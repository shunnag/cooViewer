import CoreGraphics
import Foundation

// 印刷の見え方(紙の本では見分けられない細かい網点をなめらかな階調にまとめる処理)の
// 公開 API(設計書 §5)。アプリの型には依存しない。演算は移植したエンジン
// (Descreener ほか)がそのまま行い、ここは入出力の形とモードだけを定める。
// どのページを処理するかは prepare(PageInput.swift)が、どう止めて戻すかはエンジン
// (PrintAppearanceEngine.swift)が、エンジンの出力をどの色の完成画像にするかは recolour
// (PageOutput.swift)が決める。

/// 版、ページの受け付け、段階の解決、完成画像への仕上げ、縮小。
public enum PrintAppearance {
    /// 出力のバイトが変わり得る変更のたびに上げる。キャッシュのタグに入る
    public static let engineVersion = 1

    /// ページの物理的な高さ(mm)。画素から距離への換算は、ラスタの高さとこの値で決める。
    /// 単ページ(縦横比約 0.7)でも 1 枚に収めた見開き(約 1.4)でも高さは同じ
    static let pageHeightMM = 173.0

    /// 処理する画素数の上限の既定値。物理メモリが 16 GB 未満の Mac では 900 万画素、それ以外は 1600 万画素。
    /// マシンごとに固定で、メモリの逼迫では変えない(同じファイルの判定がセッション中に変わらないため)
    public static let defaultMaxPixels: Int =
        ProcessInfo.processInfo.physicalMemory < UInt64(16) << 30 ? 9_000_000 : 16_000_000

    /// 実際に使う段階。強め は高さ 800 px 未満のページでは 標準 に留める
    /// (低解像度のスキャンで強めすぎないため)
    public static func effectiveLevel(_ level: PrintAppearanceLevel, heightPx: Int) -> PrintAppearanceLevel {
        PrintAppearanceKit.effectiveLevel(level, heightPx: heightPx)
    }

    /// ファイルのバイト列を調べ、処理するページなら輝度を、そうでなければ素通しの理由を返す。
    /// 判定は同じバイト列と maxPixels に対して常に同じ。スレッドを選ばず、並行に呼んでよい。
    /// 投げるのは作業域を確保できないときだけ(そのページは素通しとして扱わない)
    public static func prepare(_ data: Data, maxPixels: Int) throws -> PrintAppearancePreparation {
        try PageInput.prepare(data, maxPixels: maxPixels)
    }

    /// 作業域を先に用意するための、ヘッダだけで分かるページの大きさ(設計書 §5)。prepare がヘッダで素通しに
    /// する理由(辺が 128 px 未満・向き・深さ・色モデル・画素数の上限・縦横比)のどれにも当たらなければ
    /// 幅と高さと、ヘッダの色モデルがグレーか(偽なら色のページとして素通しになりうる)を返す。
    /// prepare とは別の CGImageSource で読むので、prepare のデコード結果に影響しない
    public static func reservationSize(_ data: Data, maxPixels: Int) -> (width: Int, height: Int, grayHeader: Bool)? {
        PageInput.reservationSize(data, maxPixels: maxPixels)
    }

    /// 処理済みのページを width x height へ縮める(vImage の高品質な再標本化。粗い網点が残ったページを
    /// 1.5〜2 倍以上縮めても折り返しが出ないよう、前置フィルタを持つ方式を使う)。changed は引き継ぐ
    public static func reduce(_ page: PrintAppearanceGray, width: Int, height: Int) throws -> PrintAppearanceGray {
        try PageInput.reduce(page, width: width, height: height)
    }

    /// 色を保った RGB のページを width x height へ縮める。グレーと同じ高品質の再標本化を
    /// 各チャンネルに独立にかける。changed は引き継ぐ
    public static func reduce(_ page: PrintAppearanceRGB, width: Int, height: Int) throws -> PrintAppearanceRGB {
        try PageOutput.reduce(page, width: width, height: height)
    }

