import Foundation
import os

/// 書庫の自動復号とアプリの先読みが、低電力モードだけに連動する(設計書 §5)。
protocol PowerStateProviding: Sendable {
    var isLowPowerModeEnabled: Bool { get }
}

/// テストは実行機の電力状態に依存せず、提供者を差し替えられる。
struct FixedPowerState: PowerStateProviding {
    let isLowPowerModeEnabled: Bool
}

/// OS 通知は任意スレッドで届くため、現在値の更新と読み取りをロックする。
/// 他の依存は不変で、監視トークンは初期化と解放時だけ触る。
final class PowerStateMonitor: PowerStateProviding, @unchecked Sendable {
    static let shared = PowerStateMonitor()
    static let didChangeNotification = Notification.Name("CooViewerPowerStateDidChange")

    private let state: OSAllocatedUnfairLock<Bool>
    private let readState: @Sendable () -> Bool
    private let center: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default,
         readState: @escaping @Sendable () -> Bool = {
             ProcessInfo.processInfo.isLowPowerModeEnabled
         }) {
        self.center = center
        self.readState = readState
        state = OSAllocatedUnfairLock(initialState: readState())
        observer = center.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                      object: nil, queue: nil) { [weak self] _ in
            self?.update()
        }
        // 初期値の取得から監視登録までの間に起きた状態変更も取り込む。
        update()
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    var isLowPowerModeEnabled: Bool { state.withLock { $0 } }

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
