import Dispatch
import Foundation
import os
import XCTest
@testable import cooViewer

/// 本番の監視器と同じく、一つの提供者の現在値をロックで読み書きする。
final class MutableMemoryPressure: MemoryPressureProviding, Sendable {
    private let state: OSAllocatedUnfairLock<MemoryPressureLevel>

    init(_ level: MemoryPressureLevel) {
        state = OSAllocatedUnfairLock(initialState: level)
    }

    var memoryPressureLevel: MemoryPressureLevel {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// メモリ圧迫源と予算ポリシーの検証(設計書 §5、§7.6)
final class MemoryPressureMonitorTests: XCTestCase {
    func testEffectiveLimitTruthTable() {
        // 段階 × 設定値。整数除算は切り捨て、下限は 1 バイト
        let cases: [(Int, MemoryPressureLevel, Int)] = [
            (1 << 30, .normal, 1 << 30),
            (1 << 30, .warning, 512 << 20),
            (1 << 30, .critical, 256 << 20),
            (7, .normal, 7), (7, .warning, 3), (7, .critical, 1),
            (3, .warning, 1), (3, .critical, 1),
            (2, .warning, 1), (1, .normal, 1), (1, .critical, 1),
            (0, .normal, 1), (0, .critical, 1),
        ]
        for (configured, level, expected) in cases {
            XCTAssertEqual(MemoryBudgetPolicy.effectiveLimit(configured: configured, level: level),
                           expected, "configured=\(configured) level=\(level)")
        }
        XCTAssertEqual(MemoryBudgetPolicy.warningDivisor, 2)
        XCTAssertEqual(MemoryBudgetPolicy.criticalDivisor, 4)
    }

    func testLevelMapsDispatchEventsBySeverity() {
        XCTAssertEqual(MemoryPressureLevel(event: .normal), .normal)
        XCTAssertEqual(MemoryPressureLevel(event: .warning), .warning)
        XCTAssertEqual(MemoryPressureLevel(event: .critical), .critical)
        XCTAssertEqual(MemoryPressureLevel(event: [.warning, .critical]), .critical)
        XCTAssertNil(MemoryPressureLevel(event: []))
    }

    /// 購読者は setHandler の時点で注入された提供者を一度受け取り(init と購読の隙間を閉じる)、
    /// 以後は通知の object(無ければ注入された提供者)を受け取る
    func testObservationDeliversInjectedProviderOnSetHandlerAndNotificationObjectAfterwards() {
        let center = NotificationCenter()
        let observation = MemoryPressureObservation(center: center)
        let received = OSAllocatedUnfairLock(initialState: [MemoryPressureLevel]())
        observation.setHandler({ provider in
            received.withLock { $0.append(provider.memoryPressureLevel) }
        }, provider: FixedMemoryPressure(.warning))
        XCTAssertEqual(received.withLock { $0 }, [.warning])
        center.post(name: MemoryPressureMonitor.didChangeNotification, object: FixedMemoryPressure(.critical))
        center.post(name: MemoryPressureMonitor.didChangeNotification, object: nil)
        XCTAssertEqual(received.withLock { $0 }, [.warning, .critical, .warning])
    }

    func testFixedProviderReportsItsLevel() {
        XCTAssertEqual(FixedMemoryPressure().memoryPressureLevel, .normal)
        XCTAssertEqual(FixedMemoryPressure(.critical).memoryPressureLevel, .critical)
    }

    func testEventFromBackgroundUpdatesStateBeforePublishingChange() {
        let center = NotificationCenter()
        let monitor = MemoryPressureMonitor(center: center)
        let published = OSAllocatedUnfairLock(initialState: [MemoryPressureLevel]())
        let token = center.addObserver(forName: MemoryPressureMonitor.didChangeNotification,
                                       object: nil, queue: nil) { notification in
            // 通知時点で現在値が更新済みであり、object から提供者として読めること
            let fromObject = (notification.object as? any MemoryPressureProviding)?.memoryPressureLevel
            XCTAssertEqual(fromObject, monitor.memoryPressureLevel)
            published.withLock { $0.append(monitor.memoryPressureLevel) }
        }
        defer { center.removeObserver(token) }
        XCTAssertEqual(monitor.memoryPressureLevel, .normal)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // 同じ段階の繰り返しと空イベントは通知しない。normal まで段階は持続する
            for event in [DispatchSource.MemoryPressureEvent.warning, .warning, [], .critical, .normal] {
                monitor.receive(event)
            }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(monitor.memoryPressureLevel, .normal)
        XCTAssertEqual(published.withLock { $0 }, [.warning, .critical, .normal])
    }
}
