import CoreGraphics
import Washi
import XCTest

@testable import cooViewer

/// コレクション(合本)内リフロー EPUB の代理ページまわり(cooViewer-4gc)。
/// - 代理ページは見開きに混ぜない(素通り・再入場防止の要)
/// - 代理ソースは表紙(なければタイトルカード)1 ページを供給する
/// - 版面余白プリセットの写像
@MainActor
final class EPUBCollectionTests: XCTestCase {
    /// reflowEPUBURL を任意のページに立てられるスタブ
    private final class PlaceholderStubSource: BookSource, @unchecked Sendable {
        let url = URL(fileURLWithPath: "/stub/collection")
        let count: Int
        let placeholderIndices: Set<Int>
        var supportsDateSort: Bool { false }

        init(count: Int, placeholderIndices: Set<Int>) {
            self.count = count
            self.placeholderIndices = placeholderIndices
        }

        func entries() async throws -> [PageEntry] {
            (0..<count).map { index in
                PageEntry(
                    id: index, name: "p\(index)", pathInBook: "p\(index)",
                    fileURL: nil, creationDate: nil, modificationDate: nil,
                    reflowEPUBURL: placeholderIndices.contains(index)
                        ? URL(fileURLWithPath: "/stub/book\(index).epub") : nil)
            }
        }

        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            // 縦長(見開き候補になる寸法)
            try ImageDecoding.decode(
                TestFixtures.pngData(width: 70, height: 100),
                maxPixelSize: maxPixelSize)
        }
    }

    func testPlaceholderNeverPairsIntoSpread() async throws {
        // 縦長 3 ページ(通常なら 0+1 が見開き)。1 が代理ページなら常に単独
        let source = PlaceholderStubSource(count: 3, placeholderIndices: [1])
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSpread
        let first = await book.currentSpread()
        XCTAssertEqual(first.indices, [0], "代理ページは隣とペアにしない")
        book.goTo(index: 1)
        let second = await book.currentSpread()
        XCTAssertEqual(second.indices, [1], "代理ページ自体も単独表示")

        // 対照: 代理ページがなければ 0+1 が見開きになる
        let paired = try await Book.open(
            source: PlaceholderStubSource(count: 3, placeholderIndices: []))
        paired.readMode = .rightToLeftSpread
        let spread = await paired.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1])
    }

    func testReflowPlaceholderSourceSuppliesCoverEntry() async throws {
        // 展開済みフォルダ形式の最小リフロー EPUB(Washi は両形式を開ける)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("placeholder-\(UUID().uuidString).epub")
        let fm = FileManager.default
        try fm.createDirectory(
            at: root.appendingPathComponent("META-INF"),
            withIntermediateDirectories: true)
        try fm.createDirectory(
            at: root.appendingPathComponent("OEBPS"),
            withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "application/epub+zip".write(
            to: root.appendingPathComponent("mimetype"),
            atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.write(to: root.appendingPathComponent("META-INF/container.xml"),
                  atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">test-placeholder</dc:identifier>
            <dc:title>代理ページの本</dc:title>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-08-20T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """.write(to: root.appendingPathComponent("OEBPS/package.opf"),
                  atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>1</title></head>
        <body><p>本文</p></body></html>
        """.write(to: root.appendingPathComponent("OEBPS/ch1.xhtml"),
                  atomically: true, encoding: .utf8)

        let source = try ReflowEPUBPlaceholderSource(url: root)
        let entries = try await source.entries()
        XCTAssertEqual(entries.count, 1, "代理ページは 1 ページだけ")
        XCTAssertEqual(entries[0].reflowEPUBURL, root)
        // 表紙が無い本 → タイトルカードが合成される
        let image = try await source.image(for: entries[0], maxPixelSize: nil)
        XCTAssertGreaterThan(image.width, 0)
    }

    func testThumbnailScreensMatchCensusPagination() {
        // 見開き(2 ページ/画面): 表紙 1 ページ + 5 ページ章 + 3 ページ章。
        // ラベルは全文ページ番号、奇数章は端数画面で終わる
        let screens = EPUBScreenThumbnailSource.makeScreens(
            counts: [1, 5, 3], pagesPerScreen: 2)
        XCTAssertEqual(screens.map(\.label),
                       ["1", "2-3", "4-5", "6", "7-8", "9"])
        XCTAssertEqual(screens.map(\.spineIndex), [0, 1, 1, 1, 2, 2])
        XCTAssertEqual(screens.map(\.pageInItem), [0, 0, 2, 4, 0, 2])
        // 単ページ: 1 画面 = 1 ページ
        let single = EPUBScreenThumbnailSource.makeScreens(
            counts: [1, 3], pagesPerScreen: 1)
        XCTAssertEqual(single.map(\.label), ["1", "2", "3", "4"])
    }

    func testCollectionPlanExpandsPlaceholders() {
        func entry(_ id: Int, _ name: String, epub: String? = nil) -> PageEntry {
            PageEntry(id: id, name: name, pathInBook: name, fileURL: nil,
                      creationDate: nil, modificationDate: nil,
                      reflowEPUBURL: epub.map { URL(fileURLWithPath: $0) })
        }
        let url = URL(fileURLWithPath: "/x/b.epub")
        let entries = [entry(0, "01.png"),
                       entry(1, "b.epub", epub: "/x/b.epub"),
                       entry(2, "z.png")]
        // 幅 1400 - 余白 112 = 1288 ≥ 700 → 見開き(2 ページ/画面)
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 1400, height: 900),
            settings: EPUBReaderSettings())
        XCTAssertEqual(metrics.pagesPerScreen, 2)
        let plan = CollectionThumbnailPlan.make(
            bookEntries: entries, counts: [1: [1, 3]],
            metrics: metrics, isDark: false)
        // 01.png / (表紙 1 + 2-3 + 4) / z.png = 5 セル
        XCTAssertEqual(plan.entries.map { $0.name },
                       ["01.png", "1", "2-3", "4", "z.png"])
        XCTAssertEqual(plan.targets[0],
                       CollectionThumbnailPlan.Target.bookPage(index: 0))
        XCTAssertEqual(plan.targets[1], CollectionThumbnailPlan.Target.epubScreen(
            url: url, entryIndex: 1, spineIndex: 0,
            pageInItem: 0, countInItem: 1))
        XCTAssertEqual(plan.targets[4],
                       CollectionThumbnailPlan.Target.bookPage(index: 2))
        // 実ページ→セル(展開 EPUB は先頭セル)、EPUB 内位置→セル
        XCTAssertEqual(plan.overlayIndex(forBookPage: 2), 4)
        XCTAssertEqual(plan.overlayIndex(forBookPage: 1), 1)
        XCTAssertEqual(plan.overlayIndex(forEPUB: url,
                                         spineIndex: 1, pageInItem: 2), 3)
        XCTAssertEqual(plan.overlayIndex(forEPUB: url,
                                         spineIndex: 1, pageInItem: 0), 2)
        // census が無い代理ページ(失敗・DRM)は従来どおり 1 セルのまま
        let fallback = CollectionThumbnailPlan.make(
            bookEntries: entries, counts: [:], metrics: metrics, isDark: false)
        XCTAssertEqual(fallback.entries.count, 3)
        XCTAssertEqual(fallback.targets[1],
                       CollectionThumbnailPlan.Target.bookPage(index: 1))
    }

    func testCollectionPageMapGlobalNumbering() {
        func entry(_ id: Int, _ name: String, epub: String? = nil) -> PageEntry {
            PageEntry(id: id, name: name, pathInBook: name, fileURL: nil,
                      creationDate: nil, modificationDate: nil,
                      reflowEPUBURL: epub.map { URL(fileURLWithPath: $0) })
        }
        let url = URL(fileURLWithPath: "/x/b.epub")
        let entries = [entry(0, "01.png"),
                       entry(1, "b.epub", epub: "/x/b.epub"),
                       entry(2, "z.png"),
                       entry(3, "drm.epub", epub: "/x/drm.epub")]
        // b.epub = 表紙 1 + 本文 4 ページ。drm.epub は census 無し → 1 ページ
        let map = CollectionPageMap.make(
            folderPath: "/f", metricsKey: "k",
            entries: entries, counts: [1: [1, 4]])
        // 01.png=1 / b.epub=2..6 / z.png=7 / drm=8 → 全 8 ページ
        XCTAssertEqual(map.total, 8)
        XCTAssertEqual(map.globalStart(forEntry: 0), 0)
        XCTAssertEqual(map.globalStart(forEntry: 1), 1)
        XCTAssertEqual(map.globalStart(forEntry: 2), 6)
        XCTAssertEqual(map.globalStart(forEntry: 3), 7)
        XCTAssertEqual(map.pageCount(forEntry: 1), 5)
        // 全体ページ → ジャンプ先
        XCTAssertEqual(map.target(forGlobalPage: 0),
                       CollectionPageMap.Target.bookPage(index: 0))
        XCTAssertEqual(map.target(forGlobalPage: 1),
                       CollectionPageMap.Target.epubPage(
                           url: url, entryIndex: 1, spineIndex: 0,
                           pageInItem: 0, countInItem: 1))
        XCTAssertEqual(map.target(forGlobalPage: 3),
                       CollectionPageMap.Target.epubPage(
                           url: url, entryIndex: 1, spineIndex: 1,
                           pageInItem: 1, countInItem: 4))
        XCTAssertEqual(map.target(forGlobalPage: 6),
                       CollectionPageMap.Target.bookPage(index: 2))
        XCTAssertEqual(map.target(forGlobalPage: 7),
                       CollectionPageMap.Target.bookPage(index: 3))
        // 範囲外はクランプ
        XCTAssertEqual(map.target(forGlobalPage: 99),
                       CollectionPageMap.Target.bookPage(index: 3))
    }

    func testEPUBMarginPresetsAreOrdered() {
        let narrow = ReaderWindowController.epubInsets(forMargins: 0)
        let standard = ReaderWindowController.epubInsets(forMargins: 1)
        let wide = ReaderWindowController.epubInsets(forMargins: 2)
        XCTAssertLessThan(narrow.left, standard.left)
        XCTAssertLessThan(standard.left, wide.left)
        // ノンブルの居場所(下辺)は最小でも確保する
        XCTAssertGreaterThanOrEqual(narrow.bottom, 24)
    }
}