    /// 完成したページを width x height へ縮める(グレーはグレーのまま、RGB は RGB のまま)
    public static func reduce(_ page: PrintAppearanceOutput, width: Int, height: Int) throws -> PrintAppearanceOutput {
        switch page {
        case .gray(let gray): return .gray(try reduce(gray, width: width, height: height))
        case .rgb(let rgb): return .rgb(try reduce(rgb, width: width, height: height))
        }
    }

    /// エンジンの出力(輝度 L')をファイルの色に戻した完成画像にする。変えるのは明るさだけ(設計書 §5)。
    /// 1 チャンネルのグレーのソースは processed をそのまま返す。RGB のソースは prepare が作った sRGB の
    /// 描き直しの各画素 (R, G, B) に d = L' - L(L はその画素の輝度)を足し、0〜255 に収めた sRGB の RGB にする。
    /// 輝度の重みの和が 1000 なので、どのチャンネルも収める必要のない画素では出力の輝度がちょうど L' になり、
    /// L' == L の画素は描き直しのまま、R = G = B のページは R = G = B = L' になる。
    /// page は prepare が返したもの、processed はそのページのエンジンの出力。大きさが違えば投げる
    public static func recolour(_ page: PrintAppearancePage,
                                processed: PrintAppearanceGray) throws -> PrintAppearanceOutput {
        try PageOutput.recolour(page, processed: processed)
    }
}

/// 強さの段階。値は設定キーに保存する整数と一致させる
public enum PrintAppearanceLevel: Int, Sendable, CaseIterable {
    case low
    case standard
    case strong
}

/// エンジンへの入力: 8 bit の輝度(上の行から順、行の詰め物なし)。
/// RGB のソースは、色を戻すための sRGB の描き直しも持つ(1 画素 4 バイト。輝度と合わせて 5 バイト)。
/// エンジンの処理を待つ間と処理中もこれを保ち、recolour で完成画像にしたら手放す(設計書 §5)。
/// 輝度と描き直しは仮想記憶に置き、手放したらすぐ OS へ返す(設計書 §2.3。PageMemory.swift)
public struct PrintAppearancePage: Sendable {
    public let width: Int
    public let height: Int
    /// 輝度の持ち主(width * height バイト)。作った後は書き換えない
    let lumaBuffer: PageBuffer
    /// RGB のソースの sRGB の描き直し。1 チャンネルのグレーのソースと、輝度から直接作ったページは nil
    let redraw: SRGBRedraw?

    /// 輝度の写し(検査と診断用。処理の経路は withLuma で複製せずに読む)
    public var luma: [UInt8] { withLuma { Array($0) } }

    /// 完成画像がファイルの色を保った RGB になるか(偽なら 1 チャンネルのグレー)
    public var keepsColour: Bool { redraw != nil }

    /// 輝度だけのページ(完成画像はグレー)
    public init(luma: [UInt8], width: Int, height: Int) throws {
        guard width > 0, height > 0, luma.count == width * height else {
            throw PrintAppearanceError.invalidPage("輝度の大きさが幅×高さと一致しない")
        }
        let buffer = try PageBuffer(byteCount: luma.count)
        luma.withUnsafeBufferPointer { _ = memcpy(buffer.base, $0.baseAddress!, $0.count) }
        self.init(checked: buffer, width: width, height: height)
    }

    /// 大きさを確かめ済みの輝度(width * height バイト)から作る。redraw は同じ大きさの描き直しで、
    /// luma はその輝度
    init(checked luma: PageBuffer, width: Int, height: Int, redraw: SRGBRedraw? = nil) {
        self.width = width
        self.height = height
        lumaBuffer = luma
        self.redraw = redraw
    }

    /// 輝度を複製せずに読む
    func withLuma<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: UnsafePointer(lumaBuffer.bytes), count: width * height))
    }
}

