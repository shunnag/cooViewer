import Darwin
import Dispatch
import Foundation
import os
import PrintAppearanceKit

// 網点処理(紙の本では見分けられない細かい網点をなめらかな階調にまとめる)の実行役(設計書 §5)。
// 1 プロセスに 1 つ置き、エンジンも 1 つだけ持つ(2 つ目は作業域を倍にし、1 つの GPU 文脈を
// 2 つのエンジンで使う形は確かめていないため)。
//
// エンジンは concurrentPerform と GPU の完了待ちでブロックするので、専用の直列 DispatchQueue の上だけで
// 動かす。メインアクタ・Swift Concurrency の協調スレッド・ImageResampler のアクタには載せない
// (設計書 §7.3)。呼び出し側は継続で待つ。
// 待ち行列・数・解放の予約は 1 つのロックの中に置く。アクタにしないのは、表示の要求がメインアクタから
// 先読みの仕事を追い越すとき、並べ替えと停止の判定を同期的に済ませるため(実行中のページの停止位置から
// アクタへは問い合わせられない)。ロックは 1 ページの処理の間は持たない。
//
// 順序: 表示の仕事を新しい順(最後に触れた順)、次に先読みの仕事を到着順。
// 間引き: 本ごとに待っている表示の仕事は 4 つまで。5 つ目が来たら最も古く触れたものを Superseded で
//   終える。表示の読み込みは取り消されないので、押しっぱなしのキーでは処理より速く仕事が溜まり、
//   キーを離した後もエンジンが古いページで塞がるため。ルーペの仕事(券なし)は数えず、間引かない。
// 追い越し: 表示の仕事が来た(または先読みが表示に上がった)とき、実行中の先読みのページがパス 1 の
//   途中なら次のチャンクの境目で止め、表示の仕事を先に処理し、止めたページを先読みの先頭へ戻す。
//   パス 1 を過ぎたページは最後まで処理する(残りは短い)。
// 取り消し: 待っている仕事は外し、実行中の仕事は次の停止位置で止めて CancellationError で終える。
// 作業域の解放(コンパイル済みのパイプラインは残す): 20 秒(省エネ中は 5 秒)仕事がない、
//   400 万画素を超えるページの後に待ちも予約もない、メモリ圧迫が warning で待ちがない、critical では毎ページの後。
//   全ての窓で網点処理が切られたら(releaseAll)パイプラインも手放す。
// 作業域の予約: 表示のページはデコードの間に、そのページの大きさの作業域をこのキューで先に用意する(reserve)。
//   確保と初回の頁の割り当ては 13 MP で数十 ms かかり、起動直後の最初のページと、大きなページの後に作業域を
//   手放した後のジャンプで毎回払っていたため(設計書 §5)。
// 再計画: 先読みの計画が変わっても新しい計画に残るページの仕事は辞退させず、新しい計画の順に並べ直す(replan)。
// GPU の失敗はエンジンが同じページを CPU の厳密な経路で処理し直して返す。ここでは生の画素を返す道を
// 作らない(キャッシュのタグの下に未処理の画素が入り、超解像のディスクキャッシュまで残るため)。

/// 網点処理の要求。段階と、本のページ読み込みから来たときはその券(ルーペは券なし)
struct PrintAppearanceRequest: Sendable {
    let level: PrintAppearanceLevel
    let ticket: PrintAppearanceTicket?

    init(level: PrintAppearanceLevel, ticket: PrintAppearanceTicket? = nil) {
        self.level = level
        self.ticket = ticket
    }
}

/// キャッシュの名前空間に入れる網点処理の印(設計書 §5)。ページキャッシュの名前空間・ページキー・
/// リサンプルのキー・超解像のディスクキャッシュのキーに入る。
/// 切っているときは空文字なので、既存のキーはすべて従来のまま。入れているときは "~pa<エンジンの版><段階>"
/// (例 ~pa1s)で、要求した段階を表す(強め が 800 px 未満で 標準 に留まるページ、色のページ、処理しない
/// ページも、ファイルのバイト列とこの印で結果が決まるため、印はページごとでなく設定ごとでよい)。
/// '#' を含まないので、ページキー "<本のキー>#<ID>" の分割(ImageResampler.bookKey)を崩さない
enum PrintAppearanceTag {
    static func tag(for level: PrintAppearanceLevel?) -> String {
        guard let level else { return "" }
        let letter = switch level {
        case .low: "l"
        case .standard: "s"
        case .strong: "h"
        }
        return "~pa\(PrintAppearance.engineVersion)\(letter)"
    }
}

/// 1 回のページ読み込みと、サービスの中のその仕事を結ぶ唯一の経路(設計書 §5)。Book が読み込みごとに作る。
/// 表示の要求が合流したら touch、未開始の先読みを辞退させるときは decline を呼ぶ。
/// 仕事がまだサービスに届いていない間(デコード中)の touch・decline は券が覚え、届いたときに反映する
/// (DecodePromotion と同じ考え方)
final class PrintAppearanceTicket: Sendable {
    enum Intent: Sendable, Equatable {
        case prefetch
        case display
        case declined
    }

