import XCTest
@testable import cooViewer

/// アクティビティ窓のスナップショット/予算ロジックの検証(設計書 §7.6)
final class ActivitySnapshotTests: XCTestCase {
    private func ml() -> ActivitySnapshot.ML {
        ActivitySnapshot.ML(noiseState: "x", superResState: "y",
                            diskCount: 0, diskBytes: 0, encrypted: false)
    }

    func testEmptySnapshotHasNoBookButKeepsML() {
        let snap = ActivitySnapshot.empty(ml: ml(), physicalMemory: 16 << 30, pressure: .normal)
        XCTAssertNil(snap.book)
        XCTAssertNil(snap.loading)
        XCTAssertNil(snap.memory)
        XCTAssertEqual(snap.ml.noiseState, "x")
    }

    func testSnapshotEquatableDetectsChange() {
        let a = ActivitySnapshot.empty(ml: ml(), physicalMemory: 16 << 30, pressure: .normal)
        var b = a
        XCTAssertEqual(a, b)
        b.ml = ActivitySnapshot.ML(noiseState: "z", superResState: "y",
                                   diskCount: 1, diskBytes: 100, encrypted: false)
        XCTAssertNotEqual(a, b)
    }

    func testPrefetchByteBudgetMatchesPolicy() {
        // アクティビティ窓が出す「予算」は PreresamplePolicy の再計算そのもの
        let physical: UInt64 = 128 << 30
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: physical, usesML: false,
                                                    conserveEnergy: false, memoryPressure: .normal),
                       4 << 30)  // 物理/8=16GB だが上限 4GB
        let small: UInt64 = 8 << 30
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: small, usesML: false,
                                                    conserveEnergy: false, memoryPressure: .normal),
                       Int(small / 8))
    }

    /// 計画は実際の先読みと同じ入力で出す: ML 通常 4 ページ、ML 省エネ 2、非 ML 通常 64。
    /// バイト予算も枚数 / 64 に比例し、圧迫段階で縮む
    func testPrefetchPlanMatchesRealPreresampleInputs() {
        let physical: UInt64 = 16 << 30  // 通常の予算 2GB
        let mlNormal = ActivitySnapshot.PrefetchPlan(physicalMemory: physical, usesML: true,
                                                     conserveEnergy: false, memoryPressure: .normal)
        XCTAssertEqual(mlNormal.pageBudget, 4)
        XCTAssertEqual(mlNormal.byteBudget, (2 << 30) / 16)
        let mlConserving = ActivitySnapshot.PrefetchPlan(physicalMemory: physical, usesML: true,
                                                         conserveEnergy: true, memoryPressure: .normal)
        XCTAssertEqual(mlConserving.pageBudget, 2)
        XCTAssertEqual(mlConserving.byteBudget, (2 << 30) / 32)
        let plainNormal = ActivitySnapshot.PrefetchPlan(physicalMemory: physical, usesML: false,
                                                        conserveEnergy: false, memoryPressure: .normal)
        XCTAssertEqual(plainNormal.pageBudget, 64)
        XCTAssertEqual(plainNormal.byteBudget, 2 << 30)
        let plainConserving = ActivitySnapshot.PrefetchPlan(physicalMemory: physical, usesML: false,
                                                            conserveEnergy: true, memoryPressure: .critical)
        XCTAssertEqual(plainConserving.pageBudget, 4)
        XCTAssertEqual(plainConserving.byteBudget, (2 << 30) / 16 / 4)
    }

    func testImageResamplerStatsAreConsistent() async {
        let resampler = ImageResampler(byteLimit: 10 << 20, pressure: FixedMemoryPressure(),
                                       center: NotificationCenter())
        let stats = await resampler.stats()
        XCTAssertEqual(stats.count, 0)
        XCTAssertEqual(stats.usedBytes, 0)
        XCTAssertEqual(stats.limitBytes, 10 << 20)
    }

    func testResamplerStatsReportEffectiveLimitUnderPressure() async {
        // アクティビティ窓の上限は圧迫段階を適用した実効値
        let resampler = ImageResampler(byteLimit: 10 << 20, pressure: FixedMemoryPressure(.warning),
                                       center: NotificationCenter())
        let stats = await resampler.stats()
        XCTAssertEqual(stats.limitBytes, 5 << 20)
    }

    /// 資源上限の行は本を開いていなくても出る: 圧迫段階(●)と、開いた書庫ごとの復号予算(📐)。
    /// 値は ArchiveDecodeBudget の純関数そのもの
    func testResourcesFormatPressureAndPerOpenedArchiveBudgets() {
        let byteText = { (bytes: Int) in
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        }
        for level in MemoryPressureLevel.allCases {
            let snap = ActivitySnapshot.empty(ml: ml(), physicalMemory: 8 << 30, pressure: level)
            XCTAssertNil(snap.book)
            let rows = snap.resources.rows
            XCTAssertEqual(rows.map(\.label), [
                String(localized: "Memory pressure"),
                String(localized: "Archive decode · primary"),
                String(localized: "Archive decode · each extractor"),
            ])
            XCTAssertEqual(rows[0].value, "● " + level.displayName)
            XCTAssertEqual(rows[1].value, "📐 " + byteText(snap.resources.primaryDecodeBytes))
            XCTAssertEqual(rows[2].value, "📐 " + byteText(snap.resources.extractorDecodeBytes))
            XCTAssertEqual(UInt64(snap.resources.primaryDecodeBytes),
                           ArchiveDecodeBudget.parallelDecodeMemory(
                               role: .primary, physicalMemory: 8 << 30, memoryPressure: level))
            XCTAssertEqual(UInt64(snap.resources.extractorDecodeBytes),
                           ArchiveDecodeBudget.parallelDecodeMemory(
                               role: .extractor(poolSize: 6), physicalMemory: 8 << 30, memoryPressure: level))
            XCTAssertFalse(snap.resources.scopeText.isEmpty)
        }
        let normal = ActivitySnapshot.empty(ml: ml(), physicalMemory: 8 << 30, pressure: .normal)
        XCTAssertEqual(normal.resources.primaryDecodeBytes, 128 << 20)
        XCTAssertEqual(normal.resources.extractorDecodeBytes, 64 << 20)
        let critical = ActivitySnapshot.empty(ml: ml(), physicalMemory: 64 << 30, pressure: .critical)
        XCTAssertEqual(critical.resources.primaryDecodeBytes, 64 << 20)
        XCTAssertNotEqual(normal, critical)
        // 段階ごとの表示名は異なる(行で区別できる)
        XCTAssertEqual(Set(MemoryPressureLevel.allCases.map(\.displayName)).count, 3)
    }

    func testPrefetchByteBudgetFollowsMemoryPressure() {
        // アクティビティ窓の先読み予算も圧迫段階を適用した値
        XCTAssertEqual(PreresamplePolicy.byteBudget(physicalMemory: 8 << 30, usesML: false,
                                                    conserveEnergy: false, memoryPressure: .warning),
                       512 << 20)
    }
}
