import Foundation
import os

/// 省エネに関わる OS 側の条件。低電力モードと温度圧迫(serious / critical)の
/// 二つを別々に持ち、消費側は派生値 `shouldConserveEnergy` だけを見る(設計書 §5)。
struct PowerConditions: Sendable, Equatable {
    var isLowPowerModeEnabled: Bool
    var isThermalPressureActive: Bool

    /// nominal / fair は通常運転のまま。serious 以上で初めて絞る(KaitoKit と同じ境界)。
    static func isThermalPressure(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    static func current(_ process: ProcessInfo = .processInfo) -> PowerConditions {
        PowerConditions(isLowPowerModeEnabled: process.isLowPowerModeEnabled,
                        isThermalPressureActive: isThermalPressure(process.thermalState))
    }
}

/// どの条件で省エネに入るかのユーザー設定(設定「高度」。設計書 §5)。
/// 保存値は UserDefaults キー `PowerPolicy` の rawValue 文字列で、未設定・未知の値は
/// 従来どおりの既定に読む。先読み深さ・事前リサンプル・展開係の数・KaitoKit の復号
/// 並列数・Washi の画面外処理は全てこの一つの方針から導き、消費者ごとの分岐を持たない。
enum PowerPolicy: String, CaseIterable, Sendable {
    /// 低電力モードまたは温度圧迫(serious / critical。解除は 45 秒の保持付き)で控える。
    /// 2.0b45 より後の挙動そのままで、既定。
    case lowPowerModeOrThermal
    /// 低電力モードのときだけ控え、温度は見ない(2.0b45 までの挙動)。
    case lowPowerModeOnly
    /// 電力・温度では控えない。メモリ圧迫による上限(キャッシュ・復号予算)は別系統で
    /// 引き続き効く。
    case alwaysFullSpeed

    static let `default` = PowerPolicy.lowPowerModeOrThermal

    /// 全消費者が使う唯一の省エネ判定(設計書 §5)。条件を集めるのは提供者、
    /// 判定するのはこの関数だけ。
    func conserves(_ conditions: PowerConditions) -> Bool {
        switch self {
        case .lowPowerModeOrThermal:
            conditions.isLowPowerModeEnabled || conditions.isThermalPressureActive
        case .lowPowerModeOnly:
            conditions.isLowPowerModeEnabled
        case .alwaysFullSpeed:
            false
        }
    }
}

/// 書庫の自動復号とアプリの先読みは、同じ条件と同じ方針で一緒に絞る(設計書 §5)。
/// 判定は `PowerPolicy.conserves` の一つに集約し、各消費者が別々の条件を組み立てない。
protocol PowerStateProviding: Sendable {
    var isLowPowerModeEnabled: Bool { get }
    var isThermalPressureActive: Bool { get }
    var powerPolicy: PowerPolicy { get }
    /// 既定実装で十分だが、監視器はロック 1 回で一貫した値を返すために上書きする
    var shouldConserveEnergy: Bool { get }
}

extension PowerStateProviding {
    var shouldConserveEnergy: Bool {
        powerPolicy.conserves(PowerConditions(isLowPowerModeEnabled: isLowPowerModeEnabled,
                                              isThermalPressureActive: isThermalPressureActive))
    }
}

/// テストは実行機の電力・温度状態と設定に依存せず、提供者を差し替えられる。
struct FixedPowerState: PowerStateProviding {
    let isLowPowerModeEnabled: Bool
    let isThermalPressureActive: Bool
    let powerPolicy: PowerPolicy

    init(isLowPowerModeEnabled: Bool = false, isThermalPressureActive: Bool = false,
         powerPolicy: PowerPolicy = .default) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isThermalPressureActive = isThermalPressureActive
        self.powerPolicy = powerPolicy
    }
}

/// 一定時間後に一度だけ実行し、取り消せる予約の注入点。製品は Task の sleep で待ち、
/// テストは記録した予約を手で発火させて時計に依存しない。
struct DelayedScheduler: Sendable {
    typealias Cancel = @Sendable () -> Void
    let schedule: @Sendable (_ delay: Duration, _ action: @escaping @Sendable () -> Void) -> Cancel

    static let task = DelayedScheduler { delay, action in
        let task = Task.detached(priority: .utility) {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            action()
        }
        return { task.cancel() }
    }
}

/// OS 通知は任意スレッドで届くため、現在値の更新と読み取りをロックする。
/// 他の依存は不変で、監視トークンは初期化と解放時だけ触る。
final class PowerStateMonitor: PowerStateProviding, @unchecked Sendable {
    static let shared = PowerStateMonitor()
    static let didChangeNotification = Notification.Name("CooViewerPowerStateDidChange")

    /// 温度圧迫を抜けるまでの保持時間(ヒステリシス。設計書 §5)。ファンレス機では
    /// 持続負荷下で thermalState が fair と serious の間を数十秒周期で往復する。往復の
    /// たびに省エネを抜けると先読みを全深度へ戻してすぐ再加熱し、進行中の ML 事前
    /// リサンプル(1 ページ数秒)も捨てることになる。45 秒は典型的な冷却側の滞在時間
    /// より長く往復を一続きの省エネ期間にまとめ、負荷が本当に終わってから全速に戻る
    /// までの遅れは 1 分未満に収まる。圧迫の開始と低電力モードの両方向は即時に反映する。
    /// KaitoKit 自身の DecodePowerPolicy は reader open 時に KaitoKit が評価するため、
    /// この保持はアプリ側の絞り(先読み深さ・事前リサンプル・展開係の数)にだけ効く。
    static let thermalReleaseHold: Duration = .seconds(45)

