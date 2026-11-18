import AppKit
import CoreGraphics
import ImageIO
@testable import PrintAppearanceKit
import UniformTypeIdentifiers
import Washi
import XCTest
@testable import cooViewer

// 網かけの表示の設定・メニュー・キー操作・準備の契機・アクティビティ窓(設計書 §2.4・§5・§7.5)。
// 画像はすべて式で描いた合成のもの。実ユーザーの defaults(UserDefaults.standard の永続ドメイン)には
// 書かず、値は引数ドメインだけで与える(メニューの書き込み側は SettingsStore を隔離したスイートで確かめる)。

/// UserDefaults.standard の引数ドメインを一時的に上書きする。永続ドメインには書かない
@MainActor
private final class ArgumentDefaults {
    private let previous: [String: Any]
    private var current: [String: Any]

    init(_ values: [String: Any]) {
        previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        current = values
        apply()
    }

    func set(_ values: [String: Any]) {
        current.merge(values) { _, new in new }
        apply()
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain)
    }

    private func apply() {
        UserDefaults.standard.setVolatileDomain(previous.merging(current) { _, new in new },
                                                forName: UserDefaults.argumentDomain)
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// 画像の先頭の画素の値(灰色の合成ページの見分け用)
private func firstByte(_ image: CGImage?) -> UInt8? {
    guard let image, let data = image.dataProvider?.data, CFDataGetLength(data) > 0 else { return nil }
    return CFDataGetBytePtr(data)[0]
}

/// 段階ごとに違う値の灰色のページを返す読み込み元。規則に合う要求を止め、テストが放す。
/// ルーペの画像は高さで段階を表す(幅は表示より大きくして、差し込みの解像度の照合を通す)
private actor HalftoneToggleStubSource: BookSource {
    nonisolated let url: URL
    nonisolated var supportsDateSort: Bool { false }
    nonisolated let supportsParallelPageLoads: Bool

    struct Request: Sendable {
        let entryID: Int
        let level: PrintAppearanceLevel?
        let hasRequest: Bool
        let prefetch: Bool
    }

    private let pageCount: Int
    private var holdRule: @Sendable (Request) -> Bool = { _ in false }
    private(set) var requests: [Request] = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]

    init(pageCount: Int, parallel: Bool = false) {
        self.pageCount = pageCount
        supportsParallelPageLoads = parallel
        url = URL(fileURLWithPath: "/stub/halftone-toggle-\(UUID().uuidString)")
    }

    var heldCount: Int { held.count }
    var heldIndices: [Int] { held.keys.sorted() }

    func setHold(_ rule: @escaping @Sendable (Request) -> Bool) { holdRule = rule }

    nonisolated static func value(for level: PrintAppearanceLevel?) -> UInt8 {
        switch level {
        case nil: 10
        case .low: 60
        case .standard: 120
        case .strong: 200
        }
    }

    /// ルーペの画像の幅(ページの画像より大きい)
    nonisolated static let loupeWidth = 4096

    nonisolated static func loupeHeight(for level: PrintAppearanceLevel?) -> Int {
        switch level {
        case nil: 1
        case .low: 2
        case .standard: 3
        case .strong: 4
        }
    }

    nonisolated static func gray(value: UInt8, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        memset(context.data!, Int32(value), context.bytesPerRow * height)
        return context.makeImage()!
    }

    func entries() async throws -> [PageEntry] {
        (0..<pageCount).map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func imageSize(for entry: PageEntry) async -> CGSize? {
        CGSize(width: 8 + entry.id, height: 24)
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let request = Request(entryID: entry.id, level: PageRequestIntent.printAppearance?.level,
                              hasRequest: PageRequestIntent.printAppearance != nil,
                              prefetch: PageRequestIntent.isPrefetch)
        let index = requests.count
        requests.append(request)
        if holdRule(request) {
            await withCheckedContinuation { held[index] = $0 }
        }
        return Self.gray(value: Self.value(for: request.level), width: 8 + entry.id, height: 24)
    }

    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        Self.gray(value: 0, width: Self.loupeWidth, height: Self.loupeHeight(for: PageRequestIntent.printAppearance?.level))
    }

    func releaseAll() {
        let all = held
        held.removeAll()
        for continuation in all.values { continuation.resume() }
    }
}