    private struct Binding: Sendable {
        let service: PrintAppearanceService
        let job: UInt64
    }

    private struct State: Sendable {
        var intent: Intent
        var binding: Binding?
    }

    /// 間引きは本ごとに数える(別の窓の本の表示を間引かないため)
    let book: ObjectIdentifier
    private let state: OSAllocatedUnfairLock<State>

    init(book: ObjectIdentifier, isPrefetch: Bool) {
        self.book = book
        state = OSAllocatedUnfairLock(initialState: State(intent: isPrefetch ? .prefetch : .display))
    }

    var intent: Intent { state.withLock { $0.intent } }

    /// 表示の要求が合流した: 仕事を表示の最新の位置へ動かし、先読みの仕事なら表示の仕事にする
    func touch() {
        let binding = state.withLock { state -> Binding? in
            state.intent = .display
            return state.binding
        }
        if let binding { binding.service.touch(job: binding.job) }
    }

    /// 待っている先読みの仕事を PrefetchDecodeGate.Declined で終える。表示に上がった仕事と
    /// 実行中の仕事は続ける
    func decline() {
        let binding = state.withLock { state -> Binding? in
            guard state.intent != .display else { return nil }
            state.intent = .declined
            return state.binding
        }
        if let binding { binding.service.decline(job: binding.job) }
    }

    /// 先読みの計画が変わっても、このページを新しい計画でも読む: 待っている先読みの仕事を辞退させずに
    /// 新しい計画の順へ並べ直す(呼んだ順に後ろへ付く)。表示に上がった仕事と辞退した仕事には何もしない。
    /// まだサービスに届いていなければ、届いたときの到着の順がそのまま新しい計画の順になる
    func replan() {
        let binding = state.withLock { state -> Binding? in
            state.intent == .prefetch ? state.binding : nil
        }
        if let binding { binding.service.replan(job: binding.job) }
    }

    /// サービスが仕事を受け付けるとき、サービスのロックの中から呼ぶ。その時点の意図を返す。
    /// ロックの順はサービス → 券に限る(券の側はロックを外してからサービスを呼ぶ)
    fileprivate func attach(to service: PrintAppearanceService, job: UInt64) -> Intent {
        state.withLock { state in
            state.binding = Binding(service: service, job: job)
            return state.intent
        }
    }

    fileprivate func detach() {
        state.withLock { $0.binding = nil }
    }
}

/// サービスが使うエンジンの形(テストは偽物を差し込む)。サービスの直列キューの上からだけ呼ぶ
protocol PrintAppearanceProcessing: AnyObject {
    var status: PrintAppearanceEngineStatus { get }
    func warmUp(runDummyPage: Bool, threads: Int) throws
    func reserve(width: Int, height: Int, threads: Int) throws
    func process(_ page: PrintAppearancePage, level: PrintAppearanceLevel, threads: Int,
                 shouldStop: (PrintAppearanceStopPoint) -> Bool) throws -> PrintAppearanceGray
    func releaseWorkingMemory(keepPipelines: Bool)
}

extension PrintAppearanceEngine: PrintAppearanceProcessing {}

final class PrintAppearanceService: Sendable {
    static let shared = PrintAppearanceService()

    /// 本ごとの表示の待ちが上限を超え、最も古く触れた仕事として間引かれた。
    /// Book は何もキャッシュせず、要求がまだ有効なら読み込み直す(設計書 §5)
    struct Superseded: Error {}

    fileprivate typealias Continuation = CheckedContinuation<PrintAppearanceGray, any Error>

    struct Configuration: Sendable {
        /// 処理する画素数の上限(超えるページは素通し)。マシンごとに固定
        var maxPixels = PrintAppearance.defaultMaxPixels
        /// 本ごとに待てる表示の仕事の数
        var displayWaitLimit = 4
        /// 表示・ルーペ・準備の並列数: 全てのコア(16 まで)。利用者が待つページなので高効率コアも使う。
        /// 13.4 MP のページで 8 から 16 にするとエンジンが 15〜17% 短くなる(M4 Max、12 + 4 コアで 221 → 183 ms。
        /// 設計書 §5 の min(8, 高性能コアの数) からの変更)。高性能コアが 6 つの Mac では 6 から 10 になる
        var displayThreads = min(16, max(1, ProcessInfo.processInfo.activeProcessorCount))
        /// 先読みの並列数: min(8, 高性能コアの数)。4 では 8 の 1.3〜1.4 倍の時間がかかり(11.1 MP で 294〜308 ms
        /// に対して 210〜222 ms、M4 Max で実測)、1 秒に 1 回の見開きのページ送りに先読みが追いつかない。
        /// ページあたりの CPU 時間はほぼ同じ
        var prefetchThreads = min(8, PrintAppearanceService.performanceCoreCount())
        /// 省エネ中の先読みの並列数
        var conservingPrefetchThreads = 2
        /// 仕事がないまま作業域を手放すまでの時間(作り直しは数 ms)
        var idleRelease: Duration = .seconds(20)
        var conservingIdleRelease: Duration = .seconds(5)
        /// これを超える画素数のページを処理した後、待ちがなければ作業域を手放す
        var largePagePixels = 4_000_000
    }

