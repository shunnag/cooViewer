import CoreGraphics
import Foundation

/// レトロ日本形式(MAG / MAKI)のデコーダ。
/// 仕様は「Maki-chan graphics format」文書(mooncore.eu/bunny/txt/makichan.htm)
/// に基づく。**判定は拡張子ではなく先頭マジックで行う**: 同じ拡張子で別形式が
/// 流通しているため(.max は 3ds Max 等、.pic は Softimage/Pictor 等と衝突)、
/// マジックが一致しないデータには決して適用しない。ImageIO で読めない
/// データのフォールバックとして ImageDecoding から呼ばれる。
/// EN: Decoders for retro Japanese image formats (MAG / MAKI), based on the
/// EN: Maki-chan graphics format document. Dispatch is strictly magic-based —
/// EN: the extensions collide with unrelated formats — and runs only as a
/// EN: fallback when ImageIO cannot read the data.
enum RetroImageDecoding {
    private static let magMagic = Array("MAKI02  ".utf8)
    private static let makiMagicA = Array("MAKI01A ".utf8)
    private static let makiMagicB = Array("MAKI01B ".utf8)

    /// 先頭マジックによる形式判定(拡張子は一切見ない)
    /// EN: Magic-based detection; extensions are never consulted.
    static func isRetroImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(8))
        return head == magMagic || head == makiMagicA || head == makiMagicB
    }

    /// ヘッダのみからピクセル寸法を返す(縦横比 1:2 の伸長込み)
    /// EN: Header-only pixel size (aspect doubling applied).
    static func imageSize(_ data: Data) -> CGSize? {
        let bytes = [UInt8](data.prefix(65536))
        if let header = parseMagHeader(bytes) {
            let height = (header.bottom - header.top + 1)
                * (header.doubleHeight ? 2 : 1)
            return CGSize(width: header.right - header.left + 1, height: height)
        }
        if let maki = parseMakiHeader(bytes) {
            return CGSize(width: 640, height: maki.doubleHeight ? 800 : 400)
        }
        return nil
    }

    /// フルデコード。対応外(MSX YJK モード等)や壊れたデータは nil
    /// EN: Full decode; nil for unsupported variants or corrupt data.
    static func decode(_ data: Data) -> CGImage? {
        let bytes = [UInt8](data)
        if bytes.prefix(8).elementsEqual(magMagic) {
            return decodeMag(bytes)
        }
        if bytes.prefix(8).elementsEqual(makiMagicA)
            || bytes.prefix(8).elementsEqual(makiMagicB) {
            return decodeMaki(bytes, variantB: bytes.prefix(8).elementsEqual(makiMagicB))
        }
        return nil
    }

    // MARK: - MAG (MAKI02)

    private struct MagHeader {
        let base: Int          // ヘッダ先頭(コメント終端 0x1A 後の最初の 0x00)
        let modelCode: UInt8
        let modelFlag: UInt8
        let mode: UInt8
        let left: Int, top: Int, right: Int, bottom: Int
        let offsetA: Int, offsetB: Int, offsetPix: Int  // ファイル先頭からの絶対位置
        var is256: Bool { mode & 0x80 != 0 }
        /// 1:2 アスペクト(最終段で縦 2 倍に伸長)。仕様: 非 MSX は
        /// 「256 色でなく mode bit0」、MSX(0x03) は flag == 4
        var doubleHeight: Bool {
            if modelCode == 0x03 { return modelFlag == 0x04 }
            return !is256 && (mode & 0x01) != 0
        }
    }

    private static func parseMagHeader(_ d: [UInt8]) -> MagHeader? {
        guard d.count > 40, d.prefix(8).elementsEqual(magMagic) else { return nil }
        // コメント(機種 4 + 可変)は 0x1A で終わり、その後の最初の 0x00 が
        // 実ヘッダの先頭(仕様どおり。0x1A 直後とは限らない)
        guard let escape = d[8...].firstIndex(of: 0x1A),
              let base = d[escape...].firstIndex(of: 0x00),
              base + 32 <= d.count else { return nil }
        func u16(_ offset: Int) -> Int {
            Int(d[base + offset]) | Int(d[base + offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            u16(offset) | u16(offset + 2) << 16
        }
        let header = MagHeader(
            base: base,
            modelCode: d[base + 1], modelFlag: d[base + 2], mode: d[base + 3],
            left: u16(4), top: u16(6), right: u16(8), bottom: u16(10),
            offsetA: base + u32(12), offsetB: base + u32(16),
            offsetPix: base + u32(24))
        guard header.left <= header.right, header.top <= header.bottom,
              header.right < 65536, header.bottom < 65536,
              header.offsetA > base + 32, header.offsetA <= d.count,
              header.offsetB >= header.offsetA, header.offsetB <= d.count,
              header.offsetPix >= header.offsetB, header.offsetPix <= d.count
        else { return nil }
        return header
    }

    /// 4bit コード 1-15 のコピー元(単位: X = 16bit ワード、Y = 行)
    /// 仕様の図: 1:(-1,0) 2:(-2,0) 3:(-4,0) 4:(0,-1) 5:(-1,-1)
    ///           6:(0,-2) 7:(-1,-2) 8:(-2,-2) 9:(0,-4) 10:(-1,-4) 11:(-2,-4)
    ///           12:(0,-8) 13:(-1,-8) 14:(-2,-8) 15:(0,-16)
    private static let magCopyOffsets: [(words: Int, rows: Int)] = [
        (0, 0), (1, 0), (2, 0), (4, 0), (0, 1), (1, 1),
        (0, 2), (1, 2), (2, 2), (0, 4), (1, 4), (2, 4),
        (0, 8), (1, 8), (2, 8), (0, 16),
    ]

    private static func decodeMag(_ d: [UInt8]) -> CGImage? {
        guard let h = parseMagHeader(d) else { return nil }
        // MSX2+ の YJK モードは色変換が別物なので対応外(誤描画を避けて nil)
        // EN: MSX2+ YJK modes need a different color pipeline; bail out.
        if h.modelCode == 0x03, [0x24, 0x34, 0x44].contains(h.modelFlag) {
            return nil
        }

        // 左右端を 4 バイト境界へパディング(仕様の式のとおり)
        let pixelsPerByte = h.is256 ? 1 : 2
        let paddedLeft = (h.left / pixelsPerByte) & ~3
        let paddedRight = ((h.right / pixelsPerByte) + 4) & ~3
        let byteWidth = paddedRight - paddedLeft
        let height = h.bottom - h.top + 1
        guard byteWidth > 0, height > 0, byteWidth * height <= 64 * 1024 * 1024
        else { return nil }

        // パレット(GRB 三つ組がヘッダ+32 からフラグ A 開始まで)
        let paletteCount = min(256, (h.offsetA - h.base - 32) / 3)
        guard paletteCount >= 1 else { return nil }
        let significantBits = paletteSignificantBits(
            modelCode: h.modelCode, paletteCount: paletteCount, file: d)
        var palette = [(r: UInt8, g: UInt8, b: UInt8)](
            repeating: (0, 0, 0), count: 256)
        for i in 0..<paletteCount {
            let p = h.base + 32 + i * 3
            palette[i] = (r: expandComponent(d[p + 1], bits: significantBits),
                          g: expandComponent(d[p], bits: significantBits),
                          b: expandComponent(d[p + 2], bits: significantBits))
        }

        // 3 ストリーム展開(フラグ A のビット / フラグ B のバイト /
        // 16bit 単位の色インデックス)
        var out = [UInt8](repeating: 0, count: byteWidth * height)
        var action = [UInt8](repeating: 0, count: byteWidth / 4)
        var flagACursor = h.offsetA
        var flagABit = 0
        var flagBCursor = h.offsetB
        var colorCursor = h.offsetPix
        var actionIndex = 0
        var position = 0
        let total = out.count

        decodeLoop: while position < total {
            // フラグ A: 1 ビット(MSB→LSB)。尽きたら終了(残りは 0 のまま)
            guard flagACursor < h.offsetB else { break }
            let aBit = (d[flagACursor] >> (7 - flagABit)) & 1
            flagABit += 1
            if flagABit == 8 {
                flagABit = 0
                flagACursor += 1
            }
            if aBit != 0 {
                guard flagBCursor < h.offsetPix else { break }
                action[actionIndex] ^= d[flagBCursor]
                flagBCursor += 1
            }
            let actionByte = action[actionIndex]
            actionIndex += 1
            if actionIndex == action.count { actionIndex = 0 }

            for nibble in [actionByte >> 4, actionByte & 0x0F] {
                guard position + 1 < total else { break decodeLoop }
                if nibble == 0 {
                    // 色インデックスストリームから 2 バイト(尽きたら 0)
                    if colorCursor + 1 < d.count {
                        out[position] = d[colorCursor]
                        out[position + 1] = d[colorCursor + 1]
                        colorCursor += 2
                    }
                } else {
                    let offset = magCopyOffsets[Int(nibble)]
                    let source = position - offset.words * 2 - offset.rows * byteWidth
                    if source >= 0 {
                        out[position] = out[source]
                        out[position + 1] = out[source + 1]
                    }
                }
                position += 2
            }
        }

        // パディングの切り落とし+RGBA 化(16 色は上位ニブルが左ピクセル)
        let cropLeftPixels = h.left - paddedLeft * pixelsPerByte
        let width = h.right - h.left + 1
        return renderIndexed(
            width: width, height: height, doubleHeight: h.doubleHeight,
            palette: palette
        ) { x, y in
            let px = cropLeftPixels + x
            let row = y * byteWidth
            if h.is256 {
                return Int(out[row + px])
            }
            let byte = out[row + px / 2]
            return px % 2 == 0 ? Int(byte >> 4) : Int(byte & 0x0F)
        }
    }

    /// パレット成分の有効ビット数(仕様の機種別規則)。
    /// モデルコードに加えて機種名文字列(オフセット 8)も見る: 実在の
    /// X68000 画像にはモデルコード 0x00 のまま機種名 "X68K" のものがあり、
    /// 5bit で解釈しないと全色がわずかにずれる(実サンプルで確認)
    /// EN: Significant palette bits. Also honors the machine-name string at
    /// EN: offset 8 — real X68000 files exist with model code 0x00.
    private static func paletteSignificantBits(
        modelCode: UInt8, paletteCount: Int, file: [UInt8]) -> Int {
        if file.count >= 12, Array(file[8..<12]) == Array("X68K".utf8) {
            return 5
        }
        if modelCode == 0x03 {
            // 例外: "Deca loader" がファイルオフセット 32 にあれば 4 ビット扱い
            let marker = Array("Deca loader".utf8)
            if file.count >= 32 + marker.count,
               Array(file[32..<32 + marker.count]) == marker {
                return 4
            }
            return 3
        }
        if modelCode == 0x68 { return 5 }
        if modelCode == 0x99 { return 8 }
        if paletteCount == 256, modelCode != 0x88 { return 8 }
        return 4
    }

    /// 上位 bits ビットを下位へ繰り返しコピーして 8 ビットへ拡張
    /// (仕様の例: 0x55/3bit→0x49, 0xBF/4bit→0xBB, 0x67/5bit→0x63)
    /// EN: Replicate the significant top bits downward to fill the byte.
    static func expandComponent(_ value: UInt8, bits: Int) -> UInt8 {
        guard (1...7).contains(bits) else { return value }
        let mask = UInt8(0xFF << (8 - bits) & 0xFF)
        let top = value & mask
        var result = Int(top)
        var shift = bits
        while shift < 8 {
            result |= Int(top) >> shift
            shift += bits
        }
        return UInt8(result & 0xFF)
    }

    // MARK: - MAKI (MAKI01A/B)

    private struct MakiHeader {
        let flagBSize: Int
        let extensionFlag: Int
        var doubleHeight: Bool { extensionFlag & 1 != 0 }
    }

    private static func parseMakiHeader(_ d: [UInt8]) -> MakiHeader? {
        guard d.count >= 1096,
              d.prefix(8).elementsEqual(makiMagicA)
                || d.prefix(8).elementsEqual(makiMagicB) else { return nil }
        // MAKI ヘッダはビッグエンディアン(X68000 発祥)
        let flagBSize = Int(d[32]) << 8 | Int(d[33])
        let extensionFlag = Int(d[38]) << 8 | Int(d[39])
        return MakiHeader(flagBSize: flagBSize, extensionFlag: extensionFlag)
    }

    private static func decodeMaki(_ d: [UInt8], variantB: Bool) -> CGImage? {
        guard let h = parseMakiHeader(d) else { return nil }
        // 常に全画面 640x400・16 色(仕様: 位置/サイズフィールドは未使用)
        let byteWidth = 320
        let height = 400

        var palette = [(r: UInt8, g: UInt8, b: UInt8)](
            repeating: (0, 0, 0), count: 16)
        for i in 0..<16 {
            let p = 48 + i * 3
            palette[i] = (r: makiPaletteComponent(d[p + 1]),
                          g: makiPaletteComponent(d[p]),
                          b: makiPaletteComponent(d[p + 2]))
        }

        // フラグ A(96〜、固定 1000 バイト)を 4x4 チャンクのマスクへ展開
        // EN: Expand flag A (+ flag B words) into the 320x400 one-bit mask.
        var mask = [Bool](repeating: false, count: byteWidth * height)
        let flagAStart = 96
        let flagBStart = flagAStart + 1000
        var flagBCursor = flagBStart
        let flagBEnd = min(d.count, flagBStart + h.flagBSize)
        var chunkIndex = 0  // 横 80 x 縦 100 チャンク
        for bitIndex in 0..<8000 {
            let aByte = d[flagAStart + bitIndex / 8]
            let aBit = (aByte >> (7 - bitIndex % 8)) & 1
            let chunkX = (chunkIndex % 80) * 4
            let chunkY = (chunkIndex / 80) * 4
            chunkIndex += 1
            guard aBit != 0 else { continue }
            guard flagBCursor + 1 < flagBEnd else { break }
            // 2 バイト = 4 行 x 4 ビット(上位ニブルが先、MSB が左)
            let word = [d[flagBCursor] >> 4, d[flagBCursor] & 0x0F,
                        d[flagBCursor + 1] >> 4, d[flagBCursor + 1] & 0x0F]
            flagBCursor += 2
            for (rowOffset, nibble) in word.enumerated() {
                let row = (chunkY + rowOffset) * byteWidth + chunkX
                for column in 0..<4 where (nibble >> (3 - column)) & 1 != 0 {
                    mask[row + column] = true
                }
            }
        }

        // マスク順に走査: 0 は色 0 のペア、1 はピクセルデータ 1 バイト
        var out = [UInt8](repeating: 0, count: byteWidth * height)
        var pixelCursor = flagBEnd
        for i in 0..<out.count where mask[i] {
            if pixelCursor < d.count {
                out[i] = d[pixelCursor]
                pixelCursor += 1
            }
        }

        // 縦方向の繰り返しを XOR フィルタで復元(A: 2 行上、B: 4 行上)
        let xorDistance = variantB ? 4 : 2
        for y in xorDistance..<height {
            let row = y * byteWidth
            let above = (y - xorDistance) * byteWidth
            for x in 0..<byteWidth {
                out[row + x] ^= out[above + x]
            }
        }

        // ニブル順は MAG と同じ**上位=左**。参考文書には「下位が左」の記述が
        // あるが、実ファイルと公式レンダリングの照合で上位=左と確認済み
        // (対称バイト以外の全ピクセルが一致)
        // EN: HIGH nibble = left pixel, same as MAG. The reference document
        // EN: claims low-first, but byte-level comparison against the official
        // EN: renderings proves high-first.
        return renderIndexed(
            width: 640, height: height, doubleHeight: h.doubleHeight,
            palette: palette
        ) { x, y in
            let byte = out[y * byteWidth + x / 2]
            return x % 2 == 0 ? Int(byte >> 4) : Int(byte & 0x0F)
        }
    }

    /// MAKI のパレット拡張は MAG の繰り返し複製と異なり、仕様で明記された
    /// 「上位ニブルが 0 なら 0x00、それ以外は下位ニブルを 0xF にする」規則
    /// (公式レンダリングと照合して確認済み)
    /// EN: MAKI palette expansion per its spec: zero top nibble -> 0x00,
    /// EN: otherwise OR 0x0F (verified against the reference renderings).
    static func makiPaletteComponent(_ value: UInt8) -> UInt8 {
        let top = value & 0xF0
        return top == 0 ? 0 : top | 0x0F
    }

    // MARK: - 共通レンダリング

    /// インデックス画像を RGBX の CGImage にする(doubleHeight で縦 2 倍)。
    /// メモリ配置は R,G,B,X の素直なバイト列(バイトオーダーフラグ不使用)
    /// EN: Rasterize palette-indexed pixels into an RGBX CGImage with a
    /// EN: plain big-endian byte layout.
    private static func renderIndexed(
        width: Int, height: Int, doubleHeight: Bool,
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        pixelIndex: (Int, Int) -> Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let rowRepeat = doubleHeight ? 2 : 1
        let outHeight = height * rowRepeat
        let rowBytes = width * 4
        var rgba = [UInt8](repeating: 0xFF, count: rowBytes * outHeight)
        for y in 0..<height {
            let base = y * rowRepeat * rowBytes
            for x in 0..<width {
                let color = palette[pixelIndex(x, y) % palette.count]
                rgba[base + x * 4] = color.r
                rgba[base + x * 4 + 1] = color.g
                rgba[base + x * 4 + 2] = color.b
            }
            if rowRepeat == 2 {
                for i in 0..<rowBytes {
                    rgba[base + rowBytes + i] = rgba[base + i]
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: outHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
