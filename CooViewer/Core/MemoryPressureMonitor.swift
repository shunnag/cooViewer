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

/// アプリに一つのメモリ圧迫源。圧迫イベントは utility キューで届くため、現在値の
/// 更新と読み取りをロックし、変化したときだけアプリ通知を一本送る(設計書 §5)。
/// 段階は OS が .normal を報告するまで持続する(自前のタイムアウトは持たない)。
final class MemoryPressureMonitor: MemoryPressureProviding, @unchecked Sendable {
    static let shared = MemoryPressureMonitor()
    static let didChangeNotification = Notification.Name("CooViewerMemoryPressureDidChange")

    private let state: OSAllocatedUnfairLock<MemoryPressureLevel>
    private let center: NotificationCenter
    private let source: any DispatchSourceMemoryPressure

    init(center: NotificationCenter = .default) {
        self.center = center
        state = OSAllocatedUnfairLock(initialState: .normal)
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
    }

    deinit {
        source.cancel()
    }

    var memoryPressureLevel: MemoryPressureLevel { state.withLock { $0 } }

    /// 圧迫イベントの受理(任意スレッド)。テストは実圧迫なしにここへ流す。
    func receive(_ event: DispatchSource.MemoryPressureEvent) {
        guard let level = MemoryPressureLevel(event: event) else { return }
        let changed = state.withLock { current in
            guard current != level else { return false }
            current = level
            return true
        }
        // 更新済みの現在値を読めるよう、アプリ通知はロックを外してから送る。
        if changed { center.post(name: Self.didChangeNotification, object: self) }
    }
}