    /// 稼働状況の表示用の写し。実在する値だけを載せる
    struct Stats: Sendable, Equatable {
        /// エンジンの状態。まだ作っていなければ nil
        var engine: PrintAppearanceEngineStatus?
        var isWarmingUp = false
        var waitingDisplay = 0
        var waitingPrefetch = 0
        var isRunning = false
        /// エンジンが処理したページ(うち、1 画素も変えなかったもの)
        var processedPages = 0
        var unchangedPages = 0
        /// CPU の経路でも断られたページ(決定的な素通しになる)
        var refusedPages = 0
        /// 断り以外の失敗で終わったページ
        var failedPages = 0
        /// prepare が素通しにしたページの理由ごとの数(デコードの入口が知らせる)
        var passedThrough: [PrintAppearancePassReason: Int] = [:]
        var shedJobs = 0
        var preemptions = 0
        var promotions = 0
        var declinedJobs = 0
        /// 先読みの計画が変わっても辞退させずに並べ直した仕事
        var replannedJobs = 0
        var cancelledJobs = 0
        var storeReleases = 0
        /// 表示のページのデコードの間に作業域を予約した回数
        var reservations = 0
        var lastWaitMilliseconds: Double?
        var lastEngineMilliseconds: Double?
        var lastWarmUpMilliseconds: Double?
        /// 直近 timingWindow ページの中央値(待ち・エンジン)
        var medianWaitMilliseconds: Double?
        var medianEngineMilliseconds: Double?
        /// 処理したページの、ゲートの中のデコードと prepare(最後と中央値)
        var lastPrepareMilliseconds: Double?
        var medianPrepareMilliseconds: Double?
        /// 処理したページの、デコードの入口に入ってから完成画像までの全体(最後と中央値)
        var lastPageMilliseconds: Double?
        var medianPageMilliseconds: Double?
    }

    /// 中央値を取る直近のページ数
    static let timingWindow = 32

    let configuration: Configuration
    var maxPixels: Int { configuration.maxPixels }

    private let queue: DispatchQueue
    private let slot: EngineSlot
    private let state: OSAllocatedUnfairLock<State>
    private let power: any PowerStateProviding
    private let scheduler: DelayedScheduler
    private let pressureObservation: MemoryPressureObservation

    init(configuration: Configuration = Configuration(),
         makeEngine: @escaping @Sendable () -> any PrintAppearanceProcessing = {
             PrintAppearanceEngine(mode: .automatic, canCreateGPU: { FileDescriptorHeadroom.isAvailable() })
         },
         power: any PowerStateProviding = PowerStateMonitor.shared,
         pressure: any MemoryPressureProviding = MemoryPressureMonitor.shared,
         center: NotificationCenter = .default,
         scheduler: DelayedScheduler = .task) {
        self.configuration = configuration
        self.power = power
        self.scheduler = scheduler
        // QoS は仕事ごとに付ける。workItem: Metal のコマンドバッファなどの自動解放をページごとに返す
        let queue = DispatchQueue(label: "jp.coo.cooViewer.print-appearance", autoreleaseFrequency: .workItem)
        self.queue = queue
        slot = EngineSlot(queue: queue, make: makeEngine)
        state = OSAllocatedUnfairLock(initialState: State(pressure: pressure.memoryPressureLevel))
        pressureObservation = MemoryPressureObservation(center: center)
        // 通知は圧迫源の utility キューで届く。ロックの中で段階を置き、解放はキューへ積む
        pressureObservation.setHandler({ [weak self] provider in
            self?.applyMemoryPressure(provider.memoryPressureLevel)
        }, provider: pressure)
    }

    func stats() -> Stats {
        state.withLock { state in
            var stats = state.stats
            stats.waitingDisplay = state.jobs.values.count(where: { $0.phase == .waiting && $0.isDisplay })
            stats.waitingPrefetch = state.jobs.values.count(where: { $0.phase == .waiting && !$0.isDisplay })
            stats.isRunning = state.running != nil
            stats.isWarmingUp = state.warmUp == .running
            stats.medianWaitMilliseconds = state.waitSamples.median
            stats.medianEngineMilliseconds = state.engineSamples.median
            stats.lastPrepareMilliseconds = state.prepareSamples.last
            stats.medianPrepareMilliseconds = state.prepareSamples.median
            stats.lastPageMilliseconds = state.pageSamples.last
            stats.medianPageMilliseconds = state.pageSamples.median
            return stats
        }
    }

    // MARK: - ページ

