import Darwin
import Dispatch
import Foundation
import os

/// OS が報告するメモリ圧迫の段階(設計書 §5)。
enum MemoryPressureLevel: Sendable, CaseIterable {
    case normal
    case warning
    case critical

    /// DispatchSource の OptionSet を段階へ写す。critical > warning > normal の順に見て、
    /// どれも含まない通知(ありえないが)は nil = 変化なしとして無視する。
    init?(event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            self = .critical
        } else if event.contains(.warning) {
            self = .warning
        } else if event.contains(.normal) {
            self = .normal
        } else {
            return nil
        }
    }

    /// sysctl `kern.memorystatus_vm_pressure_level` の生値を段階へ写す(設計書 §5):
    /// 1 normal / 2 warning / 4 critical。xnu のソースでは 3 = urgent(公開 SDK には定義が
    /// 無く、実際に報告される値でもない)。warning と critical の間の値で上限を緩めないよう
    /// warning 扱いにする。0(未初期化)と未知の値は normal。
    init(systemPressureValue value: Int32) {
        switch value {
        case 2, 3: self = .warning
        case 4: self = .critical
        default: self = .normal
        }
    }

    /// システム全体の圧迫段階を sysctl で読む(権限不要・非ブロッキング)。sysctl が失敗した
    /// か想定外の大きさを返したときは nil(観測なし)。
    static func readSystemWide() -> MemoryPressureLevel? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else {
            return nil
        }
        return MemoryPressureLevel(systemPressureValue: value)
    }
}

/// 全キャッシュと書庫の復号予算が参照する唯一のメモリ圧迫判定(設計書 §5)。
/// PowerStateProviding と同じ形で、テストは固定値の提供者へ差し替える。
protocol MemoryPressureProviding: Sendable {
    var memoryPressureLevel: MemoryPressureLevel { get }
}

/// テストは実行機のメモリ状態に依存せず、提供者を差し替えられる。
struct FixedMemoryPressure: MemoryPressureProviding {
    let memoryPressureLevel: MemoryPressureLevel

    init(_ level: MemoryPressureLevel = .normal) {
        memoryPressureLevel = level
    }
}

/// 設定上の上限(configured)を圧迫段階に応じた実効上限へ写す純関数(設計書 §5)。
/// 各キャッシュは段階変化で実効上限まで追い出し、normal が報告されるまで下げたまま
/// 保つ。旧実装の trimToHalf は上限を変えなかったため、先読みが即座にキャッシュを
/// 埋め直して圧迫が解けなかった。
enum MemoryBudgetPolicy {
    /// warning は「このままだと逼迫する」段階: 半分に下げれば先読みの大半は保ちつつ
    /// OS に返す量が出る。
    static let warningDivisor = 2
    /// critical は「既にスワップ・jetsam の圏内」: 表示中スプレッド+隣接ぶんが残る
    /// 1/4 まで下げ、再デコードの往復より解放を優先する。
    static let criticalDivisor = 4

    /// 整数除算は切り捨て。空キャッシュ(0 バイト)を作らないよう下限は 1 バイト。
    static func effectiveLimit(configured: Int, level: MemoryPressureLevel) -> Int {
        let divisor = switch level {
        case .normal: 1
        case .warning: warningDivisor
        case .critical: criticalDivisor
        }
        return max(1, configured / divisor)
    }
}

/// 圧迫通知の購読を一つの Sendable な値に閉じ込める(設計書 §5)。
/// 所有者(actor / @MainActor クラス)の init は self を閉包へ渡した後にストアドプロパティへ
/// 書けず、非 Sendable な購読トークンを直接持つと nonisolated な deinit から外せない。
/// 購読はここで先に作り、処理は所有者の init 完了後に setHandler で差し込む。
/// handler には段階ではなく**提供者**を渡す: 所有者は自分の隔離へ跳んだ後に
/// `provider.memoryPressureLevel` を読むので、跳ぶ順序が入れ替わっても最新の段階が適用される。
final class MemoryPressureObservation: @unchecked Sendable {
    typealias Handler = @Sendable (any MemoryPressureProviding) -> Void
    private struct Subscriber {
        let handler: Handler
        let provider: any MemoryPressureProviding
    }

