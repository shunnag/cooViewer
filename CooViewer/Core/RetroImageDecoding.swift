import CoreGraphics
import Foundation

/// 独自デコーダ形式の個別有効化(設定「デコーダ」ペインのトグル。未設定は有効)。
/// リスト作成(SupportedTypes)とデコードの両方で参照する
enum RetroFormatToggle {
    static let magKey = "RetroDecodeMAG"
    static let makiKey = "RetroDecodeMAKI"
    static let piKey = "RetroDecodePi"
    static let picKey = "RetroDecodePIC"
    static let pnmKey = "RetroDecodePNM"

    static func isEnabled(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}

/// レトロ日本形式(MAG / MAKI / Pi / PIC / PBM P4)のデコーダ。
/// 仕様は「Maki-chan graphics format」文書(mooncore.eu/bunny/txt/makichan.htm)
/// と柳沢氏の公式仕様・参照実装に基づく。**判定は拡張子ではなく先頭マジックで
/// 行う**: 同じ拡張子で別形式が流通しているため(.max は 3ds Max 等、.pic は
/// Softimage/Pictor 等と衝突)、マジックが一致しないデータには決して適用しない。
/// ImageIO で読めないデータのフォールバックとして ImageDecoding から呼ばれる。
enum RetroImageDecoding {
    private static let magMagic = Array("MAKI02  ".utf8)
    private static let makiMagicA = Array("MAKI01A ".utf8)
    private static let makiMagicB = Array("MAKI01B ".utf8)
    private static let picMagic = Array("PIC".utf8)
    private static let piMagic = Array("Pi".utf8)

    /// 先頭マジックによる形式判定(拡張子は一切見ない)。
    /// Pi/PIC はマジックが短いため、ヘッダ全体の妥当性検証も判定に含める
    static func isRetroImage(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(8))
        if head == magMagic {
            return RetroFormatToggle.isEnabled(RetroFormatToggle.magKey)
        }
        if head == makiMagicA || head == makiMagicB {
            return RetroFormatToggle.isEnabled(RetroFormatToggle.makiKey)
        }
        let bytes = [UInt8](data.prefix(65536))
        if parsePiHeader(bytes) != nil {
            return RetroFormatToggle.isEnabled(RetroFormatToggle.piKey)
        }
        if parsePicHeader(bytes) != nil {
            return RetroFormatToggle.isEnabled(RetroFormatToggle.picKey)
        }
        if parseP4Header(bytes) != nil {
            return RetroFormatToggle.isEnabled(RetroFormatToggle.pnmKey)
        }
        return false
    }

    /// ヘッダのみからピクセル寸法を返す(縦横比 1:2 の伸長込み)
    static func imageSize(_ data: Data) -> CGSize? {
        let bytes = [UInt8](data.prefix(65536))
        if let header = parseMagHeader(bytes),
           RetroFormatToggle.isEnabled(RetroFormatToggle.magKey) {
            let height = (header.bottom - header.top + 1)
                * (header.doubleHeight ? 2 : 1)
            if header.isYJK {
                return CGSize(width: header.yjkWidth, height: height)
            }
            return CGSize(width: header.right - header.left + 1, height: height)
        }
        if let maki = parseMakiHeader(bytes),
           RetroFormatToggle.isEnabled(RetroFormatToggle.makiKey) {
            return CGSize(width: 640, height: maki.doubleHeight ? 800 : 400)
        }
        if let pi = parsePiHeader(bytes),
           RetroFormatToggle.isEnabled(RetroFormatToggle.piKey) {
            return CGSize(width: pi.width, height: pi.height)
        }
        if let pic = parsePicHeader(bytes),
           RetroFormatToggle.isEnabled(RetroFormatToggle.picKey) {
            return CGSize(width: pic.width, height: pic.height)
        }
        if let pnm = parseP4Header(bytes),
           RetroFormatToggle.isEnabled(RetroFormatToggle.pnmKey) {
            return CGSize(width: pnm.width, height: pnm.height)
        }
        return nil
    }

