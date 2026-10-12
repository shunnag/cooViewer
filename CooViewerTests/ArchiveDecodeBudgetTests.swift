import KaitoKit
import XCTest
@testable import cooViewer

final class ArchiveDecodeBudgetTests: XCTestCase {
    func testPrimaryUsesAutomaticThreadsAndFixedMemoryBudget() {
        for auto in [1, 4, 16] {
            let budget = ArchiveDecodeBudget(role: .primary, automaticThreads: auto)
            XCTAssertNil(budget.decodeThreads)
            XCTAssertEqual(budget.powerPolicy, .reduceInLowPowerModeOrThermalPressure)
            XCTAssertEqual(budget.parallelDecodeMemory, 256 << 20)
        }
    }

    func testExtractorBudgetUsesPowerAdjustedAutomaticThreads() {
        // 自動値は KaitoKit が各電力状態で解決済み。アプリ側で二度半減しない(設計書 §5)。
        for (pool, expected) in [(3, [1, 2, 5]), (6, [1, 2, 2])] {
            for (auto, threads) in zip([1, 4, 16], expected) {
                let budget = ArchiveDecodeBudget(role: .extractor(poolSize: pool), automaticThreads: auto)
                XCTAssertEqual(budget.decodeThreads, threads, "auto=\(auto)、pool=\(pool)")
                XCTAssertEqual(budget.powerPolicy, .reduceInLowPowerModeOrThermalPressure)
                XCTAssertEqual(budget.parallelDecodeMemory, 128 << 20)
            }
        }
    }

    func testNormalAndLowPowerBudgetsUseTheirOpeningState() {
        for conserveEnergy in [false, true] {
            let pool = ArchiveSource.extractorPoolSize(conserveEnergy: conserveEnergy, processorCount: 16)
            let auto = conserveEnergy ? 4 : 16
            let budget = ArchiveDecodeBudget(role: .extractor(poolSize: pool), automaticThreads: auto)
            XCTAssertEqual(pool, conserveEnergy ? 3 : 6)
            XCTAssertEqual(budget.decodeThreads, 2)
        }
        let singleCore = ArchiveDecodeBudget(role: .extractor(poolSize: 2), automaticThreads: 1)
        XCTAssertEqual(singleCore.decodeThreads, 1)
    }

    func testOptionsPreserveOtherReadLimitsAndLazyHeaderSnapshot() {
        for role in [ArchiveReaderRole.primary, .extractor(poolSize: 6)] {
            let budget = ArchiveDecodeBudget(role: role, automaticThreads: 16)
            let options = budget.readerOptions(lazyLocalHeaders: false)
            XCTAssertEqual(options.decodeThreads, budget.decodeThreads)
            XCTAssertEqual(options.decodePowerPolicy, .reduceInLowPowerModeOrThermalPressure)
            XCTAssertFalse(options.lazyLocalHeaders)
            var defaults = ReadLimits()
            defaults.parallelDecodeMemory = budget.parallelDecodeMemory
            XCTAssertEqual(options.limits, defaults)
        }
    }

    func testExtractorPoolShrinksInLowPowerMode() {
        for cores in [1, 4, 8, 16, 32] {
            let normal = ArchiveSource.extractorPoolSize(conserveEnergy: false, processorCount: cores)
            XCTAssertEqual(ArchiveSource.extractorPoolSize(conserveEnergy: true, processorCount: cores),
                           max(2, normal / 2))
        }
    }
}
