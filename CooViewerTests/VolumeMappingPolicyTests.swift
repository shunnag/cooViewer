import XCTest
@testable import cooViewer

/// 媒体の取り外し・切断による SIGBUS を避けるボリューム判定(cooViewer-oxr.39)。
final class VolumeMappingPolicyTests: XCTestCase {
    func testMemoryMapGateAllowsLocalFixedVolume() {
        XCTAssertTrue(VolumeMappingPolicy.isSafeForMemoryMapping(
            volumeIsLocal: true, isRemovable: false, isEjectable: false))
    }

    func testMemoryMapGateRejectsRemovableVolume() {
        XCTAssertFalse(VolumeMappingPolicy.isSafeForMemoryMapping(
            volumeIsLocal: true, isRemovable: true, isEjectable: false))
    }

    func testMemoryMapGateRejectsEjectableVolume() {
        XCTAssertFalse(VolumeMappingPolicy.isSafeForMemoryMapping(
            volumeIsLocal: true, isRemovable: false, isEjectable: true))
    }

    func testMemoryMapGateRejectsNonLocalVolume() {
        XCTAssertFalse(VolumeMappingPolicy.isSafeForMemoryMapping(
            volumeIsLocal: false, isRemovable: false, isEjectable: false))
    }

    func testMemoryMapGateRejectsUnknownLocality() {
        XCTAssertFalse(VolumeMappingPolicy.isSafeForMemoryMapping(
            volumeIsLocal: nil, isRemovable: false, isEjectable: false))
    }

    func testMemoryMapGateRejectsUnknownRemovability() {
        XCTAssertFalse(VolumeMappingPolicy.isSafeForMemoryMapping(
            volumeIsLocal: true, isRemovable: nil, isEjectable: false))
    }

    func testMemoryMapGateRejectsUnknownEjectability() {
        XCTAssertFalse(VolumeMappingPolicy.isSafeForMemoryMapping(
            volumeIsLocal: true, isRemovable: false, isEjectable: nil))
    }
}
