import Foundation
import os
import XCTest
@testable import cooViewer

final class PowerStateMonitorTests: XCTestCase {
    func testNotificationFromBackgroundUpdatesStateBeforePublishingChange() {
        let center = NotificationCenter()
        let input = OSAllocatedUnfairLock(initialState: false)
        let monitor = PowerStateMonitor(center: center, readState: { input.withLock { $0 } })
        let published = OSAllocatedUnfairLock(initialState: [Bool]())
        let token = center.addObserver(forName: PowerStateMonitor.didChangeNotification,
                                       object: nil, queue: nil) { _ in
            published.withLock { $0.append(monitor.isLowPowerModeEnabled) }
        }
        defer { center.removeObserver(token) }
        XCTAssertFalse(monitor.isLowPowerModeEnabled)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            input.withLock { $0 = true }
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            input.withLock { $0 = false }
            center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(monitor.isLowPowerModeEnabled)
        XCTAssertEqual(published.withLock { $0 }, [true, false])
    }
}
