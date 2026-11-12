import Foundation

// 印刷の見え方(紙の本では見分けられない細かい網点をなめらかな階調にまとめる処理)の
// 公開 API(設計書 §5)。アプリの型には依存しない。演算は移植したエンジン
// (Descreener ほか)がそのまま行い、ここは入出力の形とモードだけを定める。

/// 版と段階の解決。
public enum PrintAppearance {
    /// 出力のバイトが変わり得る変更のたびに上げる。キャッシュのタグに入る
    public static let engineVersion = 1

    /// ページの物理的な高さ(mm)。画素から距離への換算は、ラスタの高さとこの値で決める。
    /// 単ページ(縦横比約 0.7)でも 1 枚に収めた見開き(約 1.4)でも高さは同じ
    static let pageHeightMM = 173.0

    /// 実際に使う段階。強め は高さ 800 px 未満のページでは 標準 に留める
    /// (低解像度のスキャンで強めすぎないため)
    public static func effectiveLevel(_ level: PrintAppearanceLevel, heightPx: Int) -> PrintAppearanceLevel {
        PrintAppearanceKit.effectiveLevel(level, heightPx: heightPx)
    }
}

/// 強さの段階。値は設定キーに保存する整数と一致させる
public enum PrintAppearanceLevel: Int, Sendable, CaseIterable {
    case low
    case standard
    case strong
}

/// エンジンへの入力: 8 bit の輝度(上の行から順、行の詰め物なし)。
public struct PrintAppearancePage: Sendable {
    public let width: Int
    public let height: Int
    public let luma: [UInt8]

    public init(luma: [UInt8], width: Int, height: Int) throws {
        guard width > 0, height > 0, luma.count == width * height else {
            throw PrintAppearanceError.invalidPage("輝度の大きさが幅×高さと一致しない")
        }
        self.width = width
        self.height = height
        self.luma = luma
    }
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

    init(copying bytes: UnsafePointer<UInt8>, width: Int, height: Int, changed: Bool) {
        let rowBytes = (width + 15) & ~15
        var data = Data(count: rowBytes * height)
        data.withUnsafeMutableBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height { memcpy(base + y * rowBytes, bytes + y * width, width) }
        }
        self.width = width
        self.height = height
        self.bytesPerRow = rowBytes
        self.pixels = data
        self.changed = changed
    }
}

/// エンジンの失敗。GPU 由来か、ページに対して決定的に断るものかを呼び出し側が区別できるように分ける
public enum PrintAppearanceError: Error, Sendable, Equatable {
    /// Metal のデバイス・ライブラリ・パイプラインを用意できない
    case gpuUnavailable(String)
    /// GPU の実行が失敗した、または GPU の結果が CPU の判定と食い違った
    case gpuFailed(String)
    /// 作業領域を確保できない
    case allocationFailed(String)
    /// このページは処理できない(小さすぎる・ノッチの範囲が大きすぎるなど、同じ入力なら常に同じ結果)
    case unsupportedPage(String)
    /// 入力の形が不正
    case invalidPage(String)
    /// 調整値がエンジンの前提に合わない
    case invalidParameters(String)
}

/// 1 プロセスに 1 つ置くエンジン。Sendable ではなく、1 つの直列キューからだけ使う(設計書 §5)。
/// 内部で concurrentPerform と GPU 完了待ちでブロックするため、メインアクタや
/// Swift Concurrency の協調スレッドから呼ばないこと。
public final class PrintAppearanceEngine {
    public enum Mode: Sendable, Equatable {
        /// GPU を使う既定の経路(CPU 経路との差は最大 1 階調)
        case automatic
        /// GPU を使わない厳密な経路
        case cpuOnly
    }

    public let mode: Mode
    private var descreener: Descreener?

    public init(mode: Mode = .automatic) {
        self.mode = mode
    }

    /// 1 ページを処理する。threads は CPU 段の並列数で、出力はこの値に依存しない
    public func process(_ page: PrintAppearancePage, level: PrintAppearanceLevel,
                        threads: Int) throws -> PrintAppearanceGray {
        guard page.width >= N, page.height >= N else {
            throw PrintAppearanceError.unsupportedPage("辺が 128 px 未満")
        }
        let engine = try makeDescreener(threads: threads)
        let effective = PrintAppearance.effectiveLevel(level, heightPx: page.height)
        let geo = Geometry(pageHeightMM: PrintAppearance.pageHeightMM, distanceMM: effective.distanceMM,
                           pageHeightPx: page.height)
        let result = try page.luma.withUnsafeBufferPointer {
            try engine.run(src: $0.baseAddress!, W: page.width, H: page.height, geo: geo, threads: threads)
        }
        return PrintAppearanceGray(copying: engine.output, width: page.width, height: page.height,
                                   changed: result.changed > 0)
    }

    private func makeDescreener(threads: Int) throws -> Descreener {
        if let descreener { return descreener }
        let made: Descreener
        switch mode {
        case .automatic:
            made = try Descreener(params: .printAppearance, a2: .printAppearance, options: .automatic,
                                  gpu: try GPUContext(), threads: threads)
        case .cpuOnly:
            made = try Descreener(params: .printAppearance, a2: .printAppearance, options: .cpuOnly,
                                  gpu: nil, threads: threads)
        }
        descreener = made
        return made
    }
}