    /// フルデコード。対応外の変種や壊れたデータは nil
    static func decode(_ data: Data) -> CGImage? {
        let bytes = [UInt8](data)
        if bytes.prefix(8).elementsEqual(magMagic) {
            guard RetroFormatToggle.isEnabled(RetroFormatToggle.magKey) else {
                return nil
            }
            return decodeMag(bytes)
        }
        if bytes.prefix(8).elementsEqual(makiMagicA)
            || bytes.prefix(8).elementsEqual(makiMagicB) {
            guard RetroFormatToggle.isEnabled(RetroFormatToggle.makiKey) else {
                return nil
            }
            return decodeMaki(bytes, variantB: bytes.prefix(8).elementsEqual(makiMagicB))
        }
        if parsePiHeader(bytes) != nil {
            guard RetroFormatToggle.isEnabled(RetroFormatToggle.piKey) else {
                return nil
            }
            return decodePi(bytes)
        }
        if parsePicHeader(bytes) != nil {
            guard RetroFormatToggle.isEnabled(RetroFormatToggle.picKey) else {
                return nil
            }
            return decodePic(bytes)
        }
        if parseP4Header(bytes) != nil {
            guard RetroFormatToggle.isEnabled(RetroFormatToggle.pnmKey) else {
                return nil
            }
            return decodeP4(bytes)
        }
        return nil
    }

    /// MSB ファーストのビットリーダ(Pi / PIC 共通)
    private struct BitReader {
        let data: [UInt8]
        var position: Int
        var bit = 0

        init(_ data: [UInt8], at offset: Int) {
            self.data = data
            position = offset
        }

        mutating func readBit() -> Int? {
            guard position < data.count else { return nil }
            let value = (data[position] >> (7 - bit)) & 1
            bit += 1
            if bit == 8 {
                bit = 0
                position += 1
            }
            return Int(value)
        }