/// 中身のあるリフロー EPUB の最小の出版物(EPUB 表示モードを作るため)
private func makeReflowPublication() throws -> EPUBPublication {
    let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """
    let package = """
    <?xml version="1.0"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">halftone-menu-test</dc:identifier>
        <dc:title>網かけ</dc:title>
        <dc:language>ja</dc:language>
        <meta property="dcterms:modified">2026-11-13T00:00:00Z</meta>
      </metadata>
      <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
      <spine><itemref idref="chapter"/></spine>
    </package>
    """
    let chapter = """
    <?xml version="1.0"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>本文</title></head><body><p>本文</p></body></html>
    """
    let data = TestFixtures.storedZip(entries: [
        (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
        (Array("META-INF/container.xml".utf8), Data(container.utf8)),
        (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
        (Array("OEBPS/chapter.xhtml".utf8), Data(chapter.utf8)),
    ])
    return try EPUBPublication(data: data, displayURL: URL(fileURLWithPath: "/test/halftone-menu.epub"))
}

// MARK: - 設定の書き込み(メニュー・キー操作・ペインが使う SettingsStore の側)

@MainActor
final class HalftoneDisplaySettingWriteTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() async throws {
        suiteName = "test.cooViewer.halftone-ui.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults, powerMonitor: PowerStateMonitor(center: NotificationCenter(),
            readState: { PowerConditions(isLowPowerModeEnabled: false, isThermalPressureActive: false) }))
        store.registerDefaults()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
    }

    /// キー操作 55 の切り替えは入と切を往復し、強さは変えない。未知の保存値は切として読むので入になる
    func testToggleRoundTripsAndKeepsStrength() {
        store.halftoneDisplayStrength = .strong
        store.toggleHalftoneDisplay()
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 1)
        XCTAssertEqual(store.printAppearanceRequest, .strong)
        store.toggleHalftoneDisplay()
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 0)
        XCTAssertNil(store.printAppearanceRequest)
        XCTAssertEqual(store.halftoneDisplayStrength, .strong)

        defaults.set(5, forKey: "HalftoneDisplayMode")
        store.toggleHalftoneDisplay()
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 1)
    }

    /// メニューの項目のタグ(モード 0/1・強さ 0/1/2)は defaults の値そのもの
    func testMenuTagsAreTheStoredValues() {
        for level in PrintAppearanceLevel.allCases {
            store.halftoneDisplayStrength = level
            XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayStrength"), level.rawValue)
        }
        XCTAssertEqual(PrintAppearanceLevel.allCases.map(\.rawValue), [0, 1, 2])
        store.halftoneDisplayEnabled = true
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 1)
        store.halftoneDisplayEnabled = false
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 0)
    }
}

// MARK: - 表示メニューとキー操作

@MainActor
final class HalftoneDisplayMenuTests: XCTestCase {
    private func viewMenu() throws -> NSMenu {
        let main = MainMenuBuilder.build()
        return try XCTUnwrap(main.items.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.submenu?.items.contains {
                $0.action == #selector(ReaderWindowController.changeInterpolation(_:)) } == true }
        })
    }

    /// 表示メニューの「補間」の次に「網かけの表示」: 2 つの選択、区切り、3 段階の強さ。キーイクイバレントなし
    func testViewMenuHasHalftoneSubmenuAfterInterpolation() throws {
        let menu = try viewMenu()
        let interpolation = try XCTUnwrap(menu.items.firstIndex { $0.submenu?.items.contains {
            $0.action == #selector(ReaderWindowController.changeInterpolation(_:)) } == true })
        let item = menu.items[interpolation + 1]
        XCTAssertEqual(item.title, String(localized: "Halftone Display"))
        let submenu = try XCTUnwrap(item.submenu)
        XCTAssertEqual(submenu.items.map(\.isSeparatorItem), [false, false, true, false, false, false])
        let modes = Array(submenu.items[0...1])
        let strengths = Array(submenu.items[3...5])
        XCTAssertEqual(modes.map(\.title), [String(localized: "As scanned"), String(localized: "Like the printed book")])
        XCTAssertEqual(modes.map(\.tag), [0, 1])
        XCTAssertTrue(modes.allSatisfy {
            $0.action == #selector(ReaderWindowController.changeHalftoneDisplayMode(_:)) })
        XCTAssertEqual(strengths.map(\.title),
                       [String(localized: "Subtle"), String(localized: "Standard"), String(localized: "Strong")])
        XCTAssertEqual(strengths.map(\.tag), PrintAppearanceLevel.allCases.map(\.rawValue))
        XCTAssertTrue(strengths.allSatisfy {
            $0.action == #selector(ReaderWindowController.changeHalftoneDisplayStrength(_:)) })
        XCTAssertTrue(submenu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    private func item(_ action: Selector, tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        return item
    }

    /// チェックは設定の値、強さは切っている間は無効(選んだ値のチェックは残す)。未知の値は既定として示す。
    /// リフロー EPUB の表示モードでは全項目が無効で、キー操作 55 も処理しない(ビープで消費)
    func testValidationFollowsSettingAndDisablesEverythingInEPUBMode() throws {
        let arguments = ArgumentDefaults(["HalftoneDisplayMode": 0, "HalftoneDisplayStrength": 2])
        defer { arguments.restore() }
        let controller = ReaderWindowController(window: nil)
        let modes = [0, 1].map { item(#selector(ReaderWindowController.changeHalftoneDisplayMode(_:)), tag: $0) }
        let strengths = PrintAppearanceLevel.allCases.map {
            item(#selector(ReaderWindowController.changeHalftoneDisplayStrength(_:)), tag: $0.rawValue)
        }
        func validate() -> (modes: [Bool], strengths: [Bool]) {
            (modes.map(controller.validateMenuItem), strengths.map(controller.validateMenuItem))
        }

        var enabled = validate()
        XCTAssertEqual(enabled.modes, [true, true])
        XCTAssertEqual(enabled.strengths, [false, false, false], "切っている間は強さを選べない")
        XCTAssertEqual(modes.map(\.state), [.on, .off])
        XCTAssertEqual(strengths.map(\.state), [.off, .off, .on])

        arguments.set(["HalftoneDisplayMode": 1, "HalftoneDisplayStrength": 0])
        enabled = validate()
        XCTAssertEqual(enabled.modes, [true, true])
        XCTAssertEqual(enabled.strengths, [true, true, true])
        XCTAssertEqual(modes.map(\.state), [.off, .on])
        XCTAssertEqual(strengths.map(\.state), [.on, .off, .off])

        arguments.set(["HalftoneDisplayMode": 5, "HalftoneDisplayStrength": 9])
        enabled = validate()
        XCTAssertEqual(enabled.strengths, [false, false, false])
        XCTAssertEqual(modes.map(\.state), [.on, .off])
        XCTAssertEqual(strengths.map(\.state), [.off, .on, .off])

        arguments.set(["HalftoneDisplayMode": 1, "HalftoneDisplayStrength": 1])
        controller.epubSession = EPUBReadingSession(publication: try makeReflowPublication(),
                                                    url: URL(fileURLWithPath: "/test/halftone-menu.epub"))
        defer { controller.epubSession?.end() }
        XCTAssertTrue(controller.isEPUBMode)
        enabled = validate()
        XCTAssertEqual(enabled.modes, [false, false])
        XCTAssertEqual(enabled.strengths, [false, false, false])
        XCTAssertFalse(controller.performEPUB(.toggleHalftoneDisplay, leftHalf: nil),
                       "EPUB の縮小ディスパッチャは処理しない(キーはビープで消費される)")
    }

    /// 既定の h はキーの解決で切り替えの操作になり、名前は「網かけの表示を切り替え」
    func testDefaultHResolvesToToggleWithName() {
        let binding = BindingConfiguration.builtInDefaults.resolveKey(character: "h", modifiers: 0,
                                                                      fitMode: 0, readsFromLeft: false)
        XCTAssertEqual(binding?.legacyActionNumber, 55)
        XCTAssertEqual(binding?.action, .toggleHalftoneDisplay)
        XCTAssertEqual(ActionNames.keyActionName(55), String(localized: "Toggle Halftone Display"))
        XCTAssertTrue(ActionNames.keyActionCategories.contains { $0.numbers.contains(55) })
    }
}

// MARK: - 準備と解放の契機

@MainActor
final class PrintAppearanceLifecycleTests: XCTestCase {
    /// 最初の観測は記録だけ。以後は切 ↔ 入の変わり目でだけ準備・解放する
    func testActsOnlyOnTransitionsAfterTheFirstObservation() {
        var events: [String] = []
        let lifecycle = PrintAppearanceLifecycle(isAllowed: { true }, prepare: { events.append("prepare") },
                                                 release: { events.append("release") })
        lifecycle.observe(enabled: true)
        lifecycle.observe(enabled: true)
        XCTAssertEqual(events, [], "入れて起動したときの準備は起動時の予熱が受け持つ")
        lifecycle.observe(enabled: false)
        lifecycle.observe(enabled: false)
        lifecycle.observe(enabled: true)
        XCTAssertEqual(events, ["release", "prepare"])

        var offEvents: [String] = []
        let offAtLaunch = PrintAppearanceLifecycle(isAllowed: { true }, prepare: { offEvents.append("prepare") },
                                                   release: { offEvents.append("release") })
        offAtLaunch.observe(enabled: false)
        XCTAssertEqual(offEvents, [], "切って起動したら共有のサービスに触れない")
        offAtLaunch.observe(enabled: true)
        XCTAssertEqual(offEvents, ["prepare"])
    }

    /// XCTest(と書庫監査)では既定の契機は何もしない
    func testDefaultLifecycleDoesNothingInsideXCTest() {
        XCTAssertTrue(AutomatedRun.isXCTest)
        XCTAssertFalse(PrintAppearanceLifecycle.isAllowedInThisProcess)
        var events: [String] = []
        let lifecycle = PrintAppearanceLifecycle(prepare: { events.append("prepare") },
                                                 release: { events.append("release") })
        lifecycle.observe(enabled: false)
        lifecycle.observe(enabled: true)
        lifecycle.observe(enabled: false)
        XCTAssertEqual(events, [])
    }

    /// applySettings は本がなくても切 ↔ 入を契機へ伝える。強さだけの変更では何もしない
    func testApplySettingsDrivesTheLifecycleWithoutABook() {
        let arguments = ArgumentDefaults(["HalftoneDisplayMode": 0, "HalftoneDisplayStrength": 1])
        defer { arguments.restore() }
        var events: [String] = []
        let controller = ReaderWindowController(window: nil)
        controller.printAppearanceLifecycle = PrintAppearanceLifecycle(
            isAllowed: { true }, prepare: { events.append("prepare") }, release: { events.append("release") })
        controller.applySettings()
        arguments.set(["HalftoneDisplayMode": 1])
        controller.applySettings()
        arguments.set(["HalftoneDisplayStrength": 2])
        controller.applySettings()
        arguments.set(["HalftoneDisplayMode": 0])
        controller.applySettings()
        XCTAssertEqual(events, ["prepare", "release"])
        XCTAssertNil(controller.book)
    }
}

// MARK: - 切り替えの表示(古い画素・未処理の画素を挟まない)

@MainActor
final class HalftoneDisplayToggleTests: XCTestCase {
    /// 設定を変えて applySettings(メニュー・ペイン・キー操作が defaults を書いた後と同じ経路)を通すと、
    /// 新しい見開きが揃うまで古い見開きと古いキー・印を保ち、揃ったら 3 つを一度に差し替える。
    /// ルーペも新しい段階で取り直し、別の段階の画像を映さない
    func testToggleSwapsTheSpreadInOneStepWithoutStaleOrRawFrames() async throws {
        let arguments = ArgumentDefaults(["NoiseReductionLevel": 0, "HalftoneDisplayMode": 0,
                                          "HalftoneDisplayStrength": 1, "AdvancedSettingsEnabled": 0,
                                          "LoupeRate": 1.0])
        defer { arguments.restore() }
        let suiteName = "test.cooViewer.halftone-toggle.\(UUID().uuidString)"
        let historyDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let historyDirectory = try TestFixtures.makeTempDir()
        defer {
            historyDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: historyDirectory)
        }
        let source = HalftoneToggleStubSource(pageCount: 6)
        let controller = ReaderWindowController(
            window: nil, history: BookHistoryStore(defaults: historyDefaults, directory: historyDirectory))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = controller.readerViewForInput
        window.contentView = view
        defer { window.contentView = nil }
        let book = try await Book.open(source: source, printAppearance: SettingsStore.shared.printAppearanceRequest)
        book.readMode = .leftToRightSingle
        controller.replaceBook(book)
        await controller.refreshDisplay()
        XCTAssertEqual(firstByte(view.images.first), HalftoneToggleStubSource.value(for: nil))
        XCTAssertEqual(view.printAppearanceTag, "")
        XCTAssertEqual(view.resampleKeyPrefix, book.cacheKey)
        view.enableLoupe(size: 16, rate: 1)
        await controller.requestLoupeHighResolution()?.value
        XCTAssertEqual(view.loupePageImages.map(\.height), [HalftoneToggleStubSource.loupeHeight(for: nil)])

        let levelByTag = Dictionary(uniqueKeysWithValues: ([nil] + PrintAppearanceLevel.allCases.map { $0 })
            .map { (PrintAppearanceTag.tag(for: $0), $0) })
        var violations: [String] = []
        var observedTags = [""]
        func check(_ label: String) {
            let tag = view.printAppearanceTag
            guard let level = levelByTag[tag] else {
                violations.append("\(label): 未知の印 \(tag)")
                return
            }
            if view.resampleKeyPrefix != book.cacheKey + tag {
                violations.append("\(label): キー \(view.resampleKeyPrefix) と印 \(tag)")
            }
            if firstByte(view.images.first) != HalftoneToggleStubSource.value(for: level) {
                violations.append("\(label): 印 \(tag) の下に別の画素 \(String(describing: firstByte(view.images.first)))")
            }
            // ルーペの高解像度の画像(幅で見分ける)が届いていれば、印と同じ段階のものだけ。届く前は表示中の
            // ページの画像を映すので、それは上の画素の照合で足りる
            let loupeHeights = view.loupePageImages.filter { $0.width == HalftoneToggleStubSource.loupeWidth }
                .map(\.height)
            if loupeHeights.contains(where: { $0 != HalftoneToggleStubSource.loupeHeight(for: level) }) {
                violations.append("\(label): ルーペ \(loupeHeights) と印 \(tag)")
            }
            if observedTags.last != tag { observedTags.append(tag) }
        }

        func step(_ label: String, _ values: [String: Any], level: PrintAppearanceLevel?) async throws {
            await source.setHold { $0.entryID == 0 && $0.level == level && !$0.prefetch }
            let oldTag = view.printAppearanceTag
            arguments.set(values)
            XCTAssertEqual(SettingsStore.shared.printAppearanceRequest, level, label)
            controller.applySettings()
            XCTAssertEqual(book.printAppearanceLevel, level, "\(label): 本は同期で切り替わる")
            let issued = await waitUntil {
                check("\(label) 発行待ち")
                return await source.heldCount == 1
            }
            XCTAssertTrue(issued, "\(label): 新しい印で表示の読み込みを出す")
            let stay = ContinuousClock.now + .milliseconds(200)
            while ContinuousClock.now < stay {
                check("\(label) 保留中")
                XCTAssertEqual(view.printAppearanceTag, oldTag, "\(label): 揃うまで古い見開きのまま")
                try await Task.sleep(for: .milliseconds(2))
            }
            await source.releaseAll()
            let target = PrintAppearanceTag.tag(for: level)
            let swapped = await waitUntil {
                check("\(label) 差し替え")
                return view.printAppearanceTag == target
            }
            XCTAssertTrue(swapped, "\(label): 差し替わる")
            let loupe = await waitUntil {
                check("\(label) ルーペ")
                return view.loupePageImages.map(\.height) == [HalftoneToggleStubSource.loupeHeight(for: level)]
            }
            XCTAssertTrue(loupe, "\(label): ルーペも新しい段階")
            for _ in 0..<25 {
                check("\(label) 落ち着き")
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        try await step("入", ["HalftoneDisplayMode": 1], level: .standard)
        try await step("強め", ["HalftoneDisplayStrength": 2], level: .strong)
        try await step("控えめ", ["HalftoneDisplayStrength": 0], level: .low)
        try await step("切", ["HalftoneDisplayMode": 0], level: nil)
        XCTAssertEqual(violations, [])
        XCTAssertEqual(observedTags, ["", PrintAppearanceTag.tag(for: .standard), PrintAppearanceTag.tag(for: .strong),
                                      PrintAppearanceTag.tag(for: .low), ""])
        view.disableLoupe()
        controller.cancelLoupeHighResolution()
        await source.releaseAll()
        await book.close().value
    }

    /// 切っていたときに立てた先読みの計画は、入れた時点で止まる。計画し直すまで要求付きの読み込みを
    /// 始めず、計画し直した後もエンジンを待つ読み込みは幅 4 まで(設計書 §5)
    func testSwitchOnStopsTheRunningPrefetchPlan() async throws {
        let source = HalftoneToggleStubSource(pageCount: 60, parallel: true)
        await source.setHold { $0.prefetch }
        let book = try await Book.open(source: source)
        book.readMode = .leftToRightSingle
        book.mediaProfile = MediaProfile(mediaClass: .fastLocal, conserveEnergy: false)
        book.prefetchAhead = 40
        book.prefetchBehind = 0
        _ = await book.currentSpread()
        let width = book.mediaProfile.bookPrefetchConcurrency
        XCTAssertGreaterThan(width, 4)
        let started = await waitUntil { await source.heldCount == width }
        XCTAssertTrue(started, "切っているときの幅で先読みが走る")
        let before = await source.requests.count

        XCTAssertTrue(book.updatePrintAppearance(.standard))
        await source.releaseAll()
        try await Task.sleep(for: .milliseconds(200))
        let afterToggle = await source.requests
        XCTAssertEqual(afterToggle.count, before, "止めた計画は新しい読み込みを始めない")
        XCTAssertFalse(afterToggle.contains { $0.hasRequest })

        _ = await book.currentSpread()
        let replanned = await waitUntil { await source.heldCount == 4 }
        XCTAssertTrue(replanned)
        try await Task.sleep(for: .milliseconds(100))
        let held = await source.heldIndices
        let requests = await source.requests
        XCTAssertEqual(held.count, 4, "要求付きの先読みは幅 4 まで")
        XCTAssertTrue(held.allSatisfy { requests[$0].hasRequest && requests[$0].level == .standard })

        let closing = book.close()
        for _ in 0..<40 {
            await source.releaseAll()
            try await Task.sleep(for: .milliseconds(5))
        }
        await closing.value
    }
}

// MARK: - ルーペ(実際のデコードの経路)

@MainActor
final class HalftoneDisplayLoupeTests: XCTestCase {
    /// フォルダの合成の網点ページで、ルーペの高解像度の画像は網点処理の入口の出力と同じ画素で、
    /// 処理しないデコードとは違う。切ればルーペも処理しない画素に戻る
    func testLoupeShowsTheProcessedPageOnTheRealDecodePath() async throws {
        // ルーペの倍率 1: 原寸のページで足り、超解像で拡大しない(拡大すると網点処理の画素と比べられない)
        let arguments = ArgumentDefaults(["NoiseReductionLevel": 0, "HalftoneDisplayMode": 1,
                                          "HalftoneDisplayStrength": 1, "AdvancedSettingsEnabled": 0,
                                          "LoupeRate": 1.0])
        defer { arguments.restore() }
        let directory = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 384, height = 576
        let data = try Self.grayPNG(PrintAppearanceTestPages.screen(width: width, height: height, period: 4,
                                                                    angle: 45), width: width, height: height)
        try data.write(to: directory.appendingPathComponent("page.png"))
        let suiteName = "test.cooViewer.halftone-loupe.\(UUID().uuidString)"
        let historyDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { historyDefaults.removePersistentDomain(forName: suiteName) }
        let controller = ReaderWindowController(
            window: nil, history: BookHistoryStore(defaults: historyDefaults,
                                                   directory: directory.appendingPathComponent("states")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = controller.readerViewForInput
        window.contentView = view
        defer { window.contentView = nil }
        let source = try FolderSource(url: directory, readSubFolders: false)
        let book = try await Book.open(source: source, printAppearance: SettingsStore.shared.printAppearanceRequest)
        book.readMode = .leftToRightSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        controller.replaceBook(book)
        await controller.refreshDisplay()
        XCTAssertEqual(view.printAppearanceTag, PrintAppearanceTag.tag(for: .standard))

        view.enableLoupe(size: 16, rate: 1)
        await controller.requestLoupeHighResolution()?.value
        let loupe = try XCTUnwrap(view.loupePageImages.first)
        XCTAssertEqual(loupe.width, width)
        XCTAssertEqual(loupe.height, height)
        let processed = try await PageRequestIntent.$printAppearance.withValue(
            PrintAppearanceRequest(level: .standard)) {
            try await PageImageDecoding.decode(data, maxPixelSize: nil)
        }
        let raw = try ImageDecoding.decode(data, maxPixelSize: nil, displayTarget: nil)
        XCTAssertEqual(try Self.grayBytes(loupe), try Self.grayBytes(processed), "ルーペは処理した画素")
        XCTAssertNotEqual(try Self.grayBytes(loupe), try Self.grayBytes(raw), "網点を処理していない画素ではない")

        arguments.set(["HalftoneDisplayMode": 0])
        controller.applySettings()
        let restored = await waitUntil(timeout: .seconds(20)) {
            guard view.printAppearanceTag.isEmpty, let image = view.loupePageImages.first,
                  let bytes = try? Self.grayBytes(image) else { return false }
            return bytes == (try? Self.grayBytes(raw))
        }
        XCTAssertTrue(restored, "切ればルーペも処理しない画素")
        view.disableLoupe()
        controller.cancelLoupeHighResolution()
        await book.close().value
    }

    private static func grayPNG(_ values: [UInt8], width: Int, height: Int) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(values) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString,
                                                                         1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 8 bit の灰色に描き直した W * H バイト(行の詰め物と色空間の違いを除いて比べる)
    private static func grayBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
                  let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width, space: space,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw CocoaError(.coderInvalidValue) }
        return bytes
    }
}

// MARK: - アクティビティ窓と統計の書き出し

final class HalftoneActivityTests: XCTestCase {
    private func halftone(enabled: Bool = true, level: PrintAppearanceLevel = .standard,
                          stats: PrintAppearanceService.Stats,
                          plan: ActivitySnapshot.Halftone.Plan? = nil) -> ActivitySnapshot.Halftone {
        ActivitySnapshot.Halftone(enabled: enabled, level: level, stats: stats, plan: plan, displayThreads: 8,
                                  prefetchThreads: 4, maxPixels: 16_000_000)
    }

    /// 一度も使っていなければ節を出さない。入れたか、エンジンが動いたことがあれば出す
    func testSectionAppearsOnlyWhenRelevant() {
        let idle = PrintAppearanceService.Stats()
        XCTAssertFalse(ActivitySnapshot.Halftone.isRelevant(enabled: false, stats: idle))
        XCTAssertTrue(ActivitySnapshot.Halftone.isRelevant(enabled: true, stats: idle))
        var used = idle
        used.processedPages = 1
        XCTAssertTrue(ActivitySnapshot.Halftone.isRelevant(enabled: false, stats: used))
        var passed = idle
        passed.passedThrough[.colour] = 2
        XCTAssertTrue(ActivitySnapshot.Halftone.isRelevant(enabled: false, stats: passed))
    }

    /// 行はサービスの値をそのまま映す: 状態・作業域・ページ・素通しの理由・待ち・時間・計画
    func testRowsMirrorTheServiceValues() {
        var stats = PrintAppearanceService.Stats()
        stats.engine = PrintAppearanceEngineStatus(path: .gpu, workingBytes: 0, gpuFallbackPages: 0,
                                                   compileMilliseconds: 210.4)
        stats.isRunning = true
        stats.processedPages = 12
        stats.unchangedPages = 3
        stats.passedThrough = [.colour: 2, .aspect: 1]
        stats.waitingDisplay = 1
        stats.waitingPrefetch = 3
        stats.preemptions = 4
        stats.shedJobs = 5
        stats.failedPages = 0
        stats.refusedPages = 1
        stats.lastWaitMilliseconds = 2
        stats.lastEngineMilliseconds = 40
        stats.lastPrepareMilliseconds = 11
        stats.medianWaitMilliseconds = 3
        stats.medianEngineMilliseconds = 45
        let section = halftone(level: .strong, stats: stats,
                               plan: .init(prefetchAhead: 12, prefetchBehind: 4, prefetchWidth: 4))
        let values = Dictionary(uniqueKeysWithValues: section.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(values[String(localized: "Setting")],
                       "📐 " + String(localized: "Like the printed book") + " · " + String(localized: "Strong"))
        XCTAssertEqual(values[String(localized: "Engine")], "● GPU · " + String(localized: "processing"))
        XCTAssertEqual(values[String(localized: "Working memory")], "● " + String(localized: "Released"))
        XCTAssertEqual(values[String(localized: "Pages processed")],
                       "● 12 · " + String(localized: "unchanged") + " 3")
        XCTAssertEqual(values[String(localized: "Passed through")],
                       "● " + String(localized: "Color") + " 2 · " + String(localized: "Aspect ratio") + " 1")
        XCTAssertEqual(values[String(localized: "Failed / refused")], "● 0 / 1")
        XCTAssertEqual(values[String(localized: "Waiting (display / prefetch)")], "● 1 / 3")
        XCTAssertEqual(values[String(localized: "Pre-emptions / shed")], "● 4 / 5")
        XCTAssertEqual(values[String(localized: "Last page (prepare · wait · engine)")], "● 11 · 2 · 40 ms")
        XCTAssertEqual(values[String(localized: "Median of recent pages")], "● — · 3 · 45 ms")
        XCTAssertEqual(values[String(localized: "Last compile")], "● 210 ms")
        XCTAssertEqual(values[String(localized: "Prefetch depth / width")], "📐 12 / 4")
        XCTAssertEqual(values[String(localized: "Threads (display / prefetch)")], "📐 8 / 4")
    }

    /// エンジンの状態の言い分け: 準備中・未起動・切・CPU だけ(理由つき)
    func testEngineStates() {
        var stats = PrintAppearanceService.Stats()
        XCTAssertEqual(halftone(stats: stats).engineText, String(localized: "Not started"))
        XCTAssertEqual(halftone(enabled: false, stats: stats).engineText, String(localized: "Off"))
        XCTAssertEqual(halftone(enabled: false, stats: stats).settingText, String(localized: "As scanned"))
        stats.isWarmingUp = true
        XCTAssertEqual(halftone(stats: stats).engineText, String(localized: "Preparing…"))
        stats.isWarmingUp = false
        stats.engine = PrintAppearanceEngineStatus(path: .cpuOnly(.repeatedGPUFailures), workingBytes: 1 << 20,
                                                   gpuFallbackPages: 2, compileMilliseconds: nil)
        XCTAssertEqual(halftone(stats: stats).engineText,
                       String(localized: "CPU only") + " (" + String(localized: "repeated GPU failures") + ")")
        XCTAssertEqual(halftone(stats: stats).passThroughText, "0")
    }

    /// 設定ペインの CPU だけの注記は、GPU を使えないときだけ(エンジンを作っていなければ出さない)
    @MainActor
    func testCPUOnlyCaptionOnlyWhenTheGPUCannotBeUsed() {
        func status(_ path: PrintAppearanceEngineStatus.Path) -> PrintAppearanceEngineStatus {
            PrintAppearanceEngineStatus(path: path, workingBytes: 0, gpuFallbackPages: 0, compileMilliseconds: nil)
        }
        XCTAssertNil(SettingsView.halftoneCPUOnlyCaption(engine: nil))
        XCTAssertNil(SettingsView.halftoneCPUOnlyCaption(engine: status(.gpu)))
        XCTAssertNil(SettingsView.halftoneCPUOnlyCaption(engine: status(.idle)))
        XCTAssertNil(SettingsView.halftoneCPUOnlyCaption(engine: status(.cpuOnly(.requested))))
        XCTAssertNotNil(SettingsView.halftoneCPUOnlyCaption(engine: status(.cpuOnly(.gpuUnavailable("x")))))
        XCTAssertNotNil(SettingsView.halftoneCPUOnlyCaption(engine: status(.cpuOnly(.repeatedGPUFailures))))
    }

    /// 統計の JSON は固定の英語のキーで、未計測は null、素通しは全理由を 0 から並べる
    func testStatsReportHasStableKeys() throws {
        var stats = PrintAppearanceService.Stats()
        stats.processedPages = 7
        stats.passedThrough = [.small: 1]
        stats.lastEngineMilliseconds = 33
        let data = PrintAppearanceStatsReport.json(halftone(stats: stats,
            plan: .init(prefetchAhead: 12, prefetchBehind: 4, prefetchWidth: 4)))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["setting", "engine", "pages", "queue", "milliseconds", "medianWindow", "plan"])
        let setting = try XCTUnwrap(root["setting"] as? [String: Any])
        XCTAssertEqual(setting["enabled"] as? Bool, true)
        XCTAssertEqual(setting["level"] as? String, "standard")
        XCTAssertEqual((root["engine"] as? [String: Any])?["path"] as? String, "notCreated")
        let pages = try XCTUnwrap(root["pages"] as? [String: Any])
        XCTAssertEqual(pages["processed"] as? Int, 7)
        let passed = try XCTUnwrap(pages["passedThrough"] as? [String: Int])
        XCTAssertEqual(passed.count, PrintAppearancePassReason.allCases.count)
        XCTAssertEqual(passed["small"], 1)
        XCTAssertEqual(passed["colour"], 0)
        let milliseconds = try XCTUnwrap(root["milliseconds"] as? [String: Any])
        XCTAssertEqual(milliseconds["lastEngine"] as? Double, 33)
        XCTAssertTrue(milliseconds["medianPage"] is NSNull)
        let plan = try XCTUnwrap(root["plan"] as? [String: Any])
        XCTAssertEqual(plan["prefetchWidth"] as? Int, 4)
        XCTAssertEqual(plan["displayThreads"] as? Int, 8)
        XCTAssertEqual(root["medianWindow"] as? Int, PrintAppearanceService.timingWindow)
        // 同じ入力なら同じバイト列(キーの並びが固定)
        XCTAssertEqual(data, PrintAppearanceStatsReport.json(halftone(stats: stats,
            plan: .init(prefetchAhead: 12, prefetchBehind: 4, prefetchWidth: 4))))
    }
}