    /// 1 ページを処理する。券の意図で表示か先読みかを決め、券がなければ(ルーペ)表示として扱い間引かない。
    /// 待ちの間に間引かれたら Superseded、辞退させられたら PrefetchDecodeGate.Declined、
    /// 呼び出し側が取り消されたら CancellationError を投げる。エンジンの例外はそのまま投げる
    func process(_ page: PrintAppearancePage, request: PrintAppearanceRequest) async throws -> PrintAppearanceGray {
        try Task.checkCancellation()
        // 継続を渡す前に席を取る: 取り消しがそれより先に届いても、席に印を残して確実に終えられるように
        let id = state.withLock { state in
            state.nextJob += 1
            state.jobs[state.nextJob] = Job(page: page, level: request.level, ticket: request.ticket,
                                            queuedAt: .now)
            return state.nextJob
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.register(id, continuation: continuation)
            }
        } onCancel: {
            self.cancel(job: id)
        }
    }

    /// デコードの入口が prepare の素通しを知らせる(集計だけ)
    func recordPassThrough(_ reason: PrintAppearancePassReason) {
        state.withLock { $0.stats.passedThrough[reason, default: 0] += 1 }
    }

    /// デコードの入口が処理したページの所要時間を知らせる(稼働状況の表示用。集計だけ)
    func recordProcessedPage(prepare: Duration, total: Duration) {
        state.withLock { state in
            state.prepareSamples.append(prepare.milliseconds)
            state.pageSamples.append(total.milliseconds)
        }
    }

    private func register(_ id: UInt64, continuation: Continuation) {
        let limit = configuration.displayWaitLimit
        let outcome = state.withLock { state -> Registration in
            guard var job = state.jobs[id] else { return .finished(.failure(CancellationError())) }
            if job.cancelled {
                state.jobs[id] = nil
                state.stats.cancelledJobs += 1
                return .finished(.failure(CancellationError()))
            }
            switch job.ticket?.attach(to: self, job: id) ?? .display {
            case .declined:
                state.jobs[id] = nil
                job.ticket?.detach()
                state.stats.declinedJobs += 1
                return .finished(.failure(PrefetchDecodeGate.Declined()))
            case .display:
                job.isDisplay = true
                state.nextTouch += 1
                job.touch = state.nextTouch
            case .prefetch:
                job.isDisplay = false
                state.nextArrival += 1
                job.arrival = state.nextArrival
            }
            job.phase = .waiting
            job.continuation = continuation
            state.jobs[id] = job
            let shed = state.shedExcessDisplay(of: job.ticket?.book, limit: limit)
            return .queued(isDisplay: job.isDisplay, shed: shed)
        }
        switch outcome {
        case .finished(let result):
            continuation.resume(with: result)
        case .queued(let isDisplay, let shed):
            for shedJob in shed { shedJob.resume(throwing: Superseded()) }
            submitRunBlock(display: isDisplay)
        }
    }

    private enum Registration: Sendable {
        case finished(Result<PrintAppearanceGray, any Error>)
        case queued(isDisplay: Bool, shed: [Continuation])
    }

    private func cancel(job id: UInt64) {
        let continuation = state.withLock { state -> Continuation? in
            guard var job = state.jobs[id] else { return nil }
            switch job.phase {
            case .registering, .running:
                // 登録前は登録のときに、実行中は次の停止位置で終える
                job.cancelled = true
                state.jobs[id] = job
                return nil
            case .waiting:
                state.jobs[id] = nil
                job.ticket?.detach()
                state.stats.cancelledJobs += 1
                return job.continuation
            }
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// 券から: 表示の最新へ動かす。待っている先読みの仕事なら表示へ上げ、実行中の先読みも以後は追い越されない
    fileprivate func touch(job id: UInt64) {
        let limit = configuration.displayWaitLimit
        let outcome = state.withLock { state -> (promoted: Bool, shed: [Continuation])? in
            guard var job = state.jobs[id], !job.cancelled else { return nil }
            let promoted = !job.isDisplay
            job.isDisplay = true
            state.nextTouch += 1
            job.touch = state.nextTouch
            state.jobs[id] = job
            if promoted { state.stats.promotions += 1 }
            guard job.phase == .waiting else { return (false, []) }
            return (promoted, state.shedExcessDisplay(of: job.ticket?.book, limit: limit))
        }
        guard let outcome else { return }
        for shedJob in outcome.shed { shedJob.resume(throwing: Superseded()) }
        // 先読みとして積んだ実行の枠は utility なので、表示の QoS の枠を足す(余った枠は何もしない)
        if outcome.promoted { submitRunBlock(display: true) }
    }

    /// 券から: 待っている先読みの仕事だけを辞退させる
    fileprivate func decline(job id: UInt64) {
        let continuation = state.withLock { state -> Continuation? in
            guard let job = state.jobs[id], job.phase == .waiting, !job.isDisplay else { return nil }
            state.jobs[id] = nil
            job.ticket?.detach()
            state.stats.declinedJobs += 1
            return job.continuation
        }
        continuation?.resume(throwing: PrefetchDecodeGate.Declined())
    }

    /// 券から: 待っている先読みの仕事に新しい到着の番号を付け、新しい計画の順へ並べ直す
    fileprivate func replan(job id: UInt64) {
        state.withLock { state in
            guard var job = state.jobs[id], job.phase == .waiting, !job.isDisplay, !job.cancelled else { return }
            state.nextArrival += 1
            job.arrival = state.nextArrival
            state.jobs[id] = job
            state.stats.replannedJobs += 1
        }
    }

    // MARK: - 作業域の予約

    /// 表示のページのデコードの間に、そのページの作業域をエンジンのキューで先に用意する(設計書 §5)。
    /// ページの仕事より先にキューへ積まれるので、確保はデコードと並んで進み、ページはそのまま処理を始められる。
    /// 色のページになりうる(ヘッダがグレーでない)ページは、このプロセスでまだ 1 ページも処理していなければ
    /// 予約しない(色の本では使わない作業域を持たないため)。メモリ圧迫が critical なら予約しない。
    /// 予約したページがエンジンまで来なくても(色・取り消し・間引き)、予約の後に仕事がなければ解放の予約を立てる
    func reserve(width: Int, height: Int, colourPossible: Bool) {
        let accepted = state.withLock { state -> Bool in
            guard state.pressure != .critical, !colourPossible || state.stats.processedPages > 0 else { return false }
            state.pendingReservations += 1
            state.stats.reservations += 1
            return true
        }
        guard accepted else { return }
        let threads = configuration.displayThreads
        queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
            let engine = slot.engine()
            // 失敗してもページの処理がその場で確保し直す(GPU の失敗の扱いもそちらに任せる)
            try? engine.reserve(width: width, height: height, threads: threads)
            let status = engine.status
            state.withLock { state in
                state.pendingReservations -= 1
                state.stats.engine = status
            }
            scheduleIdleReleaseIfQuiet()
        }
    }

    // MARK: - 実行

    /// 待っている仕事 1 つにつき実行の枠を 1 つ積む。枠は実行するときに最も優先する仕事を選ぶので、
    /// 枠の順と仕事の順は一致しなくてよい(外された仕事の枠は何もせずに終わる)。
    /// 表示の枠は userInitiated、先読みの枠は utility で積む(設計書 §5)
    private func submitRunBlock(display: Bool) {
        if display {
            queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in runNext(inDisplayBlock: true) }
        } else {
            queue.async(qos: .utility) { [self] in runNext(inDisplayBlock: false) }
        }
    }

    private enum Start: Sendable {
        case idle
        /// 表示の枠で先読みの仕事しか待っていない: 先読みの枠へ回す
        case deferToPrefetchBlock
        case run(Pick, cancelIdle: DelayedScheduler.Cancel?)
    }

    /// 枠の QoS は積んだときの仕事のもので、選ぶ仕事と食い違うことがある(先に積んだ先読みの枠が後から来た
    /// 表示の仕事を拾い、表示の枠には先読みの仕事が残る)。表示の仕事は userInitiated に引き上げて同じ
    /// スレッドで処理し(concurrentPerform の作業者はこのスレッドの QoS に合わせて走る)、表示の枠は先読みの
    /// 仕事を処理せず utility の枠を積み直す。引き上げはできても引き下げはできないため(設計書 §5)
    private func runNext(inDisplayBlock: Bool) {
        let conserving = power.shouldConserveEnergy
        let configuration = configuration
        let start = state.withLock { state -> Start in
            if let pick = state.startNext(configuration: configuration, conserving: conserving,
                                          allowPrefetch: !inDisplayBlock) {
                return .run(pick, cancelIdle: state.invalidateIdleRelease())
            }
            return state.hasWaitingJob ? .deferToPrefetchBlock : .idle
        }
        switch start {
        case .idle:
            scheduleIdleReleaseIfQuiet()
        case .deferToPrefetchBlock:
            submitRunBlock(display: false)
        case .run(let pick, let cancelIdle):
            cancelIdle?()
            if pick.isDisplay && !inDisplayBlock {
                DispatchWorkItem(qos: .userInitiated, flags: .enforceQoS) { [self] in execute(pick) }.perform()
            } else {
                execute(pick)
            }
        }
    }

    /// 選んだ 1 ページをエンジンで処理し、結果を返すか先読みの先頭へ戻す(キューの上)
    private func execute(_ pick: Pick) {
        let engine = slot.engine()
        let clock = ContinuousClock()
        let begin = clock.now
        let result: Result<PrintAppearanceGray, any Error>
        do {
            result = .success(try engine.process(pick.page, level: pick.level, threads: pick.threads) { point in
                shouldStop(job: pick.id, at: point)
            })
        } catch {
            result = .failure(error)
        }
        let elapsed = clock.now - begin
        let status = engine.status
        let outcome = state.withLock { $0.finish(pick.id, result: result, elapsed: elapsed, status: status) }
        switch outcome {
        case .resume(let continuation, let result):
            continuation?.resume(with: result)
        case .requeued(let isDisplay):
            submitRunBlock(display: isDisplay)
        case .none:
            break
        }
        releaseAfterPage(engine, pixels: pick.page.width * pick.page.height)
        scheduleIdleReleaseIfQuiet()
    }

    /// エンジンの停止位置から(キューの上で)呼ばれる。取り消された仕事はどの位置でも止める。
    /// 先読みの仕事は、表示の仕事が待っていればパス 1 の間だけ止める(設計書 §5)
    private func shouldStop(job id: UInt64, at point: PrintAppearanceStopPoint) -> Bool {
        state.withLock { state in
            guard let job = state.jobs[id] else { return true }
            if job.cancelled { return true }
            guard !job.isDisplay, point == .beforeRun || point == .betweenPass1Chunks else { return false }
            return state.jobs.values.contains { $0.phase == .waiting && $0.isDisplay }
        }
    }

    // MARK: - 準備と解放

    /// 最初のページを待たせないための準備を 1 度だけ積む: エンジンを作り、定数表に触れ、パイプラインを
    /// コンパイルし、省エネ中でなければ 256x256 の合成ページを 1 枚処理する。
    /// コンパイルは userInitiated で積む(実行中の枠には後から優先度の引き上げが届かず、utility の
    /// コンパイルの後ろで最初のページが待つのが最悪の場合のため)。準備の間に来たページは同じ直列キューで
    /// その後ろに並ぶので、二重にコンパイルしない
    func prepareIfNeeded() {
        let start = state.withLock { state -> Bool in
            // まだ走っていない releaseAll を取り消す(切ってすぐ入れ直したとき、後からキューで走る解放が
            // 入れている間のパイプラインを捨てないように)
            state.releaseGeneration &+= 1
            guard state.warmUp == .none else { return false }
            state.warmUp = .running
            return true
        }
        guard start else { return }
        let runDummyPage = !power.shouldConserveEnergy
        let threads = configuration.displayThreads
        queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
            // 積んだ後に releaseAll が来ていたら(すぐ切られた)準備しない。続く解放が手放すものを作らないため
            guard state.withLock({ $0.warmUp == .running }) else { return }
            let engine = slot.engine()
            let clock = ContinuousClock()
            let begin = clock.now
            // 失敗しても次のページがその場で用意する(GPU を使えなければエンジンが CPU だけになる)
            _ = try? engine.warmUp(runDummyPage: runDummyPage, threads: threads)
            let elapsed = clock.now - begin
            let status = engine.status
            state.withLock { state in
                // 準備の間に releaseAll が準備前へ戻していたら、そのままにする(次の prepareIfNeeded が積み直す)
                if state.warmUp == .running { state.warmUp = .done }
                state.stats.lastWarmUpMilliseconds = elapsed.milliseconds
                state.stats.engine = status
            }
            scheduleIdleReleaseIfQuiet()
        }
    }

    /// 全ての窓で網点処理が切られたとき: 作業域と GPU のパイプラインを手放す。
    /// CPU だけで動く理由はエンジンが保つ(GPU の失敗が続いたプロセスでは戻さない)。
    /// 準備の状態はここで準備前へ戻し、解放はキューで行う。キューで走る前に prepareIfNeeded が来たら
    /// (切ってすぐ入れ直した)解放しない
    func releaseAll() {
        let generation = state.withLock { state -> UInt64 in
            state.releaseGeneration &+= 1
            state.warmUp = .none
            return state.releaseGeneration
        }
        queue.async(qos: .utility) { [self] in
            guard state.withLock({ $0.releaseGeneration == generation }) else { return }
            let engine = slot.existing
            engine?.releaseWorkingMemory(keepPipelines: false)
            let status = engine?.status
            let hadEngine = engine != nil
            let cancelIdle = state.withLock { state -> DelayedScheduler.Cancel? in
                // 解放の前に処理したページが準備済みにしていたら、準備前へ戻す
                // (解放の間に prepareIfNeeded が来ていれば、その状態を保つ)
                if state.releaseGeneration == generation { state.warmUp = .none }
                if hadEngine {
                    state.stats.storeReleases += 1
                    state.stats.engine = status
                }
                return state.invalidateIdleRelease()
            }
            cancelIdle?()
        }
    }

    /// ページの後の解放の規則(キューの上)
    private func releaseAfterPage(_ engine: any PrintAppearanceProcessing, pixels: Int) {
        let largePage = pixels > configuration.largePagePixels
        let release = state.withLock { state -> Bool in
            // 予約が積まれていれば、すぐ来る表示のページのために残す
            let quiet = !state.hasWaitingJob && state.pendingReservations == 0
            switch state.pressure {
            case .critical: return true
            case .warning: return quiet
            case .normal: return quiet && largePage
            }
        }
        guard release, engine.status.workingBytes > 0 else { return }
        releaseStores(engine)
    }

    private func releaseStores(_ engine: any PrintAppearanceProcessing) {
        engine.releaseWorkingMemory(keepPipelines: true)
        let status = engine.status
        state.withLock { state in
            state.stats.storeReleases += 1
            state.stats.engine = status
        }
    }

    /// 待ちも実行中の仕事もなければ、一定時間後に作業域を手放す予約を立てる(キューの上)。
    /// 予約は世代で照合し、その間に仕事が始まっていれば何もしない
    private func scheduleIdleReleaseIfQuiet() {
        guard let engine = slot.existing, engine.status.workingBytes > 0 else { return }
        let delay = power.shouldConserveEnergy ? configuration.conservingIdleRelease : configuration.idleRelease
        let reservation = state.withLock { state -> (generation: UInt64, previous: DelayedScheduler.Cancel?)? in
            guard state.isQuiet else { return nil }
            let previous = state.invalidateIdleRelease()
            return (state.idleGeneration, previous)
        }
        guard let reservation else { return }
        reservation.previous?()
        let generation = reservation.generation
        let cancel = scheduler.schedule(delay) { [weak self] in
            guard let self else { return }
            queue.async(qos: .utility) { [self] in releaseIfStillIdle(generation: generation) }
        }
        let stale = state.withLock { state -> Bool in
            guard state.idleGeneration == generation else { return true }
            state.idleCancel = cancel
            return false
        }
        if stale { cancel() }
    }

    private func releaseIfStillIdle(generation: UInt64) {
        let idle = state.withLock { state -> Bool in
            guard state.idleGeneration == generation, state.isQuiet else { return false }
            state.idleCancel = nil
            return true
        }
        guard idle, let engine = slot.existing, engine.status.workingBytes > 0 else { return }
        releaseStores(engine)
    }

    /// 圧迫の段階を置く。warning 以上で仕事がなければ、すぐ作業域を手放す
    private func applyMemoryPressure(_ level: MemoryPressureLevel) {
        let releaseNow = state.withLock { state -> Bool in
            state.pressure = level
            return level != .normal && state.isQuiet
        }
        guard releaseNow else { return }
        queue.async(qos: .utility) { [self] in
            guard state.withLock({ $0.isQuiet }), let engine = slot.existing,
                  engine.status.workingBytes > 0 else { return }
            releaseStores(engine)
        }
    }

    /// テスト用: ここまでにキューへ積んだ枠が終わるのを待つ
    func flushForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async(qos: .userInitiated) { continuation.resume() }
        }
    }

    /// テスト用: エンジンを動かすキューの名前
    var queueLabelForTesting: String { queue.label }

    /// 高性能コアの論理 CPU 数(読めなければ全体の数)
    static func performanceCoreCount() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 { return Int(value) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }
}

