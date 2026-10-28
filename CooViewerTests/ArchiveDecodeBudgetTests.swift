import KaitoKit
import XCTest
@testable import cooViewer

final class ArchiveDecodeBudgetTests: XCTestCase {
    private let sixteenGB: UInt64 = 16 << 30

    func testPrimaryUsesAutomaticThreadsAndKeepsTodaysBudgetAt16GB() {
        for auto in [1, 4, 16] {
            let budget = ArchiveDecodeBudget(role: .primary, automaticThreads: auto,
                                             physicalMemory: sixteenGB, memoryPressure: .normal,
                                             powerPolicy: .lowPowerModeOrThermal)
            XCTAssertNil(budget.decodeThreads)
            XCTAssertEqual(budget.powerPolicy, .reduceInLowPowerModeOrThermalPressure)
            XCTAssertEqual(budget.parallelDecodeMemory, 256 << 20)
        }
    }

    func testExtractorBudgetUsesPowerAdjustedAutomaticThreads() {
        // 自動値は KaitoKit が各電力状態で解決済み。アプリ側で二度半減しない(設計書 §5)。
        for (pool, expected) in [(3, [1, 2, 5]), (6, [1, 2, 2])] {
            for (auto, threads) in zip([1, 4, 16], expected) {
                let budget = ArchiveDecodeBudget(role: .extractor(poolSize: pool), automaticThreads: auto,
                                                 physicalMemory: sixteenGB, memoryPressure: .normal,
                                                 powerPolicy: .lowPowerModeOrThermal)
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
            let budget = ArchiveDecodeBudget(role: .extractor(poolSize: pool), automaticThreads: auto,
                                             physicalMemory: sixteenGB, memoryPressure: .normal,
                                             powerPolicy: .lowPowerModeOrThermal)
            XCTAssertEqual(pool, conserveEnergy ? 3 : 6)
            XCTAssertEqual(budget.decodeThreads, 2)
        }
        let singleCore = ArchiveDecodeBudget(role: .extractor(poolSize: 2), automaticThreads: 1,
                                             physicalMemory: sixteenGB, memoryPressure: .normal,
                                             powerPolicy: .lowPowerModeOrThermal)
        XCTAssertEqual(singleCore.decodeThreads, 1)
    }

    /// 設定の三択を KaitoKit の方針へ一対一で写し、ReaderOptions にそのまま載せる(設計書 §5)
    func testPowerPolicyMapsToDecodePowerPolicy() {
        let expected: [PowerPolicy: DecodePowerPolicy] = [
            .lowPowerModeOrThermal: .reduceInLowPowerModeOrThermalPressure,
            .lowPowerModeOnly: .reduceInLowPowerMode,
            .alwaysFullSpeed: .alwaysUseAllCores,
        ]
        XCTAssertEqual(Set(expected.keys), Set(PowerPolicy.allCases))
        for (policy, decodePolicy) in expected {
            XCTAssertEqual(policy.decodePowerPolicy, decodePolicy)
            for role in [ArchiveReaderRole.primary, .extractor(poolSize: 6)] {
                let budget = ArchiveDecodeBudget(role: role, automaticThreads: 16,
                                                 physicalMemory: sixteenGB, memoryPressure: .normal,
                                                 powerPolicy: policy)
                XCTAssertEqual(budget.powerPolicy, decodePolicy, "\(policy) \(role)")
                XCTAssertEqual(budget.readerOptions(lazyLocalHeaders: true).decodePowerPolicy, decodePolicy)
                // 方針は予算と並列数を変えない(KaitoKit が open 時に自動値へ反映する)
                XCTAssertEqual(budget.parallelDecodeMemory, role == .primary ? 256 << 20 : 128 << 20)
            }
        }
    }

    func testOptionsPreserveOtherReadLimitsAndLazyHeaderSnapshot() {
        for role in [ArchiveReaderRole.primary, .extractor(poolSize: 6)] {
            let budget = ArchiveDecodeBudget(role: role, automaticThreads: 16,
                                             physicalMemory: sixteenGB, memoryPressure: .normal,
                                             powerPolicy: .lowPowerModeOrThermal)
            let options = budget.readerOptions(lazyLocalHeaders: false)
            XCTAssertEqual(options.decodeThreads, budget.decodeThreads)
            XCTAssertEqual(options.decodePowerPolicy, .reduceInLowPowerModeOrThermalPressure)
            XCTAssertFalse(options.lazyLocalHeaders)
            XCTAssertEqual(options.appleDoublePolicy, .expose)
            var defaults = ReadLimits()
            defaults.parallelDecodeMemory = budget.parallelDecodeMemory
            XCTAssertEqual(options.limits, defaults)
        }
    }

    /// 物理メモリに比例する曲線 × 圧迫段階 × 役割: 主 = clamp(RAM/64, 64 MiB, 256 MiB)、
    /// 展開係はその半分、圧迫中はクランプ後に 1/2・1/4。16 GB 以上は従来の 256 / 128 MiB
    /// のまま(設計書 §5)
    func testRAMCurveAndPressureFactors() {
        for (ramGB, primaryMiB): (UInt64, UInt64) in [(8, 128), (16, 256), (36, 256), (64, 256), (128, 256)] {
            for (level, divisor): (MemoryPressureLevel, UInt64) in [(.normal, 1), (.warning, 2), (.critical, 4)] {
                for role in [ArchiveReaderRole.primary, .extractor(poolSize: 6)] {
                    let budget = ArchiveDecodeBudget(role: role, automaticThreads: 16,
                                                     physicalMemory: ramGB << 30, memoryPressure: level,
                                                     powerPolicy: .lowPowerModeOrThermal)
                    let roleDivisor: UInt64 = role == .primary ? 1 : 2
                    XCTAssertEqual(budget.parallelDecodeMemory, (primaryMiB << 20) / (divisor * roleDivisor),
                                   "\(ramGB) GB \(level) \(role)")
                }
            }
        }
        // クランプの両端: 下限 64 MiB(2 GB 以下)、上限 256 MiB
        XCTAssertEqual(ArchiveDecodeBudget.parallelDecodeMemory(
            role: .primary, physicalMemory: 0, memoryPressure: .normal), 64 << 20)
        XCTAssertEqual(ArchiveDecodeBudget.parallelDecodeMemory(
            role: .extractor(poolSize: 2), physicalMemory: 2 << 30, memoryPressure: .normal), 32 << 20)
        XCTAssertEqual(ArchiveDecodeBudget.parallelDecodeMemory(
            role: .primary, physicalMemory: .max, memoryPressure: .normal), 256 << 20)
    }

    func testExtractorPoolShrinksInLowPowerMode() {
        for cores in [1, 4, 8, 16, 32] {
            let normal = ArchiveSource.extractorPoolSize(conserveEnergy: false, processorCount: cores)
            XCTAssertEqual(ArchiveSource.extractorPoolSize(conserveEnergy: true, processorCount: cores),
                           max(2, normal / 2))
        }
    }
}
