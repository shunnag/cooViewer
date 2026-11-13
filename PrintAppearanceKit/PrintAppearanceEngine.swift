import Foundation

// エンジンの生涯(設計書 §5): GPU の準備と能力の確認、ページごとの実行、止める位置、GPU の失敗からの回復、
// 作業域の解放、状態。演算は Descreener が行い、ここは経路の選び方だけを決める。
//
// 失敗の扱い(どの例外も 1 度だけ分類する):
//   止めた(stopped)、入力や調整値の誤り: そのまま呼び出し側へ投げる。CPU でやり直さない。
//   GPU 由来(gpuFailed・gpuUnavailable・allocationFailed): 積んだ仕事の完了を待ってから、同じページを
//     CPU の厳密な経路で処理し直して返す。GPU の失敗が 2 ページ続いたら、以後このエンジンは CPU だけで動く。
//     生の画素を返すことはない(キャッシュのタグの下に未処理の画素が入るのを防ぐため)。
//   GPU だけの制約で断ったページ(unsupportedPage: ノッチの範囲が GPU の集約に収まらない): CPU の経路で
//     処理し直す。ページで決まることなので GPU の失敗には数えない。CPU の経路も断れば呼び出し側へ投げる。
//   GPU を用意できない(デバイスが無い・コンパイルの失敗・能力の不足): 以後 CPU だけで動く。

/// エンジンが CPU だけの経路で動く理由
public enum PrintAppearanceCPUOnlyReason: Sendable, Equatable {
    /// Mode.cpuOnly で作った
    case requested
    /// Metal のデバイス・ライブラリ・パイプラインを用意できない、またはカーネルの前提を満たさない
    case gpuUnavailable(String)
    /// GPU の失敗が 2 ページ続いた
    case repeatedGPUFailures
}

/// エンジンの状態(稼働状況の表示用)
public struct PrintAppearanceEngineStatus: Sendable, Equatable {
    public enum Path: Sendable, Equatable {
        /// GPU をまだ用意していない(最初のページか warmUp の前、またはパイプラインを解放した後)
        case idle
        /// GPU を使う既定の経路
        case gpu
        /// CPU だけの厳密な経路
        case cpuOnly(PrintAppearanceCPUOnlyReason)
    }

    public let path: Path
    /// 確保済みの作業域のバイト数(概算)。解放後は 0
    public let workingBytes: Int
    /// GPU の失敗から CPU で処理し直したページの数
    public let gpuFallbackPages: Int
    /// 直近のカーネルのコンパイルにかかった時間(ms)。まだなら nil
    public let compileMilliseconds: Double?
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
    /// GPU を作ってよいか。アプリはファイル記述子の余裕を渡す。偽ならそのページは CPU で処理し、
    /// 次のページで作り直しを試みる
    private let canCreateGPU: () -> Bool
    /// パイプラインと定数表(作業域を解放しても残せる)
    private var gpu: GPUContext?
    /// GPU 経路の作業域と作業者
    private var gpuDescreener: Descreener?
    /// CPU 経路の作業域と作業者(Mode.cpuOnly と、GPU から処理し直すとき)
    private var cpuDescreener: Descreener?
    /// nil なら GPU を使ってよい
    private var cpuOnlyReason: PrintAppearanceCPUOnlyReason?
    private var consecutiveGPUFailures = 0
    private var gpuFallbackPages = 0
    private var compileMilliseconds: Double?

    /// テスト用: GPU の経路の各停止位置で呼び、返した例外をその位置で GPU の失敗として投げる
    var gpuFaultForTesting: ((PrintAppearanceStopPoint) -> PrintAppearanceError?)?

    public init(mode: Mode = .automatic, canCreateGPU: @escaping () -> Bool = { true }) {
        self.mode = mode
        self.canCreateGPU = canCreateGPU
        if mode == .cpuOnly { cpuOnlyReason = .requested }
    }

    public var status: PrintAppearanceEngineStatus {
        let path: PrintAppearanceEngineStatus.Path
        if let cpuOnlyReason {
            path = .cpuOnly(cpuOnlyReason)
        } else {
            path = gpu != nil ? .gpu : .idle
        }
        return PrintAppearanceEngineStatus(
            path: path,
            workingBytes: (gpuDescreener?.workingBytes ?? 0) + (cpuDescreener?.workingBytes ?? 0),
            gpuFallbackPages: gpuFallbackPages, compileMilliseconds: compileMilliseconds)
    }

    /// 最初のページを待たせないための準備: 定数表に触れ、GPU のパイプラインを作り(automatic)、
    /// runDummyPage なら 256x256 の合成ページを 1 枚処理して作業域と作業者を用意する
    public func warmUp(runDummyPage: Bool, threads: Int = 2) throws {
        touchTables()
        if cpuOnlyReason == nil, canCreateGPU() { _ = gpuContext() }
        if runDummyPage { _ = try process(Self.warmUpPage, level: .standard, threads: threads) }
    }

    /// 作業域と作業者を手放す。keepPipelines が偽なら GPU のパイプラインも手放す(次のページで作り直す)。
    /// CPU だけで動く理由は保つ
    public func releaseWorkingMemory(keepPipelines: Bool) {
        gpuDescreener = nil
        cpuDescreener = nil
        if !keepPipelines { gpu = nil }
    }