/// prepare が輝度と色の判定に使った sRGB の描き直し(8 bit RGBA、premultipliedLast、全画素が不透明なので
/// 値は乗算前と同じ)。描いた後は書き換えず、読むだけなので、どのスレッドから読んでもよい
/// (@unchecked Sendable の根拠)。バイト列は仮想記憶の領域に描き、その領域ごと持つ: 複製せず、輝度を
/// 求めたときと同じ描き直しをそのまま使い、手放したらすぐ OS へ返すため
final class SRGBRedraw: @unchecked Sendable {
    /// バイト列の持ち主。描いた後は触らない
    private let buffer: PageBuffer
    let base: UnsafePointer<UInt8>
    let bytesPerRow: Int
    let width: Int
    let height: Int

    /// buffer は context が描いた領域(context はもう描かない)
    init(buffer: PageBuffer, bytesPerRow: Int, width: Int, height: Int) {
        self.buffer = buffer
        base = UnsafePointer(buffer.bytes)
        self.bytesPerRow = bytesPerRow
        self.width = width
        self.height = height
    }
}

/// prepare の結果
public enum PrintAppearancePreparation: Sendable {
    /// 処理しない。raw はデコードを済ませたときのその画像: 何も問い合わせていない CGImageSource に
    /// ShouldCacheImmediately だけを渡した CGImageSourceCreateImageAtIndex の結果(EXIF の向きは 1)で、
    /// ImageDecoding の上限なしの経路と同じデコード。上限ありの経路は先にヘッダを読むため、JPEG によっては
    /// ±1 異なる。デコード前に決まったときは nil
    case passThrough(PrintAppearancePassReason, raw: CGImage?)
    /// 処理する。輝度と大きさ
    case ready(PrintAppearancePage)
}

/// 素通しの理由。どれも同じファイルに対して常に同じ
public enum PrintAppearancePassReason: Sendable, Equatable, CaseIterable {
    /// 色のあるページ(sRGB に描き直して、最大と最小の差が 32 以上の画素が 0.5% を超える)
    case colour
    /// 辺が 128 px 未満(エンジンのタイル 1 枚に満たない)
    case small
    /// 画素数が上限(maxPixels)を超える
    case tooLarge
    /// 幅 / 高さが 0.5〜1.6 の外(ページの高さを 173 mm とみなす換算が成り立たない縦長・横長の画像)
    case aspect
    /// EXIF の向きが 1 以外
    case orientation
    /// 不透明でない画素がある
    case transparency
    /// ImageIO で読めない、複数フレーム、8 bit 以外、HDR、グレーと RGB 以外の色モデル
    case format
}

/// エンジンの出力: 8 bit のグレー(Generic Gray 2.2 の符号値)。行は 16 バイト境界に揃える
/// (CGImage と vImage がそのまま扱えるため)。
public struct PrintAppearanceGray: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    /// bytesPerRow × height バイト。行末の詰め物は 0
    public let pixels: Data
    /// エンジンが 1 画素でも変えたか(稼働状況の集計用。出力は変えなくても常にこのグレー)
    public let changed: Bool

    /// 16 バイト境界に揃えた 1 行のバイト数
    static func alignedRowBytes(_ width: Int) -> Int { (width + 15) & ~15 }

    init(copying bytes: UnsafePointer<UInt8>, width: Int, height: Int, changed: Bool) {
        let rowBytes = Self.alignedRowBytes(width)
        // 仮想記憶に置き、手放したらすぐ OS へ返す(設計書 §2.3)。行末の詰め物は 0 のまま
        let data = PageMemory.zeroedData(byteCount: rowBytes * height) { base in
            for y in 0..<height { memcpy(base + y * rowBytes, bytes + y * width, width) }
        }
        self.init(width: width, height: height, bytesPerRow: rowBytes, pixels: data, changed: changed)
    }

    init(width: Int, height: Int, bytesPerRow: Int, pixels: Data, changed: Bool) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.changed = changed
    }

    /// Generic Gray 2.2 の 8 bit 画像として包む(バイト列は複製しない)。アプリのグレーの表示先と同じ空間なので、
    /// 表示の色変換で符号値が変わらない
    public func makeImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// 色を保った完成画像: 8 bit の sRGB、1 画素 4 バイト(R, G, B, 255 の順。4 番目は使わない)。
