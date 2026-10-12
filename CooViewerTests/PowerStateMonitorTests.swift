import Foundation
import os
import XCTest
@testable import cooViewer

final class PowerStateMonitorTests: XCTestCase {
    private typealias Conditions = PowerConditions

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
        let monitor = PowerStateMonitor(center: center, readState: {
            Conditions(isLowPowerModeEnabled: false,
                       isThermalPressureActive: Conditions.isThermalPressure(input.withLock { $0 }))
        })
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
        XCTAssertFalse(monitor.isThermalPressureActive)
        XCTAssertFalse(monitor.isLowPowerModeEnabled)
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