// MARK: - 内部の状態

private extension PrintAppearanceService {
    struct Job: Sendable {
        enum Phase: Sendable {
            /// 席を取ったが継続をまだ受け取っていない
            case registering
            case waiting
            case running
        }

        let page: PrintAppearancePage
        let level: PrintAppearanceLevel
        let ticket: PrintAppearanceTicket?
        let queuedAt: ContinuousClock.Instant
        var phase = Phase.registering
        var isDisplay = true
        var cancelled = false
        /// 表示の順: 最後に触れた番号(大きいほど新しい)
        var touch: UInt64 = 0
        /// 先読みの順: 到着の番号(小さいほど先)。追い越されたページは先頭より小さい番号で戻る
        var arrival: Int64 = 0
        var continuation: Continuation?

        init(page: PrintAppearancePage, level: PrintAppearanceLevel, ticket: PrintAppearanceTicket?,
             queuedAt: ContinuousClock.Instant) {
            self.page = page
            self.level = level
            self.ticket = ticket
            self.queuedAt = queuedAt
        }
    }

    struct Pick: Sendable {
        let id: UInt64
        let page: PrintAppearancePage
        let level: PrintAppearanceLevel
        let isDisplay: Bool
        let threads: Int
    }

    enum Finish: Sendable {
        case resume(Continuation?, Result<PrintAppearanceGray, any Error>)
        case requeued(isDisplay: Bool)
        case none
    }