    /// 1 ページを処理する。threads は CPU 段の並列数で、出力はこの値に依存しない。
    /// shouldStop は各停止位置で、このメソッドを呼んだスレッドから呼ばれる。真を返すとその位置で止め、
    /// GPU の仕事の完了を待ってから PrintAppearanceError.stopped を投げる
    public func process(_ page: PrintAppearancePage, level: PrintAppearanceLevel, threads: Int,
                        shouldStop: (PrintAppearanceStopPoint) -> Bool = { _ in false }) throws -> PrintAppearanceGray {
        guard page.width >= N, page.height >= N else {
            throw PrintAppearanceError.unsupportedPage("辺が 128 px 未満")
        }
        let effective = PrintAppearance.effectiveLevel(level, heightPx: page.height)
        let geo = Geometry(pageHeightMM: PrintAppearance.pageHeightMM, distanceMM: effective.distanceMM,
                           pageHeightPx: page.height)
        if let engine = gpuDescreenerIfAvailable(threads: threads) {
            let fault = gpuFaultForTesting
            do {
                let gray = try run(engine, page, geo: geo, threads: threads) { point in
                    if let error = fault?(point) { throw error }
                    if shouldStop(point) { throw PrintAppearanceError.stopped(point) }
                }
                consecutiveGPUFailures = 0
                return gray
            } catch let error as PrintAppearanceError {
                switch error {
                case .stopped, .invalidPage, .invalidParameters:
                    throw error
                case .unsupportedPage:
                    break
                case .gpuFailed, .gpuUnavailable, .allocationFailed:
                    recordGPUFailure()
                }
            } catch {
                recordGPUFailure()
            }
        }
        let engine = try cpuEngine(threads: threads)
        return try run(engine, page, geo: geo, threads: threads) { point in
            if shouldStop(point) { throw PrintAppearanceError.stopped(point) }
        }
    }

    // MARK: - 経路

    private func run(_ engine: Descreener, _ page: PrintAppearancePage, geo: Geometry, threads: Int,
                     stop: (PrintAppearanceStopPoint) throws -> Void) throws -> PrintAppearanceGray {
        let result = try page.withLuma {
            try engine.run(src: $0.baseAddress!, W: page.width, H: page.height, geo: geo, threads: threads, stop: stop)
        }
        return PrintAppearanceGray(copying: engine.output, width: page.width, height: page.height,
                                   changed: result.changed > 0)
    }

    /// GPU の経路の作業域。GPU を使えない、または今は作れないときは nil
    private func gpuDescreenerIfAvailable(threads: Int) -> Descreener? {
        guard cpuOnlyReason == nil else { return nil }
        if let gpuDescreener { return gpuDescreener }
        if gpu == nil && !canCreateGPU() { return nil }
        guard let g = gpuContext() else { return nil }
        do {
            let made = try Descreener(params: .printAppearance, a2: .printAppearance, options: .automatic, gpu: g,
                                      threads: threads)
            gpuDescreener = made
            return made
        } catch {
            recordGPUFailure()
            return nil
        }
    }

    /// パイプラインを用意する。作れなければ以後 CPU だけで動く
    private func gpuContext() -> GPUContext? {
        if let gpu { return gpu }
        do {
            let made = try GPUContext()
            gpu = made
            compileMilliseconds = made.compileMs
            return made
        } catch let PrintAppearanceError.gpuUnavailable(message) {
            becomeCPUOnly(.gpuUnavailable(message))
        } catch {
            becomeCPUOnly(.gpuUnavailable("\(error)"))
        }
        return nil
    }

    private func cpuEngine(threads: Int) throws -> Descreener {
        if let cpuDescreener { return cpuDescreener }
        let made = try Descreener(params: .printAppearance, a2: .printAppearance, options: .cpuOnly, gpu: nil,
                                  threads: threads)
        cpuDescreener = made
        return made
    }

    private func recordGPUFailure() {
        gpuFallbackPages += 1
        consecutiveGPUFailures += 1
        if consecutiveGPUFailures >= 2 { becomeCPUOnly(.repeatedGPUFailures) }
    }

    private func becomeCPUOnly(_ reason: PrintAppearanceCPUOnlyReason) {
        cpuOnlyReason = reason
        gpuDescreener = nil
        gpu = nil
    }

    // MARK: - 準備

    /// 遅延初期化の定数表に触れておく(最初のページで初期化の時間を払わないため)
    private func touchTables() {
        _ = eotf.count + encodeThresholds.count + hann.count + window2D.count + wsumPattern.count + q3EncLUT.count
    }

    /// 準備用の 256x256 の合成ページ: 2 px 角の市松模様(細かい網点のように全段を通る)
    static let warmUpPage: PrintAppearancePage = {
        let n = 256
        var luma = [UInt8](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n { luma[y * n + x] = (x / 2 + y / 2) % 2 == 0 ? 40 : 220 }
        }
        // 64 KB の領域が確保できないなら、どのページも処理できない
        return try! PrintAppearancePage(luma: luma, width: n, height: n)
    }()
}
