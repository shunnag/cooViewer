import CoreGraphics
import XCTest
@testable import cooViewer

final class RenderingPrewarmTests: XCTestCase {
    private let target = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.sRGB)!)

    @MainActor
    func testLaunchPrewarmingSchedulesNoWorkInsideXCTestHost() {
        XCTAssertTrue(AutomatedRun.isXCTest)
        let delegate = AppDelegate()
        delegate.scheduleLaunchPrewarming(for: ReaderWindowController(window: nil))
        XCTAssertNil(delegate.renderingPrewarmTask)
        XCTAssertNil(delegate.webKitPrewarmTask)
    }

    func testPrewarmUsesBothFormatsOnceAndLeavesNoSyntheticCacheEntries() async {
        let resampler = ImageResampler(pressure: FixedMemoryPressure())
        await resampler.prewarm(displayTarget: target, power: FixedPowerState(),
                                pressure: FixedMemoryPressure())
        let first = await resampler.stats()
        XCTAssertEqual(first.computeCount, 2)
        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(first.usedBytes, 0)
        await resampler.prewarm(displayTarget: target, power: FixedPowerState(),
                                pressure: FixedMemoryPressure())
        let second = await resampler.stats()
        XCTAssertEqual(second.computeCount, first.computeCount)
    }

    func testEnergyAndMemoryGuardsLeaveWarmupAvailableForLater() async {
        let resampler = ImageResampler(pressure: FixedMemoryPressure())
        for power in [FixedPowerState(isLowPowerModeEnabled: true),
                      FixedPowerState(isThermalPressureActive: true)] {
            await resampler.prewarm(displayTarget: target, power: power,
                                    pressure: FixedMemoryPressure())
        }
        for level in [MemoryPressureLevel.warning, .critical] {
            await resampler.prewarm(displayTarget: target, power: FixedPowerState(),
                                    pressure: FixedMemoryPressure(level))
        }
        let skipped = await resampler.stats()
        XCTAssertEqual(skipped.computeCount, 0)
        // 設計書 §5: 判定は共通の PowerPolicy に任せ、「常に全速」も尊重する。
        await resampler.prewarm(displayTarget: target,
            power: FixedPowerState(isLowPowerModeEnabled: true, isThermalPressureActive: true,
                                   powerPolicy: .alwaysFullSpeed),
            pressure: FixedMemoryPressure())
        let warmed = await resampler.stats()
        XCTAssertEqual(warmed.computeCount, 2)
    }

    func testCancelledWarmupDoesNotCompute() async {
        let resampler = ImageResampler(pressure: FixedMemoryPressure())
        let target = target
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await resampler.prewarm(displayTarget: target, power: FixedPowerState(),
                                    pressure: FixedMemoryPressure())
        }
        await task.value
        let stats = await resampler.stats()
        XCTAssertEqual(stats.computeCount, 0)
        XCTAssertEqual(stats.count, 0)
    }
}