    enum WarmUp: Sendable {
        case none
        case running
        case done
    }

    struct State: Sendable {
        var jobs: [UInt64: Job] = [:]
        var nextJob: UInt64 = 0
        var nextTouch: UInt64 = 0
        var nextArrival: Int64 = 0
        var headArrival: Int64 = 0
        var running: UInt64?
        var pressure: MemoryPressureLevel
        var warmUp = WarmUp.none
        /// releaseAll の世代。prepareIfNeeded が進めると、積んだままの解放は何もしない
        var releaseGeneration: UInt64 = 0
        var waitSamples = TimingSamples()
        var engineSamples = TimingSamples()
        var prepareSamples = TimingSamples()
        var pageSamples = TimingSamples()
        var idleGeneration: UInt64 = 0
        var idleCancel: DelayedScheduler.Cancel?
        /// キューに積んでまだ終わっていない作業域の予約
        var pendingReservations = 0
        var stats = Stats()

        init(pressure: MemoryPressureLevel) {
            self.pressure = pressure
        }

        var hasWaitingJob: Bool { jobs.values.contains { $0.phase == .waiting } }
        var isQuiet: Bool { running == nil && !hasWaitingJob && pendingReservations == 0 }

        /// 最も優先する待ちの仕事を実行中にする: 表示を新しい順、次に先読みを到着順。
        /// allowPrefetch が偽なら表示の仕事だけを選ぶ
        mutating func startNext(configuration: Configuration, conserving: Bool, allowPrefetch: Bool) -> Pick? {
            let waiting = jobs.filter { $0.value.phase == .waiting }
            var chosen = waiting.filter { $0.value.isDisplay }.max { $0.value.touch < $1.value.touch }
            if chosen == nil, allowPrefetch {
                chosen = waiting.min { $0.value.arrival < $1.value.arrival }
            }
            guard let chosen else { return nil }
            let id = chosen.key
            var job = chosen.value
            job.phase = .running
            jobs[id] = job
            running = id
            let wait = (ContinuousClock.now - job.queuedAt).milliseconds
            stats.lastWaitMilliseconds = wait
            waitSamples.append(wait)
            let threads = job.isDisplay ? configuration.displayThreads
                : (conserving ? configuration.conservingPrefetchThreads : configuration.prefetchThreads)
            return Pick(id: id, page: job.page, level: job.level, isDisplay: job.isDisplay, threads: threads)
        }

