import XCTest
@testable import cooViewer

/// 設定「高度」: マスタースイッチと保存値の解決(SettingsStore)
@MainActor
final class SettingsStoreAdvancedTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "advanced-test-\(UUID().uuidString)")!
        store = SettingsStore(defaults: defaults)
    }

    /// 表示モード(FitMode)と表紙単ページ(SpreadCoverSingle)の既定と往復
    func testFitModeAndCoverSingleAccessors() {
        XCTAssertEqual(store.fitMode, .fitToScreen)   // 未設定 = 0
        XCTAssertFalse(store.spreadCoverSingle)       // 既定オフ
        store.fitMode = .fitWidthDivide
        store.spreadCoverSingle = true
        XCTAssertEqual(defaults.integer(forKey: "FitMode"),
                       ReaderView.FitMode.fitWidthDivide.rawValue)
        XCTAssertEqual(store.fitMode, .fitWidthDivide)
        XCTAssertTrue(defaults.bool(forKey: "SpreadCoverSingle"))
    }

    func testDefaultsWhenSwitchIsOff() {
        // 保存値があってもマスタースイッチ OFF なら既定値
        defaults.set(40, forKey: "AdvancedPrefetchAhead")
        defaults.set(30, forKey: "AdvancedMemoryPercent")
        XCTAssertEqual(store.prefetchAheadCount, 12)
        XCTAssertEqual(store.prefetchBehindCount, 3)
        XCTAssertEqual(store.displayPixelCap, 4096)
        XCTAssertEqual(store.archiveSpoolSizeLimit, 4 << 30)
        XCTAssertEqual(store.prepareNextBookPages, 6)
        XCTAssertEqual(store.thumbnailCacheDays, 30)
    }

    func testStoredValuesWhenSwitchIsOn() {
        defaults.set(true, forKey: "AdvancedSettingsEnabled")
        defaults.set(40, forKey: "AdvancedPrefetchAhead")
        defaults.set(0, forKey: "AdvancedPrefetchBehind")
        defaults.set(8192, forKey: "AdvancedDisplayPixelCap")
        defaults.set(16, forKey: "AdvancedSpoolLimitGB")
        defaults.set(0, forKey: "AdvancedPrepareNextBookPages")
        defaults.set(7, forKey: "AdvancedThumbnailCacheDays")
        XCTAssertEqual(store.prefetchAheadCount, 40)
        XCTAssertEqual(store.prefetchBehindCount, 0)  // 0 = 逆方向なし
        XCTAssertEqual(store.displayPixelCap, 8192)
        XCTAssertEqual(store.archiveSpoolSizeLimit, 16 << 30)
        XCTAssertEqual(store.prepareNextBookPages, 0)  // 0 = 事前準備なし
        XCTAssertEqual(store.thumbnailCacheDays, 7)
    }

    func testArchiveSpoolPolicyFollowsMasterSwitch() {
        // マスタースイッチ OFF なら保存値があっても「自動」
        defaults.set(2, forKey: "AdvancedSpoolPolicy")
        XCTAssertEqual(store.archiveSpoolPolicy, .automatic)
        // ON なら保存値(常に/しない)を返す
        defaults.set(true, forKey: "AdvancedSettingsEnabled")
        XCTAssertEqual(store.archiveSpoolPolicy, .never)
        defaults.set(1, forKey: "AdvancedSpoolPolicy")
        XCTAssertEqual(store.archiveSpoolPolicy, .always)
        // 範囲外は丸められる(clamp で 2 = never)
        defaults.set(99, forKey: "AdvancedSpoolPolicy")
        XCTAssertEqual(store.archiveSpoolPolicy, .never)
    }

    func testSwitchOnWithoutStoredValuesFallsBackToDefaults() {
        defaults.set(true, forKey: "AdvancedSettingsEnabled")
        XCTAssertEqual(store.prefetchAheadCount, 12)
        XCTAssertEqual(store.advancedMemoryPercent, 15)
    }

    func testOutOfRangeValuesAreClamped() {
        defaults.set(true, forKey: "AdvancedSettingsEnabled")
        defaults.set(999, forKey: "AdvancedPrefetchAhead")
        defaults.set(-5, forKey: "AdvancedPrefetchBehind")
        defaults.set(90, forKey: "AdvancedMemoryPercent")
        XCTAssertEqual(store.prefetchAheadCount, 64)
        XCTAssertEqual(store.prefetchBehindCount, 0)
        XCTAssertEqual(store.advancedMemoryPercent, 50)
    }

    func testMemoryLimitUsesPercentWithoutCapWhenOn() {
        defaults.set(true, forKey: "AdvancedSettingsEnabled")
        defaults.set(30, forKey: "AdvancedMemoryPercent")
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(store.pageCacheByteLimit, physical / 100 * 30)
    }

    func testMemoryLimitKeepsLegacyBehaviorWhenOff() {
        // OFF: 15% を 16GB 上限で丸める標準動作
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        let standard = min(16 * 1024 * 1024 * 1024, physical / 100 * 15)
        XCTAssertEqual(store.pageCacheByteLimit, standard)
        // OFF では明示指定(PageCacheMegabytes)も無視して標準へ戻る
        defaults.set(256, forKey: "PageCacheMegabytes")
        XCTAssertEqual(store.pageCacheByteLimit, standard)
    }

    func testMemoryLimitExplicitMegabytesRequiresAdvancedOn() {
        // ON: MB 直指定 > メモリ%指定 の順で上書きできる
        defaults.set(true, forKey: "AdvancedSettingsEnabled")
        defaults.set(30, forKey: "AdvancedMemoryPercent")
        defaults.set(256, forKey: "PageCacheMegabytes")
        XCTAssertEqual(store.pageCacheByteLimit, 256 * 1024 * 1024)
        // OFF へ戻すと明示指定ごと標準動作へ復帰する
        defaults.set(false, forKey: "AdvancedSettingsEnabled")
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(store.pageCacheByteLimit,
                       min(16 * 1024 * 1024 * 1024, physical / 100 * 15))
    }
}