    private struct State {
        /// OS から読んだ生の条件
        var conditions: PowerConditions
        /// 保持込みの温度圧迫判定。生の値が false に戻っても保持時間の間は true のまま。
        /// 方針が温度を見なくても追跡は続け、方針を戻した瞬間から正しく効くようにする
        var thermalHeld: Bool
        /// ユーザー設定の方針(設定の保存と同時に SettingsStore が流し込む)
        var policy: PowerPolicy
        /// 進行中の解除予約。取り消し手段は予約を立てた後に入る(その間に発火・
        /// 取り消された予約は id が一致しないので無視される)
        var release: (id: UInt64, cancel: DelayedScheduler.Cancel?)?
        var nextReleaseID: UInt64 = 0

        var shouldConserve: Bool {
            policy.conserves(PowerConditions(isLowPowerModeEnabled: conditions.isLowPowerModeEnabled,
                                             isThermalPressureActive: thermalHeld))
        }
    }

    private let state: OSAllocatedUnfairLock<State>
    private let readState: @Sendable () -> PowerConditions
    private let scheduler: DelayedScheduler
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    init(center: NotificationCenter = .default,
         readState: @escaping @Sendable () -> PowerConditions = { PowerConditions.current() },
         scheduler: DelayedScheduler = .task,
         policy: PowerPolicy = .default) {
        self.center = center
        self.readState = readState
        self.scheduler = scheduler
        let initial = readState()
        state = OSAllocatedUnfairLock(initialState: State(
            conditions: initial, thermalHeld: initial.isThermalPressureActive, policy: policy))
        // 電力と温度のどちらの変化も同じ更新経路に流し、アプリ通知も一本にする(設計書 §5)。
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.update()
            })
        }
        // 初期値の取得から監視登録までの間に起きた状態変更も取り込む。
        update()
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
        state.withLock { $0.release?.cancel }?()
    }

    var isLowPowerModeEnabled: Bool { state.withLock { $0.conditions.isLowPowerModeEnabled } }
    var isThermalPressureActive: Bool { state.withLock { $0.thermalHeld } }
    var shouldConserveEnergy: Bool { state.withLock { $0.shouldConserve } }

    /// 方針の変更は、派生判定が変わらなくても通知する。OS 条件の変化は判定が変わる
    /// ときだけ通知するが、方針は判定以外にも Washi の画面外方針(全速 ↔ システム追従)
    /// を決めるため、生きているビューがそれを引き直す契機が要る(設計書 §5)。
    /// KaitoKit の復号並列数は reader の open 時に固定されるので、開いている書庫には
    /// 次に開いたときから反映する。
    var powerPolicy: PowerPolicy {
        get { state.withLock { $0.policy } }
        set {
            let changed = state.withLock { state in
                guard state.policy != newValue else { return false }
                state.policy = newValue
                return true
            }
            if changed { center.post(name: Self.didChangeNotification, object: self) }
        }
    }

    private func update() {
        // 読み取りもロック内で行い、同時に届いた通知の処理順と観測した OS 状態の順を揃える
        let (changed, cancel, newRelease) = state.withLock { state in
            let next = readState()
            let before = state.shouldConserve
            var cancel: DelayedScheduler.Cancel?
            var newRelease: UInt64?
            state.conditions = next
            if next.isThermalPressureActive {
                // 圧迫の再開(または継続)は解除予約を取り消して保持を続ける
                cancel = state.release?.cancel
                state.release = nil
                state.thermalHeld = true
            } else if state.thermalHeld, state.release == nil {
                state.nextReleaseID += 1
                state.release = (state.nextReleaseID, nil)
                newRelease = state.nextReleaseID
            }
            return (before != state.shouldConserve, cancel, newRelease)
        }
        // 予約と取り消しはロック外で行う(テストの予約器が同期に発火しても詰まらない)
        cancel?()
        if let newRelease { scheduleRelease(newRelease) }
        // 更新済みの現在値を読めるよう、アプリ通知はロックを外してから送る。
        if changed { center.post(name: Self.didChangeNotification, object: self) }
    }

    private func scheduleRelease(_ id: UInt64) {
        let cancel = scheduler.schedule(Self.thermalReleaseHold) { [weak self] in
            self?.releaseThermalHold(id)
        }
        let stale = state.withLock { state in
            guard state.release?.id == id else { return true }
            state.release?.cancel = cancel
            return false
        }
        if stale { cancel() }
    }

    /// 保持時間が満了した。予約が生きていて、いま読み直した温度もまだ圧迫下でなければ
    /// 解除する(init と同じく、通知を取り逃した間の再加熱を拾う)。
    private func releaseThermalHold(_ id: UInt64) {
        let changed = state.withLock { state in
            guard state.release?.id == id else { return false }
            state.release = nil
            let current = readState()
            state.conditions = current
            guard !current.isThermalPressureActive else { return false }
            let before = state.shouldConserve
            state.thermalHeld = false
            return before != state.shouldConserve
        }
        if changed { center.post(name: Self.didChangeNotification, object: self) }
    }
}
