import XCTest
@testable import cooViewer

/// 設定「高度」: マスタースイッチと保存値の解決(SettingsStore)
@MainActor
final class SettingsStoreAdvancedTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var originalXADZipLazyLocalHeaders = true
    private var originalKaitoZipLazyLocalHeaders = true

    override func setUp() {
        super.setUp()
        originalXADZipLazyLocalHeaders = XADMasterEngine.defaultZipLazyLocalHeaders
        originalKaitoZipLazyLocalHeaders = KaitoKitEngine.defaultZipLazyLocalHeaders
        defaults = UserDefaults(suiteName: "advanced-test-\(UUID().uuidString)")!
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        XADMasterEngine.setDefaultZipLazyLocalHeaders(originalXADZipLazyLocalHeaders)
        KaitoKitEngine.setDefaultZipLazyLocalHeaders(originalKaitoZipLazyLocalHeaders)
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testZipLazyLocalHeadersDefaultsToOnWhenUnset() {
        XCTAssertNil(defaults.object(forKey: "ZipLazyLocalHeaders"))
        XADMasterEngine.setDefaultZipLazyLocalHeaders(false)
        KaitoKitEngine.setDefaultZipLazyLocalHeaders(false)

        store.applyArchiveParserSettings()

        XCTAssertTrue(store.zipLazyLocalHeaders)
        XCTAssertTrue(XADMasterEngine.defaultZipLazyLocalHeaders)
        XCTAssertTrue(KaitoKitEngine.defaultZipLazyLocalHeaders)
    }

    func testZipLazyLocalHeadersOffReachesParserClassDefault() {
        store.zipLazyLocalHeaders = false

        XCTAssertFalse(defaults.bool(forKey: "ZipLazyLocalHeaders"))
        XCTAssertFalse(XADMasterEngine.defaultZipLazyLocalHeaders)
        XCTAssertFalse(KaitoKitEngine.defaultZipLazyLocalHeaders)
    }

    func testZipLazyLocalHeadersOnReachesParserClassDefault() {
        XADMasterEngine.setDefaultZipLazyLocalHeaders(false)
        KaitoKitEngine.setDefaultZipLazyLocalHeaders(false)

        store.zipLazyLocalHeaders = true

        XCTAssertTrue(defaults.bool(forKey: "ZipLazyLocalHeaders"))
        XCTAssertTrue(XADMasterEngine.defaultZipLazyLocalHeaders)
        XCTAssertTrue(KaitoKitEngine.defaultZipLazyLocalHeaders)
    }

    /// 書庫エンジンは KaitoKit 既定で文字列往復し、CLI 上書きは保存値を
    /// 変更せず当該プロセスだけに効く(設計書 §2.4 段階的な置き換え)。
    func testArchiveEngineRoundTripAndRuntimeOverride() {
        // registerDefaults で "kaitokit" が登録されるため object(forKey:) は nil にならない。
        // 登録既定値が KaitoKit であることを確認する
        XCTAssertEqual(defaults.string(forKey: "ArchiveEngine"), ArchiveEngineKind.kaitokit.rawValue)
        XCTAssertEqual(store.archiveEngine, .kaitokit)
        XCTAssertEqual(store.effectiveArchiveEngine, .kaitokit)

        store.archiveEngine = .xadmaster
        XCTAssertEqual(defaults.string(forKey: "ArchiveEngine"), "xadmaster")
        XCTAssertEqual(store.archiveEngine, .xadmaster)
        XCTAssertEqual(store.effectiveArchiveEngine, .xadmaster)

        store.overrideArchiveEngineForCurrentRun(.kaitokit)
        XCTAssertEqual(store.effectiveArchiveEngine, .kaitokit)
        XCTAssertEqual(defaults.string(forKey: "ArchiveEngine"), "xadmaster")
        store.overrideArchiveEngineForCurrentRun(nil)
        XCTAssertEqual(store.effectiveArchiveEngine, .xadmaster)

        // 未知の保存値は KaitoKit へ落とす。
        defaults.set("unknown", forKey: "ArchiveEngine")
        XCTAssertEqual(store.archiveEngine, .kaitokit)
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

    /// ComicInfo 読み方向の尊重フラグ(既定オフ・往復。cooViewer-4fi.4)
    func testRespectComicInfoReadingDirectionRoundTrip() {
        XCTAssertFalse(store.respectComicInfoReadingDirection)
        store.respectComicInfoReadingDirection = true
        XCTAssertTrue(defaults.bool(forKey: "RespectComicInfoReadingDirection"))
        XCTAssertTrue(store.respectComicInfoReadingDirection)
    }

    /// EPUB 脚注・組版・印刷ページの新設キーは安全な既定値から往復する。
    /// (cooViewer-oxr.32/.33/.38、設計書 §2.4)
    func testEPUBFootnoteTypographyAndPrintSettingsRoundTrip() {
        store.registerDefaults()

        XCTAssertTrue(store.epubFootnotePopover)
        XCTAssertFalse(store.epubHidesFootnoteAsides)
        XCTAssertEqual(store.epubLineHeightScale, 0)
        XCTAssertEqual(store.epubLetterSpacing, 0)
        XCTAssertEqual(store.epubParagraphSpacing, 0)
        XCTAssertFalse(store.epubForceFont)
        XCTAssertFalse(store.epubHidesRuby)
        XCTAssertFalse(store.epubShowsPrintPage)

        store.epubFootnotePopover = false
        store.epubHidesFootnoteAsides = true
        store.epubLineHeightScale = 1.8
        store.epubLetterSpacing = 1
        store.epubParagraphSpacing = 2
        store.epubForceFont = true
        store.epubHidesRuby = true
        store.epubShowsPrintPage = true

        XCTAssertFalse(store.epubFootnotePopover)
        XCTAssertTrue(store.epubHidesFootnoteAsides)
        XCTAssertEqual(store.epubLineHeightScale, 1.8)
        XCTAssertEqual(store.epubLetterSpacing, 1)
        XCTAssertEqual(store.epubParagraphSpacing, 2)
        XCTAssertTrue(store.epubForceFont)
        XCTAssertTrue(store.epubHidesRuby)
        XCTAssertTrue(store.epubShowsPrintPage)
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
