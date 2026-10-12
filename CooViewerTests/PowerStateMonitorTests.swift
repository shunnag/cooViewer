import Foundation
import os
import XCTest
@testable import cooViewer

/// 予約を記録するだけの予約器。テストが `fire()` で満了を再現し、時計を待たない
private final class ManualScheduler: Sendable {
    struct Entry {
        let delay: Duration
        let action: @Sendable () -> Void
        var cancelled = false
        var fired = false
        var isLive: Bool { !cancelled && !fired }
    }

    private let entries = OSAllocatedUnfairLock(initialState: [Entry]())

    var scheduler: DelayedScheduler {
        DelayedScheduler { [entries] delay, action in
            let index = entries.withLock { list in
                list.append(Entry(delay: delay, action: action))
                return list.count - 1
            }
            return { entries.withLock { $0[index].cancelled = true } }
        }
    }

    /// 記録した全予約(取り消し・発火済みを含む)
    var pending: [Entry] { entries.withLock { $0 } }
    var liveCount: Int { pending.filter(\.isLive).count }

    /// 取り消されても発火してもいない予約を全て満了させる
    func fire() {
        let live = entries.withLock { list in
            let indices = list.indices.filter { list[$0].isLive }
            for index in indices { list[index].fired = true }
            return indices.map { list[$0].action }
        }
        for action in live { action() }
    }
}

/// 電力と温度を手で与えられる監視器と、派生判定の変化(通知時の shouldConserveEnergy)の記録
private final class ThermalFixture {
    let center = NotificationCenter()
    let scheduler = ManualScheduler()
    let monitor: PowerStateMonitor
    private let thermal = OSAllocatedUnfairLock(initialState: ProcessInfo.ThermalState.nominal)
    private let lowPower = OSAllocatedUnfairLock(initialState: false)
    private let recorded = OSAllocatedUnfairLock(initialState: [Bool]())
    private var token: (any NSObjectProtocol)?