    private let center: NotificationCenter
    private let subscriber: OSAllocatedUnfairLock<Subscriber?>
    private let token: any NSObjectProtocol

    init(center: NotificationCenter) {
        let subscriber = OSAllocatedUnfairLock<Subscriber?>(initialState: nil)
        self.center = center
        self.subscriber = subscriber
        // 通知の object は提供者(監視器、テストでは固定値)。無ければ注入された提供者に
        // 落とす。通知は圧迫源の utility キューで届くため、所有者側の handler が隔離へ跳ぶ
        token = center.addObserver(
            forName: MemoryPressureMonitor.didChangeNotification, object: nil, queue: nil
        ) { @Sendable notification in
            guard let current = subscriber.withLock({ $0 }) else { return }
            current.handler((notification.object as? any MemoryPressureProviding) ?? current.provider)
        }
    }

    deinit {
        center.removeObserver(token)
    }

    /// handler を登録し、注入された提供者で一度呼ぶ(所有者の init で現在値を読んでから
    /// 購読が立つまでの間に起きた変化を取り込む。PowerStateMonitor.init と同じ考え方)
    func setHandler(_ handler: @escaping Handler, provider: any MemoryPressureProviding) {
        subscriber.withLock { $0 = Subscriber(handler: handler, provider: provider) }
        handler(provider)
    }
}

/// 一定間隔で繰り返し実行し、取り消せる予約の注入点(DelayedScheduler の繰り返し版)。
/// 製品は utility キューの DispatchSourceTimer、テストは記録した tick を手で発火させて
/// 時計に依存しない。
struct PeriodicScheduler: Sendable {
    typealias Cancel = @Sendable () -> Void
    let schedule: @Sendable (_ interval: Duration, _ leeway: Duration,
                             _ tick: @escaping @Sendable () -> Void) -> Cancel

    static let dispatchTimer = PeriodicScheduler { interval, leeway, tick in
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval.dispatchInterval,
                       repeating: interval.dispatchInterval, leeway: leeway.dispatchInterval)
        // MemoryPressureMonitor.init の圧迫源と同じ理由で @Sendable を明示する
        timer.setEventHandler { @Sendable in tick() }
        timer.activate()
        return { timer.cancel() }
    }
}

private extension Duration {
    /// DispatchSourceTimer は DispatchTimeInterval を取る。ミリ秒精度で十分(秒単位の間隔)
    var dispatchInterval: DispatchTimeInterval { .milliseconds(Int(self / .milliseconds(1))) }
}

/// アプリに一つのメモリ圧迫源(設計書 §5)。観測源は二つ — システム全体の段階
/// `kern.memorystatus_vm_pressure_level`(init で種を蒔き、utility キューのタイマーで
/// 読み直す)と自プロセス宛ての DispatchSource 通知(即時の信号)— で、どちらも
/// 「最新の観測が現在値」として同じ更新経路に流す。sysctl の normal は先行する通知由来の
/// warning を打ち消す(システム全体の状態が真)。圧迫通知はプロセスを選んで遷移時にだけ
/// 届くため、通知だけでは圧迫中の起動や他アプリ起因の圧迫を知れない(経緯は設計書 §5)。
/// 更新と読み取りはロックし、変化したときだけアプリ通知を一本送る。段階は OS が normal を
/// 報告するまで持続する(自前のタイムアウトは持たない)。
final class MemoryPressureMonitor: MemoryPressureProviding, @unchecked Sendable {
    static let shared = MemoryPressureMonitor()
    static let didChangeNotification = Notification.Name("CooViewerMemoryPressureDidChange")

