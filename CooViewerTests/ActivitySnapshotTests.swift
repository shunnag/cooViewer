import XCTest
@testable import cooViewer

/// アクティビティ窓のスナップショット/予算ロジックの検証(設計書 §7.6)
final class ActivitySnapshotTests: XCTestCase {
    private func ml() -> ActivitySnapshot.ML {
        ActivitySnapshot.ML(noiseState: "x", superResState: "y",
                            diskCount: 0, diskBytes: 0, encrypted: false)
    }

    func testEmptySnapshotHasNoBookButKeepsML() {
        let snap = ActivitySnapshot.empty(ml: ml())
        XCTAssertNil(snap.book)
        XCTAssertNil(snap.loading)
        XCTAssertNil(snap.memory)
        XCTAssertEqual(snap.ml.noiseState, "x")
    }

    func testSnapshotEquatableDetectsChange() {
        let a = ActivitySnapshot.empty(ml: ml())
        var b = a
        XCTAssertEqual(a, b)
        b.ml = ActivitySnapshot.ML(noiseState: "z", superResState: "y",
                                   diskCount: 1, diskBytes: 100, encrypted: false)
        XCTAssertNotEqual(a, b)
    }

    func testPrefetchByteBudgetMatchesPolicy() {
        // アクティビティ窓が出す「予算」は PreresamplePolicy の再計算そのもの
        let physical: UInt64 = 128 << 30
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: physical),
                       4 << 30)  // 物理/8=16GB だが上限 4GB
        let small: UInt64 = 8 << 30
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: small),
                       Int(small / 8))
    }

    func testImageResamplerStatsAreConsistent() async {
        let resampler = ImageResampler(byteLimit: 10 << 20)
        let stats = await resampler.stats()
        XCTAssertEqual(stats.count, 0)
        XCTAssertEqual(stats.usedBytes, 0)
        XCTAssertEqual(stats.limitBytes, 10 << 20)
    }
}