    init() {
        let (thermal, lowPower, recorded) = (thermal, lowPower, recorded)
        monitor = PowerStateMonitor(center: center, readState: {
            PowerConditions(isLowPowerModeEnabled: lowPower.withLock { $0 },
                            isThermalPressureActive: PowerConditions.isThermalPressure(thermal.withLock { $0 }))
        }, scheduler: scheduler.scheduler)
        let monitor = monitor
        token = center.addObserver(forName: PowerStateMonitor.didChangeNotification,
                                   object: nil, queue: nil) { _ in
            recorded.withLock { $0.append(monitor.shouldConserveEnergy) }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    var published: [Bool] { recorded.withLock { $0 } }

    func setThermal(_ state: ProcessInfo.ThermalState) {
        thermal.withLock { $0 = state }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    /// 通知なしで温度だけ変える(通知の取り逃しを再現する)
    func reheatSilently() {
        thermal.withLock { $0 = .serious }
    }

    func setLowPower(_ enabled: Bool) {
        lowPower.withLock { $0 = enabled }
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
    }
}

final class PowerStateMonitorTests: XCTestCase {
    private typealias Conditions = PowerConditions

    func testThermalPressureEntersImmediatelyAndLeavesOnlyAfterHold() {
        let fixture = ThermalFixture()
        fixture.setThermal(.serious)
        XCTAssertTrue(fixture.monitor.shouldConserveEnergy, "圧迫の開始は即時")
        XCTAssertEqual(fixture.published, [true])
        XCTAssertEqual(fixture.scheduler.pending.count, 0)

        fixture.setThermal(.fair)
        XCTAssertTrue(fixture.monitor.isThermalPressureActive, "保持時間の間は省エネのまま")
        XCTAssertEqual(fixture.published, [true], "保持中は通知しない")
        XCTAssertEqual(fixture.scheduler.pending.map(\.delay), [PowerStateMonitor.thermalReleaseHold])

        fixture.scheduler.fire()
        XCTAssertFalse(fixture.monitor.shouldConserveEnergy)
        XCTAssertEqual(fixture.published, [true, false])
        // 発火済みの予約が再度呼ばれても何も起きない
        fixture.scheduler.pending[0].action()
        XCTAssertEqual(fixture.published, [true, false])
        XCTAssertEqual(fixture.scheduler.liveCount, 0)
    }

    func testOscillationWithinHoldKeepsConservingWithoutNotifications() {
        let fixture = ThermalFixture()
        for state in [ProcessInfo.ThermalState.serious, .fair, .serious, .nominal, .critical, .fair] {
            fixture.setThermal(state)
            XCTAssertTrue(fixture.monitor.shouldConserveEnergy, "\(state)")
        }
        XCTAssertEqual(fixture.published, [true], "往復中は一度も抜けない")
        XCTAssertEqual(fixture.scheduler.pending.count, 3, "fair / nominal / fair で 3 回予約した")
        XCTAssertEqual(fixture.scheduler.liveCount, 1, "再加熱で先の予約は取り消された")

        // 取り消し済みの予約が遅れて発火しても無視する
        fixture.scheduler.pending[0].action()
        XCTAssertTrue(fixture.monitor.shouldConserveEnergy)
        fixture.scheduler.fire()
        XCTAssertFalse(fixture.monitor.shouldConserveEnergy)
        XCTAssertEqual(fixture.published, [true, false])
    }

    func testReleaseRereadsThermalStateBeforeLeaving() {
        let fixture = ThermalFixture()
        fixture.setThermal(.serious)
        fixture.setThermal(.fair)
        // 通知を取り逃して再加熱していた場合、満了時の読み直しで保持を続ける
        fixture.reheatSilently()
        fixture.scheduler.fire()
        XCTAssertTrue(fixture.monitor.shouldConserveEnergy)
        XCTAssertEqual(fixture.published, [true])
        // 次に fair の通知が来れば改めて予約し、満了で抜ける
        fixture.setThermal(.fair)
        XCTAssertEqual(fixture.scheduler.liveCount, 1)
        fixture.scheduler.fire()
        XCTAssertFalse(fixture.monitor.shouldConserveEnergy)
        XCTAssertEqual(fixture.published, [true, false])
    }

    func testLowPowerModeAppliesImmediatelyInBothDirectionsAndPostsOnlyDecisionChanges() {
        let fixture = ThermalFixture()
        fixture.setLowPower(true)
        XCTAssertEqual(fixture.published, [true])
        // 低電力中に圧迫が始まっても判定は変わらないので通知しない
        fixture.setThermal(.serious)
        fixture.setThermal(.fair)
        fixture.scheduler.fire()
        XCTAssertTrue(fixture.monitor.isLowPowerModeEnabled)
        XCTAssertFalse(fixture.monitor.isThermalPressureActive, "低電力中でも保持の満了は進む")
        XCTAssertEqual(fixture.published, [true])
        fixture.setLowPower(false)
        XCTAssertFalse(fixture.monitor.shouldConserveEnergy, "低電力解除は保持を待たない")
        XCTAssertEqual(fixture.published, [true, false])

        // 温度保持中の低電力 ON/OFF も判定を変えないので通知しない
        fixture.setThermal(.serious)
        fixture.setThermal(.fair)
        fixture.setLowPower(true)
        fixture.setLowPower(false)
        XCTAssertEqual(fixture.published, [true, false, true])
        XCTAssertEqual(fixture.scheduler.liveCount, 1)
    }

    func testPendingRecoveryDoesNotRetainMonitor() {
        let scheduler = ManualScheduler()
        let center = NotificationCenter()
        let thermal = OSAllocatedUnfairLock(initialState: true)
        var monitor: PowerStateMonitor? = PowerStateMonitor(center: center, readState: {
            Conditions(isLowPowerModeEnabled: false, isThermalPressureActive: thermal.withLock { $0 })
        }, scheduler: scheduler.scheduler)
        weak let released = monitor
        thermal.withLock { $0 = false }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        XCTAssertEqual(scheduler.liveCount, 1)
        // 解除予約は監視器を強参照せず、解放時に取り消される
        monitor = nil
        XCTAssertNil(released)
        XCTAssertEqual(scheduler.liveCount, 0)
        // 取り消し済みの予約が遅れて発火しても何も起きない
        scheduler.pending[0].action()
    }

    func testInitialThermalPressureIsHeldFromTheStart() {
        let scheduler = ManualScheduler()
        let monitor = PowerStateMonitor(center: NotificationCenter(), readState: {
            Conditions(isLowPowerModeEnabled: false, isThermalPressureActive: true)
        }, scheduler: scheduler.scheduler)
        XCTAssertTrue(monitor.isThermalPressureActive)
        XCTAssertEqual(scheduler.pending.count, 0)
    }

    func testNotificationFromBackgroundUpdatesStateBeforePublishingChange() {
        let center = NotificationCenter()
        let input = OSAllocatedUnfairLock(initialState: false)
        let monitor = PowerStateMonitor(center: center, readState: {
            Conditions(isLowPowerModeEnabled: input.withLock { $0 }, isThermalPressureActive: false)
        })
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

    func testThermalNotificationFromBackgroundUpdatesStateBeforePublishingChange() {
        let center = NotificationCenter()
        let input = OSAllocatedUnfairLock(initialState: ProcessInfo.ThermalState.nominal)
        let scheduler = ManualScheduler()
        let monitor = PowerStateMonitor(center: center, readState: {
            Conditions(isLowPowerModeEnabled: false,
                       isThermalPressureActive: Conditions.isThermalPressure(input.withLock { $0 }))
        }, scheduler: scheduler.scheduler)
        let published = OSAllocatedUnfairLock(initialState: [Bool]())
        let token = center.addObserver(forName: PowerStateMonitor.didChangeNotification,
                                       object: nil, queue: nil) { _ in
            published.withLock { $0.append(monitor.shouldConserveEnergy) }
        }
        defer { center.removeObserver(token) }
        XCTAssertFalse(monitor.shouldConserveEnergy)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // fair は通常運転のまま(通知なし)、serious で初めて絞り、critical は継続(通知なし)
            for state in [ProcessInfo.ThermalState.fair, .serious, .critical, .nominal] {
                input.withLock { $0 = state }
                center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
            }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(monitor.isLowPowerModeEnabled)
        // nominal に戻っても保持時間が満了するまでは省エネのまま(設計書 §5)
        XCTAssertTrue(monitor.isThermalPressureActive)
        XCTAssertEqual(published.withLock { $0 }, [true])
        scheduler.fire()
        XCTAssertFalse(monitor.isThermalPressureActive)
        XCTAssertEqual(published.withLock { $0 }, [true, false])
    }

    func testShouldConserveEnergyIsLowPowerOrThermalPressure() {
        for lowPower in [false, true] {
            for thermal in [false, true] {
                let fixed = FixedPowerState(isLowPowerModeEnabled: lowPower, isThermalPressureActive: thermal)
                XCTAssertEqual(fixed.shouldConserveEnergy, lowPower || thermal, "low=\(lowPower) thermal=\(thermal)")
                let monitor = PowerStateMonitor(center: NotificationCenter(), readState: {
                    Conditions(isLowPowerModeEnabled: lowPower, isThermalPressureActive: thermal)
                })
                XCTAssertEqual(monitor.shouldConserveEnergy, lowPower || thermal)
            }
        }
        XCTAssertFalse(FixedPowerState().shouldConserveEnergy)
    }

    func testThermalPressureStartsAtSerious() {
        XCTAssertFalse(Conditions.isThermalPressure(.nominal))
        XCTAssertFalse(Conditions.isThermalPressure(.fair))
        XCTAssertTrue(Conditions.isThermalPressure(.serious))
        XCTAssertTrue(Conditions.isThermalPressure(.critical))
    }
}
