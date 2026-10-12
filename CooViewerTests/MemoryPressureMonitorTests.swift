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
        let fixture = MonitorFixture(systemLevel: .normal)
        let monitor = fixture.monitor
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
        XCTAssertEqual(fixture.published, [.warning, .critical, .normal])
    }

    // MARK: システム全体の段階(sysctl)との併用

    func testSystemPressureValueMapping() {
        // xnu の kVMPressure*: 1 normal / 2 warning / 3 urgent / 4 critical。0 と未知は normal
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: 0), .normal)
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: 3), .warning)
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: 4), .critical)
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: 5), .normal)
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: -1), .normal)
        XCTAssertEqual(MemoryPressureLevel(systemPressureValue: .max), .normal)
    }

    /// 起動時点で既に圧迫中なら遷移通知は来ない。init で読んだ段階を通知なしに最初から返す
    func testSeedsFromSystemLevelAtInitWithoutNotification() {
        for level in MemoryPressureLevel.allCases {
            let fixture = MonitorFixture(systemLevel: level)
            XCTAssertEqual(fixture.monitor.memoryPressureLevel, level)
            XCTAssertEqual(fixture.published, [], "初期値は通知しない")
            XCTAssertEqual(fixture.ticker.scheduled.count, 1, "読み直しのタイマーを一つ立てる")
            // 後から購読する消費者(キャッシュの init)は通知なしに種の段階を受け取る
            let received = OSAllocatedUnfairLock<MemoryPressureLevel?>(initialState: nil)
            let observation = MemoryPressureObservation(center: fixture.center)
            observation.setHandler({ provider in
                received.withLock { $0 = provider.memoryPressureLevel }
            }, provider: fixture.monitor)
            XCTAssertEqual(received.withLock { $0 }, level)
        }
        // 読めなかったときは normal から始める
        let unreadable = MonitorFixture(systemLevel: nil)
        XCTAssertEqual(unreadable.monitor.memoryPressureLevel, .normal)
    }

    func testPollingSchedulesWithDocumentedIntervalAndLeeway() {
        let fixture = MonitorFixture(systemLevel: .normal)
        let entry = fixture.ticker.scheduled[0]
        XCTAssertEqual(entry.interval, MemoryPressureMonitor.systemPollInterval)
        XCTAssertEqual(entry.leeway, MemoryPressureMonitor.systemPollLeeway)
        XCTAssertEqual(entry.interval, .seconds(5))
        XCTAssertEqual(entry.leeway, .seconds(5))
        XCTAssertFalse(entry.cancelled)
    }

    /// タイマーの読み直し: 遷移ごとに通知一本、同じ読みの繰り返しと読めなかった回は無通知
    func testPollingPublishesExactlyOncePerTransition() {
        let fixture = MonitorFixture(systemLevel: .normal)
        fixture.poll(.normal)
        fixture.poll(.normal)
        XCTAssertEqual(fixture.published, [])
        fixture.poll(.warning)
        XCTAssertEqual(fixture.monitor.memoryPressureLevel, .warning)
        fixture.poll(.warning)
        fixture.poll(nil)
        XCTAssertEqual(fixture.monitor.memoryPressureLevel, .warning, "読めなかった回は現在値を保つ")
        fixture.poll(.normal)
        fixture.poll(.normal)
        XCTAssertEqual(fixture.monitor.memoryPressureLevel, .normal)
        XCTAssertEqual(fixture.published, [.warning, .normal])
    }

    /// 二つの観測源は「最新の観測が現在値」: sysctl の normal は通知由来の warning を打ち消し、
    /// sysctl の warning の後に来た critical 通知はそのまま critical になる
    func testLatestObservationFromEitherSourceWins() {
        let fixture = MonitorFixture(systemLevel: .normal)
        fixture.monitor.receive(.warning)
        XCTAssertEqual(fixture.monitor.memoryPressureLevel, .warning)
        fixture.poll(.normal)
        XCTAssertEqual(fixture.monitor.memoryPressureLevel, .normal, "システム全体の状態が真")

        fixture.poll(.warning)
        fixture.monitor.receive(.critical)
        XCTAssertEqual(fixture.monitor.memoryPressureLevel, .critical)
        fixture.poll(.critical)
        XCTAssertEqual(fixture.published, [.warning, .normal, .warning, .critical])
    }

    /// 監視器の解放でタイマーを止める(予約が self を強く持つと解放されず止まらない)
    func testDeinitCancelsPolling() {
        let ticker = ManualTicker()
        var monitor: MemoryPressureMonitor? = MemoryPressureMonitor(
            center: NotificationCenter(), readSystemLevel: { .normal }, scheduler: ticker.scheduler)
        weak var weakMonitor = monitor
        XCTAssertFalse(ticker.scheduled[0].cancelled)
        monitor = nil
        XCTAssertNil(weakMonitor, "タイマーの予約は監視器を強く持たない")
        XCTAssertTrue(ticker.scheduled[0].cancelled)
        ticker.tick()  // 取り消し後の発火は無害
    }
}

/// 繰り返し予約を記録するだけの予約器。テストが `tick()` で満了を再現し、時計を待たない
private final class ManualTicker: Sendable {
    struct Entry {
        let interval: Duration
        let leeway: Duration
        let tick: @Sendable () -> Void
        var cancelled = false
    }

    private let entries = OSAllocatedUnfairLock(initialState: [Entry]())

    var scheduler: PeriodicScheduler {
        PeriodicScheduler { [entries] interval, leeway, tick in
            let index = entries.withLock { list in
                list.append(Entry(interval: interval, leeway: leeway, tick: tick))
                return list.count - 1
            }
            return { entries.withLock { $0[index].cancelled = true } }
        }
    }

    var scheduled: [Entry] { entries.withLock { $0 } }

    /// 取り消されていない予約を一回ずつ発火させる(取り消し済みは製品のタイマーと同じく鳴らない)
    func tick() {
        for entry in scheduled where !entry.cancelled { entry.tick() }
    }
}

/// sysctl の読みを手で与えられる監視器と、通知時の現在値の記録。実機の状態には触れない
private final class MonitorFixture {
    let center = NotificationCenter()
    let ticker = ManualTicker()
    let monitor: MemoryPressureMonitor
    private let systemLevel: OSAllocatedUnfairLock<MemoryPressureLevel?>
    private let recorded = OSAllocatedUnfairLock(initialState: [MemoryPressureLevel]())
    private var token: (any NSObjectProtocol)?

    init(systemLevel: MemoryPressureLevel?) {
        let box = OSAllocatedUnfairLock(initialState: systemLevel)
        self.systemLevel = box
        monitor = MemoryPressureMonitor(center: center, readSystemLevel: { box.withLock { $0 } },
                                        scheduler: ticker.scheduler)
        let (monitor, recorded) = (monitor, recorded)
        token = center.addObserver(forName: MemoryPressureMonitor.didChangeNotification,
                                   object: nil, queue: nil) { notification in
            // 通知時点で現在値が更新済みであり、object から提供者として読めること
            let fromObject = (notification.object as? any MemoryPressureProviding)?.memoryPressureLevel
            XCTAssertEqual(fromObject, monitor.memoryPressureLevel)
            recorded.withLock { $0.append(monitor.memoryPressureLevel) }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    /// 通知のたびに読んだ現在値(= 遷移の列)
    var published: [MemoryPressureLevel] { recorded.withLock { $0 } }

    /// 次の sysctl の読み(nil = 読めない)を据えてタイマーを一回鳴らす
    func poll(_ level: MemoryPressureLevel?) {
        systemLevel.withLock { $0 = level }
        ticker.tick()
    }
}