        /// 1 ページが終わった。止めたのが取り消しでなければ(追い越し)先読みの先頭へ戻す
        mutating func finish(_ id: UInt64, result: Result<PrintAppearanceGray, any Error>, elapsed: Duration,
                             status: PrintAppearanceEngineStatus) -> Finish {
            running = nil
            stats.engine = status
            // 最初のページはエンジンがその場で準備したので、改めて準備を積まない
            if warmUp == .none { warmUp = .done }
            guard var job = jobs[id] else { return .none }
            if case .failure(let error) = result, let error = error as? PrintAppearanceError,
               case .stopped = error, !job.cancelled {
                stats.preemptions += 1
                // 実行中に辞退された先読みは、止めた時点で待ちに戻るので、待っている先読みと同じく辞退で終える
                if !job.isDisplay, job.ticket?.intent == .declined {
                    jobs[id] = nil
                    job.ticket?.detach()
                    stats.declinedJobs += 1
                    return .resume(job.continuation, .failure(PrefetchDecodeGate.Declined()))
                }
                job.phase = .waiting
                headArrival = min(headArrival, job.arrival) - 1
                job.arrival = headArrival
                jobs[id] = job
                return .requeued(isDisplay: job.isDisplay)
            }
            jobs[id] = nil
            job.ticket?.detach()
            if job.cancelled {
                stats.cancelledJobs += 1
                return .resume(job.continuation, .failure(CancellationError()))
            }
            switch result {
            case .success(let gray):
                stats.processedPages += 1
                if !gray.changed { stats.unchangedPages += 1 }
                stats.lastEngineMilliseconds = elapsed.milliseconds
                engineSamples.append(elapsed.milliseconds)
            case .failure(let error):
                if case .unsupportedPage? = error as? PrintAppearanceError {
                    stats.refusedPages += 1
                } else {
                    stats.failedPages += 1
                }
            }
            return .resume(job.continuation, result)
        }

