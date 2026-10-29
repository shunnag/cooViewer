import XCTest
@testable import cooViewer

@MainActor
final class EPUBWebKitPrewarmerTests: XCTestCase {
    private final class Resource: EPUBWebKitWarmupResource {
        var starts = 0
        var stops = 0
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    func testNoEPUBOrBusySessionDoesNotCreateWebKit() {
        var creations = 0
        let warmer = EPUBWebKitPrewarmer(power: FixedPowerState(), pressure: FixedMemoryPressure()) {
            creations += 1
            return Resource()
        }
        warmer.beginIfUseful(recentPaths: [], isIdle: true)
        warmer.beginIfUseful(recentPaths: ["/books/book.cbz", "/books/epub/book.pdf"], isIdle: true)
        warmer.beginIfUseful(recentPaths: ["/books/book.epub"], isIdle: false)
        XCTAssertEqual(creations, 0)
        XCTAssertNil(warmer.releaseTask)
    }

    func testPowerPolicyAndMemoryPressurePreventCreation() {
        var creations = 0
        for power in [FixedPowerState(isLowPowerModeEnabled: true),
                      FixedPowerState(isThermalPressureActive: true)] {
            let warmer = EPUBWebKitPrewarmer(power: power, pressure: FixedMemoryPressure()) {
                creations += 1
                return Resource()
            }
            warmer.beginIfUseful(recentPaths: ["/books/book.epub"], isIdle: true)
        }
        for level in [MemoryPressureLevel.warning, .critical] {
            let warmer = EPUBWebKitPrewarmer(power: FixedPowerState(), pressure: FixedMemoryPressure(level)) {
                creations += 1
                return Resource()
            }
            warmer.beginIfUseful(recentPaths: ["/books/book.epub"], isIdle: true)
        }
        XCTAssertEqual(creations, 0)
    }

    func testRunsOnceAndReleasesWithoutWaitingForWebKit() async {
        var creations = 0
        weak var released: Resource?
        let warmer = EPUBWebKitPrewarmer(power: FixedPowerState(), pressure: FixedMemoryPressure(),
                                        releaseAfter: .zero) {
            creations += 1
            let resource = Resource()
            released = resource
            return resource
        }
        warmer.beginIfUseful(recentPaths: ["/books/book.EPUB"], isIdle: true)
        XCTAssertEqual(released?.starts, 1)
        warmer.beginIfUseful(recentPaths: ["/books/book.epub"], isIdle: true)
        await warmer.releaseTask?.value
        XCTAssertNil(released)
        XCTAssertNil(warmer.releaseTask)
        warmer.beginIfUseful(recentPaths: ["/books/book.epub"], isIdle: true)
        XCTAssertEqual(creations, 1)
    }

    func testCancellationStopsAndReleasesResourceImmediately() {
        let resource = Resource()
        let warmer = EPUBWebKitPrewarmer(power: FixedPowerState(isLowPowerModeEnabled: true,
            isThermalPressureActive: true, powerPolicy: .alwaysFullSpeed),
            pressure: FixedMemoryPressure(), makeResource: { resource })
        warmer.beginIfUseful(recentPaths: ["/books/book.epub"], isIdle: true)
        let release = warmer.releaseTask
        warmer.cancel()
        warmer.cancel()
        XCTAssertEqual(resource.starts, 1)
        XCTAssertEqual(resource.stops, 1)
        XCTAssertTrue(release?.isCancelled == true)
        XCTAssertNil(warmer.releaseTask)
    }
}
