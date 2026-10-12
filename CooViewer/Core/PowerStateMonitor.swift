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

/// 書庫の自動復号とアプリの先読みは、低電力モードまたは温度圧迫で一緒に絞る(設計書 §5)。
/// 判定は一つに集約し、各消費者が別々の条件を組み立てないようにする。
protocol PowerStateProviding: Sendable {
    var isLowPowerModeEnabled: Bool { get }
    var isThermalPressureActive: Bool { get }
}

extension PowerStateProviding {
    /// 全消費者が使う唯一の省エネ判定(設計書 §5)。
    var shouldConserveEnergy: Bool { isLowPowerModeEnabled || isThermalPressureActive }
}

/// テストは実行機の電力・温度状態に依存せず、提供者を差し替えられる。
struct FixedPowerState: PowerStateProviding {
    let isLowPowerModeEnabled: Bool
    let isThermalPressureActive: Bool

    init(isLowPowerModeEnabled: Bool = false, isThermalPressureActive: Bool = false) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isThermalPressureActive = isThermalPressureActive
    }
}

/// OS 通知は任意スレッドで届くため、現在値の更新と読み取りをロックする。
/// 他の依存は不変で、監視トークンは初期化と解放時だけ触る。
final class PowerStateMonitor: PowerStateProviding, @unchecked Sendable {
    static let shared = PowerStateMonitor()
    static let didChangeNotification = Notification.Name("CooViewerPowerStateDidChange")

    private let state: OSAllocatedUnfairLock<PowerConditions>
    private let readState: @Sendable () -> PowerConditions
    private let center: NotificationCenter
    private var observers: [any NSObjectProtocol] = []

    init(center: NotificationCenter = .default,
         readState: @escaping @Sendable () -> PowerConditions = { PowerConditions.current() }) {
        self.center = center
        self.readState = readState
        state = OSAllocatedUnfairLock(initialState: readState())
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
    }

    var isLowPowerModeEnabled: Bool { state.withLock { $0.isLowPowerModeEnabled } }
    var isThermalPressureActive: Bool { state.withLock { $0.isThermalPressureActive } }

    private func update() {
        let changed = state.withLock { current in
            let next = readState()
            guard current != next else { return false }
            current = next
            return true
        }
        // 更新済みの現在値を読めるよう、アプリ通知はロックを外してから送る。
        if changed { center.post(name: Self.didChangeNotification, object: self) }
    }
}