        mutating func readBits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let b = readBit() else { return nil }
                value = value << 1 | b
            }
            return value
        }
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
        /// 「256 色でなく mode bit0」、MSX(0x03) は flag(下位 2 ビットは
        /// 水平アラインメントなのでマスク)== 4
        var doubleHeight: Bool {
            if modelCode == 0x03 { return (modelFlag & 0xFC) == 0x04 }
            return !is256 && (mode & 0x01) != 0
        }
        /// MSX2+ の YJK スクリーンモード(10/11 = パレット混在、12 = 純 YJK)
        var isYJK: Bool {
            modelCode == 0x03 && [0x24, 0x34, 0x44].contains(modelFlag & 0xFC)
        }
        /// YJK ではパレット混在(YAE)モード。Y の最下位ビットでパレット参照
        var yjkUsesPalette: Bool { (modelFlag & 0xFC) != 0x44 }
        /// YJK の最終ピクセル幅(1 バイト = 1 サンプル。4bpp 記録なら半分)
        var yjkWidth: Int {
            let nominal = right - left + 1
            return is256 ? nominal : (nominal + 1) / 2
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

        // MSX2+ YJK モード: バイト列を YJK サンプルとして RGB 変換する
        if h.isYJK {
            let cropLeftBytes = h.left / pixelsPerByte - paddedLeft
            return renderMagYJK(out: out, byteWidth: byteWidth, height: height,
                                cropLeftBytes: cropLeftBytes, width: h.yjkWidth,
                                usePalette: h.yjkUsesPalette, palette: palette,
                                doubleHeight: h.doubleHeight)
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

    /// YJK バッファの RGB 変換(仕様: 4 バイト = 4 ピクセルで J/K を共有。
    /// YAE モードでは Y の最下位ビットが 1 のピクセルはパレット参照)
    private static func renderMagYJK(
        out: [UInt8], byteWidth: Int, height: Int, cropLeftBytes: Int,
        width: Int, usePalette: Bool,
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        doubleHeight: Bool) -> CGImage? {
        guard width > 0, cropLeftBytes >= 0,
              cropLeftBytes + width <= byteWidth else { return nil }
        var rgb = [(r: UInt8, g: UInt8, b: UInt8)](
            repeating: (0, 0, 0), count: width * height)
        for y in 0..<height {
            let row = y * byteWidth
            for x in 0..<width {
                let index = cropLeftBytes + x
                let luma = Int(out[row + index]) >> 3
                if usePalette, luma & 1 != 0 {
                    rgb[y * width + x] = palette[luma >> 1]
                    continue
                }
                // グループ境界はバッファ内の 4 バイト単位(行頭基準)
                let group = row + (index & ~3)
                guard group + 3 < out.count else { continue }
                var k = Int(out[group] & 7) | Int(out[group + 1] & 7) << 3
                var j = Int(out[group + 2] & 7) | Int(out[group + 3] & 7) << 3
                k -= (k & 0x20) << 1
                j -= (j & 0x20) << 1
                func clamp5(_ v: Int) -> Int { min(31, max(0, v)) }
                let r = clamp5(luma + j)
                let g = clamp5(luma + k)
                let b = clamp5((((5 * luma - k) >> 1) - j) >> 1)
                func scale(_ v: Int) -> UInt8 { UInt8(v << 3 | v >> 2) }
                rgb[y * width + x] = (scale(r), scale(g), scale(b))
            }
        }
        return renderRGB(width: width, height: height,
                         doubleHeight: doubleHeight) { x, y in rgb[y * width + x] }
    }

    /// パレット成分の有効ビット数(仕様の機種別規則)。
    /// モデルコードに加えて機種名文字列(オフセット 8)も見る: 実在の
    /// X68000 画像にはモデルコード 0x00 のまま機種名 "X68K" のものがあり、
    /// 5bit で解釈しないと全色がわずかにずれる(実サンプルで確認)
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
        return renderIndexed(
            width: 640, height: height, doubleHeight: h.doubleHeight,
            palette: palette
        ) { x, y in
            let byte = out[y * byteWidth + x / 2]
            return x % 2 == 0 ? Int(byte >> 4) : Int(byte & 0x0F)
        }
    }

    // MARK: - Pi(柳沢氏の PC-98 系フォーマット)

    fileprivate struct PiHeader {
        let mode: UInt8
        let depth: Int          // 4 または 8
        let width: Int
        let height: Int
        let paletteOffset: Int  // RGB 三つ組の開始位置
        let streamOffset: Int   // 圧縮ビットストリームの開始位置
        var colors: Int { 1 << depth }
    }

    fileprivate static func parsePiHeader(_ d: [UInt8]) -> PiHeader? {
        // マジック "Pi"(仕様上は省略もあり得るが、拡張子衝突対策として必須にする)
        guard d.count > 24, d[0] == 0x50, d[1] == 0x69,
              let escape = d[2...].firstIndex(of: 0x1A),
              let base = d[escape...].firstIndex(of: 0x00) else { return nil }
        // base+0: 0x00 / +1: mode / +2,3: アスペクト比 / +4: ビット深度 /
        // +5..8: 圧縮器シグネチャ / +9,10: 付加データ長(BE) / 付加データ /
        // 幅(BE 2) / 高さ(BE 2) / パレット(RGB)
        guard base + 15 <= d.count else { return nil }
        let mode = d[base + 1]
        guard mode == 0 || mode == 0xFF else { return nil }
        var depth = Int(d[base + 4])
        if depth == 0xFF { depth = 4 }
        guard depth == 4 || depth == 8 else { return nil }
        let extraLength = Int(d[base + 9]) << 8 | Int(d[base + 10])
        guard extraLength <= 16 else { return nil }
        let sizeOffset = base + 11 + extraLength
        guard sizeOffset + 4 <= d.count else { return nil }
        let width = Int(d[sizeOffset]) << 8 | Int(d[sizeOffset + 1])
        let height = Int(d[sizeOffset + 2]) << 8 | Int(d[sizeOffset + 3])
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 64 * 1024 * 1024 else { return nil }
        let paletteOffset = sizeOffset + 4
        let streamOffset = paletteOffset + (1 << depth) * 3
        guard streamOffset < d.count else { return nil }
        return PiHeader(mode: mode, depth: depth, width: width, height: height,
                        paletteOffset: paletteOffset, streamOffset: streamOffset)
    }

    private static func decodePi(_ d: [UInt8]) -> CGImage? {
        guard let h = parsePiHeader(d) else { return nil }
        let colors = h.colors
        var palette = [(r: UInt8, g: UInt8, b: UInt8)](
            repeating: (0, 0, 0), count: colors)
        for i in 0..<colors {
            let p = h.paletteOffset + i * 3
            // Pi のパレットは RGB 順(MAG の GRB と異なる)。有効ビットは
            // PC-98 の 4bit を既定とし、MAG と同じ複製拡張を行う
            palette[i] = (r: expandComponent(d[p], bits: 4),
                          g: expandComponent(d[p + 1], bits: 4),
                          b: expandComponent(d[p + 2], bits: 4))
        }

        guard let indices = unpackPi(d, header: h) else { return nil }
        return renderIndexed(width: h.width, height: h.height,
                             doubleHeight: false, palette: palette) { x, y in
            Int(indices[y * h.width + x])
        }
    }

    /// Pi 展開本体(デルタ符号+繰り返し列。仕様と作者実装 pi.pas に準拠)
    private static func unpackPi(_ d: [UInt8], header h: PiHeader) -> [UInt8]? {
        let total = h.width * h.height
        var out = [UInt8](repeating: 0, count: total)
        var position = 0
        var reader = BitReader(d, at: h.streamOffset)
        let colors = h.colors

        // デルタ表: table[a][b] = (colors + a - b) % colors
        var table = [UInt8](repeating: 0, count: colors * colors)
        for a in 0..<colors {
            for b in 0..<colors {
                table[a * colors + b] = UInt8((colors + a - b) % colors)
            }
        }
        var lastByte = 0

        /// 可変長デルタ符号(16 色: 最大 011xxx、256 色: 0111111x^7 まで)
        func readDeltaIndex() -> Int? {
            guard let first = reader.readBit() else { return nil }
            if first == 1 {
                guard let x = reader.readBit() else { return nil }
                return x
            }
            guard let second = reader.readBit() else { return nil }
            if second == 0 {
                guard let x = reader.readBit() else { return nil }
                return 2 + x
            }
            // "01" のあと: 0 -> 010xx、1 -> 011…
            guard let third = reader.readBit() else { return nil }
            if third == 0 {
                guard let x = reader.readBits(2) else { return nil }
                return 4 + x
            }
            if colors == 16 {
                guard let x = reader.readBits(3) else { return nil }
                return 8 + x
            }
            // 256 色: 0111…: プレフィクスの 1 の数で桁が伸びる
            var ones = 0
            while ones < 4 {
                guard let bit = reader.readBit() else { return nil }
                if bit == 0 { break }
                ones += 1
            }
            switch ones {
            case 0:
                guard let x = reader.readBits(3) else { return nil }
                return 8 + x
            case 1:
                guard let x = reader.readBits(4) else { return nil }
                return 16 + x
            case 2:
                guard let x = reader.readBits(5) else { return nil }
                return 32 + x
            case 3:
                guard let x = reader.readBits(6) else { return nil }
                return 64 + x
            default:
                guard let x = reader.readBits(7) else { return nil }
                return 128 + x
            }
        }

        func processDelta() -> Bool {
            // 満杯なら何も読まずに成功扱い(参照実装と同じ)
            guard position < total else { return true }
            guard let index = readDeltaIndex() else { return false }
            let rowBase = lastByte * colors
            let color = table[rowBase + index]
            // Move-to-front(行内で先頭へ)
            var i = index
            while i > 0 {
                table[rowBase + i] = table[rowBase + i - 1]
                i -= 1
            }
            table[rowBase] = color
            out[position] = color
            position += 1
            lastByte = Int(color)
            return true
        }

        /// 繰り返し長(1 のプレフィクス k 個 + k ビット → 2^k + bits)
        func readLengthCode() -> Int? {
            var ones = 0
            while ones < 24 {
                guard let bit = reader.readBit() else { return nil }
                if bit == 0 { break }
                ones += 1
            }
            guard ones < 24 else { return nil }
            guard let extra = ones == 0 ? 0 : reader.readBits(ones) else { return nil }
            return (1 << ones) + extra
        }

        /// 位置コード(00 / 01 / 10 / 110 / 111)
        func readRepetitionType() -> Int? {
            guard let first = reader.readBit() else { return nil }
            if first == 0 {
                guard let second = reader.readBit() else { return nil }
                return second  // 0 or 1
            }
            guard let second = reader.readBit() else { return nil }
            if second == 0 { return 2 }
            guard let third = reader.readBit() else { return nil }
            return third == 0 ? 3 : 4
        }

        /// 前方コピー(重なり可)。コピー元が先頭より前の間は先頭 2 バイトで埋める
        func copyBytes(_ length: Int, offset: Int, fillerSwapped: Bool) {
            var remaining = min(length, total - position)
            var outOfBounds = offset - position
            if outOfBounds > 0 {
                let fill = min(outOfBounds, remaining)
                let b0 = fillerSwapped ? out[1] : out[0]
                let b1 = fillerSwapped ? out[0] : out[1]
                for i in 0..<fill {
                    out[position + i] = i % 2 == 0 ? b0 : b1
                }
                position += fill
                remaining -= fill
                outOfBounds = 0
            }
            for _ in 0..<remaining {
                out[position] = out[position - offset]
                position += 1
            }
        }

        var lastRepetitionType = -1
        var doingRepetition = true

        /// 繰り返しコマンド 1 つ。直前と同じ位置コードなら繰り返し終了の印
        func processRepetition(minusReps: Int) -> Bool {
            guard let type = readRepetitionType() else { return false }
            if type == lastRepetitionType {
                doingRepetition = false
                if position > 0 { lastByte = Int(out[position - 1]) }
                return true
            }
            lastRepetitionType = type
            guard let lengthCode = readLengthCode() else { return false }
            let length = (lengthCode - minusReps) * 2
            guard length > 0 else { return true }
            switch type {
            case 0:
                // 直前 4 バイトの繰り返し(先頭付近/直前 2 バイトが同値なら 2 バイト)
                let offset: Int
                if position < 4 || (position >= 2
                    && out[position - 2] == out[position - 1]) {
                    offset = 2
                } else {
                    offset = 4
                }
                guard position >= offset else { return false }
                copyBytes(length, offset: offset, fillerSwapped: false)
            case 1:
                copyBytes(length, offset: h.width, fillerSwapped: false)
            case 2:
                copyBytes(length, offset: h.width * 2, fillerSwapped: false)
            case 3:
                copyBytes(length, offset: h.width - 1, fillerSwapped: true)
            case 4:
                copyBytes(length, offset: h.width + 1, fillerSwapped: true)
            default:
                return false
            }
            return true
        }

        // 先頭: デルタ 2 つ → 長さ -1(ペア単位)の強制繰り返し
        guard processDelta(), processDelta(),
              processRepetition(minusReps: 1) else { return nil }
        while position < total {
            if doingRepetition {
                guard processRepetition(minusReps: 0) else { return nil }
            } else {
                guard processDelta(), processDelta() else { return nil }
                guard position < total else { break }
                guard let bit = reader.readBit() else { return nil }
                if bit == 0 {
                    doingRepetition = true
                    lastRepetitionType = -1
                }
            }
        }
        return out
    }

    // MARK: - PIC(柳沢氏の X68000 系フォーマット)

    fileprivate struct PicHeader {
        let platform: Int   // 0=X68k, 2=FM-Towns, 0x1F=汎用(モード 1)
        let depth: Int      // 4/8(パレット)、15/16(ダイレクトカラー)
        let width: Int
        let height: Int
        let streamOffset: Int  // platform/depth/width/height 直後のバイト位置
    }

    fileprivate static func parsePicHeader(_ d: [UInt8]) -> PicHeader? {
        guard d.count > 16, d.prefix(3).elementsEqual(picMagic),
              let escape = d[3...].firstIndex(of: 0x1A) else { return nil }
        // コメント終端 0x1A の後、最初の 0x00 までダミーを読み飛ばす
        var cursor = escape + 1
        while cursor < d.count, d[cursor] != 0 { cursor += 1 }
        cursor += 1  // 0x00 を消費
        guard cursor + 8 <= d.count else { return nil }
        func word(_ offset: Int) -> Int { Int(d[offset]) << 8 | Int(d[offset + 1]) }
        let platform = word(cursor)
        let depth = word(cursor + 2)
        let width = word(cursor + 4)
        let height = word(cursor + 6)
        var streamOffset = cursor + 8
        switch platform {
        case 0:
            break
        case 2, 0x1F:
            // FM-Towns / 汎用モード 1 は拡張ヘッダ 6 バイトを読み飛ばす
            streamOffset += 6
        default:
            return nil  // PC-88VA 等は未対応(誤描画を避ける)
        }
        guard depth == 4 || depth == 8 || depth == 15 || depth == 16
        else { return nil }
        let paletteBytes = depth <= 8 ? (1 << depth) * 2 : 0
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 64 * 1024 * 1024,
              streamOffset + paletteBytes < d.count else { return nil }
        return PicHeader(platform: platform, depth: depth,
                         width: width, height: height, streamOffset: streamOffset)
    }

    /// X68k の 16bit 色 GGGGGRRRRRBBBBBI → 8bit RGB
    private static func x68kColor(_ color: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let intensity = color & 1
        func channel(_ five: Int) -> UInt8 {
            let v = five << 3 | intensity << 2
            return UInt8(v | v >> 6)
        }
        return (r: channel(color >> 6 & 31),
                g: channel(color >> 11 & 31),
                b: channel(color >> 1 & 31))
    }

    /// 直近 128 色のキャッシュ(双方向リンクリングの LRU。7bit 符号は
    /// スロット番号を指す — 参照実装と同一の構造)
    private struct PicColorCache {
        var values = [Int](repeating: 0, count: 128)
        var previous = [Int](repeating: 0, count: 128)
        var next = [Int](repeating: 0, count: 128)
        var head = 0

        init() {
            for i in 0..<128 {
                previous[i] = (i + 1) & 127
                next[i] = (i - 1) & 127
            }
        }

        mutating func add(_ value: Int) {
            head = previous[head]
            values[head] = value
        }

        mutating func get(_ key: Int) -> Int {
            if key != head {
                let p = previous[key]
                let n = next[key]
                next[p] = n
                previous[n] = p
                let tail = previous[head]
                next[tail] = key
                previous[key] = tail
                previous[head] = key
                next[key] = head
                head = key
            }
            return values[key]
        }
    }

    private static func decodePic(_ d: [UInt8]) -> CGImage? {
        guard let h = parsePicHeader(d) else { return nil }
        var reader = BitReader(d, at: h.streamOffset)
        // パレット(16bit GGGGGRRRRRBBBBBI x 色数)に続けて圧縮ビット列
        var palette = [(r: UInt8, g: UInt8, b: UInt8)]()
        if h.depth <= 8 {
            for _ in 0..<(1 << h.depth) {
                guard let value = reader.readBits(16) else { return nil }
                palette.append(x68kColor(value))
            }
        }

        let total = h.width * h.height
        // -1 = 未確定。チェーンが先のピクセルへ色を植える
        var pixels = [Int32](repeating: -1, count: total)
        var cache = PicColorCache()
        var color: Int32 = 0
        var position = -1

        /// 長さ符号(0 のプレフィクスまで 1 を数える PIC 形式)
        func readLength() -> Int? {
            for bits in 1...21 {
                guard let bit = reader.readBit() else { return nil }
                if bit == 0 {
                    guard let value = reader.readBits(bits) else { return nil }
                    return value + (1 << bits) - 1
                }
            }
            return nil
        }

        /// チェーン追跡: 下の行の変化点へ色を植えていく
        func decodeChain(from offset: Int) -> Bool {
            var offset = offset
            while true {
                guard let code = reader.readBits(2) else { return false }
                switch code {
                case 0:
                    guard let more = reader.readBit() else { return false }
                    if more == 0 { return true }
                    guard let side = reader.readBit() else { return false }
                    offset += side == 0 ? -2 : 2
                case 1:
                    offset -= 1
                case 2:
                    break
                default:
                    offset += 1
                }
                offset += h.width
                guard offset >= 0 else { return false }
                if offset >= total { return false }
                pixels[offset] = color
            }
        }

        decodeLoop: while true {
            guard var length = readLength() else { return nil }
            while length > 1 {
                length -= 1
                position += 1
                let existing = pixels[position]
                if existing < 0 {
                    pixels[position] = color
                } else {
                    color = existing
                }
                if position >= total - 1 { break decodeLoop }
            }

            // 新しい色を読む
            if h.depth <= 8 {
                guard let index = reader.readBits(h.depth) else { return nil }
                color = Int32(index)
            } else {
                guard let flag = reader.readBit() else { return nil }
                if flag == 0 {
                    guard var value = reader.readBits(h.depth) else { return nil }
                    if h.depth == 15 { value <<= 1 }
                    cache.add(value)
                    color = Int32(value)
                } else {
                    guard let key = reader.readBits(7) else { return nil }
                    color = Int32(cache.get(key))
                }
            }
            position += 1
            pixels[position] = color
            if position >= total - 1 { break }

            guard let hasChain = reader.readBit() else { return nil }
            if hasChain == 1 {
                guard decodeChain(from: position) else { return nil }
            }
        }

        if h.depth <= 8 {
            return renderIndexed(width: h.width, height: h.height,
                                 doubleHeight: false, palette: palette) { x, y in
                let v = pixels[y * h.width + x]
                return v < 0 ? 0 : Int(v)
            }
        }
        return renderRGB(width: h.width, height: h.height,
                         doubleHeight: false) { x, y in
            let v = pixels[y * h.width + x]
            return v < 0 ? (0, 0, 0) : x68kColor(Int(v))
        }
    }

    // MARK: - PBM P4(pbmplus のバイナリ 1bit 形式。ImageIO は P4 のみ非対応)

    fileprivate struct P4Header {
        let width: Int
        let height: Int
        let dataOffset: Int
    }

    private static func isPNMWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
            || byte == 0x0B || byte == 0x0C
    }

    fileprivate static func parseP4Header(_ d: [UInt8]) -> P4Header? {
        guard d.count > 6, d[0] == 0x50, d[1] == 0x34,
              isPNMWhitespace(d[2]) else { return nil }
        var cursor = 2
        func skipSpacesAndComments() {
            while cursor < d.count {
                if isPNMWhitespace(d[cursor]) {
                    cursor += 1
                } else if d[cursor] == 0x23 {  // '#' コメントは行末まで
                    while cursor < d.count, d[cursor] != 0x0A { cursor += 1 }
                } else {
                    break
                }
            }
        }
        func readNumber() -> Int? {
            skipSpacesAndComments()
            var value = 0
            var digits = 0
            while cursor < d.count, (0x30...0x39).contains(d[cursor]) {
                value = value * 10 + Int(d[cursor] - 0x30)
                cursor += 1
                digits += 1
                guard value <= 1_000_000 else { return nil }
            }
            return digits > 0 ? value : nil
        }
        guard let width = readNumber(), let height = readNumber(),
              width > 0, height > 0, width <= 65535, height <= 65535,
              width * height <= 64 * 1024 * 1024,
              cursor < d.count, isPNMWhitespace(d[cursor]) else { return nil }
        cursor += 1  // 高さ直後の空白 1 文字(仕様)
        return P4Header(width: width, height: height, dataOffset: cursor)
    }

    private static func decodeP4(_ d: [UInt8]) -> CGImage? {
        guard let h = parseP4Header(d) else { return nil }
        let rowBytes = (h.width + 7) / 8
        guard h.dataOffset + rowBytes * h.height <= d.count else { return nil }
        // PBM は 1 = 黒、0 = 白。MSB が左
        return renderRGB(width: h.width, height: h.height,
                         doubleHeight: false) { x, y in
            let byte = d[h.dataOffset + y * rowBytes + x / 8]
            let bit = (byte >> (7 - x % 8)) & 1
            return bit == 1 ? (0, 0, 0) : (255, 255, 255)
        }
    }

    /// MAKI のパレット拡張は MAG の繰り返し複製と異なり、仕様で明記された
    /// 「上位ニブルが 0 なら 0x00、それ以外は下位ニブルを 0xF にする」規則
    /// (公式レンダリングと照合して確認済み)
    static func makiPaletteComponent(_ value: UInt8) -> UInt8 {
        let top = value & 0xF0
        return top == 0 ? 0 : top | 0x0F
    }

    // MARK: - 共通レンダリング

    /// インデックス画像を RGBX の CGImage にする(doubleHeight で縦 2 倍)。
    /// メモリ配置は R,G,B,X の素直なバイト列(バイトオーダーフラグ不使用)
    private static func renderIndexed(
        width: Int, height: Int, doubleHeight: Bool,
        palette: [(r: UInt8, g: UInt8, b: UInt8)],
        pixelIndex: (Int, Int) -> Int) -> CGImage? {
        guard !palette.isEmpty else { return nil }
        return renderRGB(width: width, height: height,
                         doubleHeight: doubleHeight) { x, y in
            palette[pixelIndex(x, y) % palette.count]
        }
    }

    /// RGB クロージャから CGImage を作る(全レトロ形式の最終段)
    private static func renderRGB(
        width: Int, height: Int, doubleHeight: Bool,
        pixel: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let rowRepeat = doubleHeight ? 2 : 1
        let outHeight = height * rowRepeat
        let rowBytes = width * 4
        // 出力バッファは malloc 領域へ直接書き、CGImage に所有権ごと渡す
        // (配列 → Data のコピーを省く。大きい画像で最大数百 MB のコピー削減)
        let byteCount = rowBytes * outHeight
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        buffer.initializeMemory(as: UInt8.self, repeating: 0xFF, count: byteCount)
        let rgba = buffer.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let base = y * rowRepeat * rowBytes
            for x in 0..<width {
                let color = pixel(x, y)
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
        guard let provider = CGDataProvider(
            dataInfo: nil, data: buffer, size: byteCount,
            releaseData: { _, data, _ in data.deallocate() }) else {
            buffer.deallocate()
            return nil
        }
        return CGImage(
            width: width, height: outHeight,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }
}