        /// 本ごとの待っている表示の仕事を上限まで減らす。最も古く触れたものから外し、その継続を返す。
        /// 券のない仕事(ルーペ)は数えない
        mutating func shedExcessDisplay(of book: ObjectIdentifier?, limit: Int) -> [Continuation] {
            guard let book else { return [] }
            var shed: [Continuation] = []
            while true {
                let candidates = jobs.filter {
                    $0.value.phase == .waiting && $0.value.isDisplay && $0.value.ticket?.book == book
                }
                guard candidates.count > limit,
                      let oldestEntry = candidates.min(by: { $0.value.touch < $1.value.touch }) else { break }
                let oldest = oldestEntry.value
                jobs[oldestEntry.key] = nil
                oldest.ticket?.detach()
                stats.shedJobs += 1
                if let continuation = oldest.continuation { shed.append(continuation) }
            }
            return shed
        }

        /// 解放の予約を無効にし(世代を進める)、取り消し手段を返す
        mutating func invalidateIdleRelease() -> DelayedScheduler.Cancel? {
            idleGeneration += 1
            defer { idleCancel = nil }
            return idleCancel
        }
    }

    /// 所要時間の直近 timingWindow 件(古いものから上書きする)。中央値だけを出す
    struct TimingSamples: Sendable {
        private var values: [Double] = []
        private var next = 0
        private(set) var last: Double?

        mutating func append(_ value: Double) {
            last = value
            if values.count < PrintAppearanceService.timingWindow {
                values.append(value)
            } else {
                values[next] = value
            }
            next = (next + 1) % PrintAppearanceService.timingWindow
        }

        /// 偶数件では中央の 2 つの平均
        var median: Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
    }

    /// Sendable でないエンジンを 1 つ入れる箱(設計書 §5)。中身はサービスの直列キューの上からだけ作り、触る。
    /// その不変条件があるので @unchecked Sendable とする
    final class EngineSlot: @unchecked Sendable {
        private let queue: DispatchQueue
        private let make: @Sendable () -> any PrintAppearanceProcessing
        private var current: (any PrintAppearanceProcessing)?

        init(queue: DispatchQueue, make: @escaping @Sendable () -> any PrintAppearanceProcessing) {
            self.queue = queue
            self.make = make
        }

        /// エンジン(なければ作る)
        func engine() -> any PrintAppearanceProcessing {
            #if DEBUG
            dispatchPrecondition(condition: .onQueue(queue))
            #endif
            if let current { return current }
            let made = make()
            current = made
            return made
        }

        /// 作ってあればそのエンジン
        var existing: (any PrintAppearanceProcessing)? {
            #if DEBUG
            dispatchPrecondition(condition: .onQueue(queue))
            #endif
            return current
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