/// 行は 16 バイト境界に揃える。網点処理を切ったときの RGB のファイルと同じ 1 画素 4 バイト
public struct PrintAppearanceRGB: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    /// bytesPerRow × height バイト。行末の詰め物は 0
    public let pixels: Data
    /// エンジンが輝度を 1 画素でも変えたか(稼働状況の集計用)
    public let changed: Bool

    /// 16 バイト境界に揃えた 1 行のバイト数
    static func alignedRowBytes(_ width: Int) -> Int { (width * 4 + 15) & ~15 }

    init(width: Int, height: Int, bytesPerRow: Int, pixels: Data, changed: Bool) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.changed = changed
    }

    /// sRGB の 8 bit 画像として包む(バイト列は複製しない)。描き直しと同じ空間なので、
    /// ファイルの色はそのまま表示先の変換へ渡る
    public func makeImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// 完成画像(recolour の結果)。1 チャンネルのグレーのソースはグレー、RGB のソースは色を保った RGB
public enum PrintAppearanceOutput: Sendable {
    case gray(PrintAppearanceGray)
    case rgb(PrintAppearanceRGB)

    public var width: Int {
        switch self {
        case .gray(let gray): gray.width
        case .rgb(let rgb): rgb.width
        }
    }

    public var height: Int {
        switch self {
        case .gray(let gray): gray.height
        case .rgb(let rgb): rgb.height
        }
    }

    /// エンジンが輝度を 1 画素でも変えたか
    public var changed: Bool {
        switch self {
        case .gray(let gray): gray.changed
        case .rgb(let rgb): rgb.changed
        }
    }

    /// グレーは Generic Gray 2.2、RGB は sRGB の 8 bit 画像として包む
    public func makeImage() -> CGImage? {
        switch self {
        case .gray(let gray): gray.makeImage()
        case .rgb(let rgb): rgb.makeImage()
        }
    }
}

/// 1 ページの処理を止められる位置(設計書 §5)。どれも段の境目で、止めたときはエンジンが積んだ GPU の仕事の
/// 完了を待ってから戻るので、同じエンジンで次のページをすぐ処理できる
public enum PrintAppearanceStopPoint: Int, Sendable, CaseIterable {
    /// 処理を始める前
    case beforeRun
    /// パス 1 のチャンク(256 タイル)の間
    case betweenPass1Chunks
    /// パス 1 の後
    case afterPass1
    /// 近傍の一致の後
    case afterNeighbourGate
    /// A2 の位相揃いの回の間
    case betweenFillRounds
    /// 出力を作る最後の段(パス 2 と後段)の前
    case beforeOutput
}

/// エンジンの失敗。GPU 由来か、ページに対して決定的に断るものかを呼び出し側が区別できるように分ける
public enum PrintAppearanceError: Error, Sendable, Equatable {
    /// Metal のデバイス・ライブラリ・パイプラインを用意できない
    case gpuUnavailable(String)
    /// GPU の実行が失敗した、または GPU の結果が CPU の判定と食い違った
    case gpuFailed(String)
    /// 作業域を確保できない
    case allocationFailed(String)
    /// このページは処理できない(小さすぎる・ノッチの範囲が大きすぎるなど、同じ入力なら常に同じ結果)
    case unsupportedPage(String)
    /// 入力の形が不正
    case invalidPage(String)
    /// 調整値がエンジンの前提に合わない
    case invalidParameters(String)
    /// shouldStop の求めで、この位置で止めた
    case stopped(PrintAppearanceStopPoint)
}