    /// システム段階の読み直し間隔と許容遅延(設計書 §5)。圧迫は数十秒〜分単位で続くので
    /// 5 秒で追従でき、許容遅延を間隔と同じにして起床を他のタイマーとまとめる(最悪 10 秒)。
    /// 読み取りは Int32 一つへの sysctl で、停止条件は設けない(本を閉じてもキャッシュと
    /// アクティビティ窓が段階に反応する)。
    static let systemPollInterval: Duration = .seconds(5)
    static let systemPollLeeway: Duration = .seconds(5)

    private let state: OSAllocatedUnfairLock<MemoryPressureLevel>
    private let center: NotificationCenter
    private let readSystemLevel: @Sendable () -> MemoryPressureLevel?
    private let source: any DispatchSourceMemoryPressure
    /// タイマーの取り消し。self を捕まえる予約は全プロパティの初期化後にしか立てられない
    /// ため var(PowerStateMonitor.observers と同じ)
    private var stopPolling: PeriodicScheduler.Cancel?

    /// `readSystemLevel` の nil は「読めなかった」(観測なし、現在値を保つ)。読めたが
    /// 解釈できない値は MemoryPressureLevel(systemPressureValue:) が normal に写す。
    init(center: NotificationCenter = .default,
         readSystemLevel: @escaping @Sendable () -> MemoryPressureLevel? = MemoryPressureLevel.readSystemWide,
         scheduler: PeriodicScheduler = .dispatchTimer) {
        self.center = center
        self.readSystemLevel = readSystemLevel
        // 最初の消費者が読む前にシステム全体の段階で種を蒔く(起動時点で既に圧迫中なら
        // 遷移通知は来ない)。初期値なので通知は送らない
        state = OSAllocatedUnfairLock(initialState: readSystemLevel() ?? .normal)
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        // @Sendable でクロージャの隔離推論を止める。setEventHandler の引数は @Sendable では
        // ないため、隔離された文脈で書いたクロージャはその隔離と推論され、DispatchSource が
        // .global(qos: .utility) で呼ぶと macOS 26.6 の Swift 並行性ランタイムがクロージャ
        // 入口の隔離アサートで SIGTRAP する(本を開く前のランダムクラッシュとして報告)。
        // 圧迫源をここ一箇所に集めたので、この注意もここだけで済む。
        // 自身の handler から source を捕まえると循環参照になるため self 経由で読む。
        source.setEventHandler { @Sendable [weak self] in
            guard let self else { return }
            self.receive(self.source.data)
        }
        source.activate()
        // weak で捕まえ、タイマー → 予約 → self → stopPolling → タイマーの循環を断つ
        stopPolling = scheduler.schedule(Self.systemPollInterval, Self.systemPollLeeway) { [weak self] in
            self?.pollSystemLevel()
        }
    }

    deinit {
        source.cancel()
        stopPolling?()
    }

    var memoryPressureLevel: MemoryPressureLevel { state.withLock { $0 } }

    /// 圧迫イベントの受理(任意スレッド)。テストは実圧迫なしにここへ流す。
    func receive(_ event: DispatchSource.MemoryPressureEvent) {
        guard let level = MemoryPressureLevel(event: event) else { return }
        apply(level)
    }

    /// タイマーからのシステム段階の読み直し。読めなかったときは現在値を保つ
    private func pollSystemLevel() {
        guard let level = readSystemLevel() else { return }
        apply(level)
    }

    /// 二つの観測源の合流点: 最新の観測を現在値とし、変わったときだけ通知する
    private func apply(_ level: MemoryPressureLevel) {
        let changed = state.withLock { current in
            guard current != level else { return false }
            current = level
            return true
        }
        // 更新済みの現在値を読めるよう、アプリ通知はロックを外してから送る。
        if changed { center.post(name: Self.didChangeNotification, object: self) }
    }
}
