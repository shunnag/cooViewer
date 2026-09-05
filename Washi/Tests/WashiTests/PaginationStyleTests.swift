import AppKit
import WebKit
import XCTest
@testable import Washi

/// pagination CSS と書籍 CSS の cascade を実 WKWebView で検証する。
@MainActor
private final class PaginationStyleHarness {
    let window: NSWindow
    let webView: WKWebView
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler
    private let size: NSSize

    init(bodyHTML: String, size: NSSize = NSSize(width: 400, height: 400),
         headCSS: String = "") throws {
        self.size = size
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: bodyHTML)
        if !headCSS.isEmpty,
           let index = entries.firstIndex(where: { $0.name == "OEBPS/text/c.xhtml" }) {
            let source = String(decoding: entries[index].data, as: UTF8.self)
            entries[index].data = Data(source.replacingOccurrences(
                of: "</head>",
                with: "<style id=\"book-head-css\">\(headCSS)</style></head>").utf8)
        }
        publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-pagination-style.epub"))

        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                                size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        schemeHandler = EPUBSchemeHandler(publication: publication,
                                           allowsScripts: false)
        configuration.setURLSchemeHandler(
            schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        for source in [ReaderScripts.pageScript, ReaderScripts.baseCSSInjector] {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: EPUBReaderView.washiWorld))
        }
        webView = WKWebView(
            frame: NSRect(origin: .zero, size: size), configuration: configuration)
        window.contentView = webView
    }

    func load() async throws {
        let entry = try XCTUnwrap(publication.readingOrder.first)
        let url = try XCTUnwrap(schemeHandler.url(forReadingOrderItem: entry))
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        try await waiter.wait(timeout: .seconds(15))
        withExtendedLifetime(waiter) {}
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }

    func evaluate<T: Sendable>(
        _ body: String, as type: T.Type = T.self
    ) async throws -> T {
        try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                body, in: nil, contentWorld: EPUBReaderView.washiWorld)
            return try XCTUnwrap(result as? T)
        }.value
    }

    func setup(with settings: EPUBReaderSettings) async throws {
        _ = try await setupPageCount(with: settings)
    }

    func setupPageCount(with settings: EPUBReaderSettings) async throws -> Int {
        let options = EPUBScreenMetrics(
            viewportSize: size, settings: settings).censusOptionsJSON
        return try await evaluate(
            "return __washi.setup(\(options)).pageCount;")
    }

    func repaginate(with settings: EPUBReaderSettings) async throws {
        _ = try await repaginatedPageCount(with: settings)
    }

    func repaginatedPageCount(with settings: EPUBReaderSettings) async throws -> Int {
        let options = EPUBScreenMetrics(
            viewportSize: size, settings: settings).censusOptionsJSON
        return try await evaluate(
            "return __washi.repaginate(\(options)).pageCount;")
    }
}

@MainActor
final class PaginationStyleTests: XCTestCase {
    private func settings(
        fontScale: Double = 1,
        defaultFontFamily: String? = nil
    ) -> EPUBReaderSettings {
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        settings.columnMode = .single
        settings.fontScale = fontScale
        settings.defaultFontFamily = defaultFontFamily
        return settings
    }

    /// cooViewer-oxr.59: 高い画像の上限は figure 自体でなく子メディアに
    /// 適用し、figcaption と後続段落のレイアウト領域を重ねない。
    func testTallFigureCaptionDoesNotOverlapFollowingParagraph() async throws {
        let harness = try PaginationStyleHarness(bodyHTML: """
            <style>
              figure { margin: 0; }
              figure svg, figcaption, p { margin: 0; padding: 0; }
            </style>
            <figure id="figure">
              <svg xmlns="http://www.w3.org/2000/svg" width="300" height="1200"
                   viewBox="0 0 300 1200" style="display:block">
                <rect width="300" height="1200" fill="gray"/>
              </svg>
              <figcaption id="caption">図版の説明文</figcaption>
            </figure>
            <p id="after">図版の後に続く本文</p>
            """)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(with: settings())

        let result: [String: Double] = try await harness.evaluate("""
            const figure = document.getElementById('figure');
            const media = figure.querySelector('svg');
            const captions = Array.from(
                document.getElementById('caption').getClientRects());
            const paragraphs = Array.from(
                document.getElementById('after').getClientRects());
            const overlaps = captions.some(a => paragraphs.some(b =>
                a.left < b.right && a.right > b.left
                    && a.top < b.bottom && a.bottom > b.top));
            return {
                captionRects: captions.length,
                paragraphRects: paragraphs.length,
                overlaps: Number(overlaps),
                figureMaxHeightIsNone:
                    Number(getComputedStyle(figure).maxHeight === 'none'),
                mediaHeight: media.getBoundingClientRect().height,
                mediaFontSize: parseFloat(getComputedStyle(media).fontSize)
            };
            """)
        XCTAssertGreaterThan(result["captionRects"] ?? 0, 0)
        XCTAssertGreaterThan(result["paragraphRects"] ?? 0, 0)
        XCTAssertEqual(result["overlaps"], 0)
        XCTAssertEqual(result["figureMaxHeightIsNone"], 1)
        let captionRoom = 3 * (result["mediaFontSize"] ?? 0)
        XCTAssertLessThanOrEqual(result["mediaHeight"] ?? 400,
                                 400 - captionRoom + 0.5,
                                 "figcaption 分の高さを子メディアから差し引く")
    }

    /// cooViewer-oxr.60/76: 14pt と指定した書籍 root の計算済み px 値に
    /// 倍率を乗じ、固定 px の body も root 相対へ正規化する。
    func testFontScaleMultipliesBookAbsoluteRootFontSize() async throws {
        let harness = try PaginationStyleHarness(bodyHTML: """
            <style>html { font-size: 14pt; }</style>
            <p id="probe">絶対サイズの本文</p>
            """)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(with: settings(fontScale: 1.1))

        let sizes: [String: Double] = try await harness.evaluate("""
            return {
                root: parseFloat(getComputedStyle(document.documentElement).fontSize),
                body: parseFloat(getComputedStyle(document.body).fontSize)
            };
            """)
        let expected = 14.0 * 96.0 / 72.0 * 1.1
        XCTAssertEqual(sizes["root"] ?? 0, expected, accuracy: 0.25)
        XCTAssertEqual(sizes["body"] ?? 0, expected, accuracy: 0.25)
        XCTAssertGreaterThan(sizes["body"] ?? 0, 14.0 * 96.0 / 72.0)
    }

    /// cooViewer-oxr.60/76: px/pt で固定された body だけを root 相対へ
    /// 正規化し、倍率を本文まで届かせる。倍率 1.0 では著者値へ戻す。
    func testFontScaleNormalizesAbsoluteBodySizeOnlyWhileScaled() async throws {
        let harness = try PaginationStyleHarness(bodyHTML: """
            <style>
              html { font-size: 14pt; }
              body { font-size: 12pt; }
            </style>
            <p id="probe">絶対 body サイズの本文</p>
            """)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(with: settings(fontScale: 1.1))

        let scaled: Double = try await harness.evaluate(
            "return parseFloat(getComputedStyle(document.body).fontSize);")
        XCTAssertEqual(scaled, 14.0 * 96.0 / 72.0 * 1.1, accuracy: 0.25)

        try await harness.repaginate(with: settings(fontScale: 1.0))
        let restored: Double = try await harness.evaluate(
            "return parseFloat(getComputedStyle(document.body).fontSize);")
        XCTAssertEqual(restored, 12.0 * 96.0 / 72.0, accuracy: 0.25)
    }

    /// cooViewer-oxr.60/76: 同じ倍率で再ページ割りしても実 px 値へ倍率を
    /// 再乗算せず、1.0 へ戻せば著者 root 値へ正確に復帰する。
    func testFontScaleRepaginationIsIdempotentAndRestoresAuthorRootSize() async throws {
        let harness = try PaginationStyleHarness(bodyHTML: """
            <style>html { font-size: 14pt; }</style>
            <p>再ページ割りする本文</p>
            """)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(with: settings(fontScale: 1.1))
        try await harness.repaginate(with: settings(fontScale: 1.1))
        try await harness.repaginate(with: settings(fontScale: 1.1))

        let scaled: Double = try await harness.evaluate(
            "return parseFloat(getComputedStyle(document.documentElement).fontSize);")
        XCTAssertEqual(scaled, 14.0 * 96.0 / 72.0 * 1.1, accuracy: 0.25)

        try await harness.repaginate(with: settings(fontScale: 1.0))
        let restored: Double = try await harness.evaluate(
            "return parseFloat(getComputedStyle(document.documentElement).fontSize);")
        XCTAssertEqual(restored, 14.0 * 96.0 / 72.0, accuracy: 0.25)
    }

    /// cooViewer-oxr.60/76: 62.5% root + rem の書籍は WebKit 既定 16px で
    /// 置き換えず、書籍の 10px root を基準に連続的に拡大する。
    func testFontScalePreservesRemBasedBookSizing() async throws {
        let harness = try PaginationStyleHarness(bodyHTML: """
            <style>
              html { font-size: 62.5%; }
              body { font-size: 125%; }
              #probe { font-size: 1.6rem; }
              #em-probe { font-size: 1em; }
            </style>
            <p id="probe">rem 基準の本文</p>
            <p id="em-probe">body 相対の本文</p>
            """)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(with: settings(fontScale: 1.05))

        let sizes: [String: Double] = try await harness.evaluate("""
            return {
                root: parseFloat(getComputedStyle(document.documentElement).fontSize),
                body: parseFloat(getComputedStyle(document.body).fontSize),
                paragraph: parseFloat(
                    getComputedStyle(document.getElementById('probe')).fontSize),
                emParagraph: parseFloat(
                    getComputedStyle(document.getElementById('em-probe')).fontSize)
            };
            """)
        XCTAssertEqual(sizes["root"] ?? 0, 10.5, accuracy: 0.15)
        XCTAssertEqual(sizes["body"] ?? 0, 13.125, accuracy: 0.2)
        XCTAssertEqual(sizes["paragraph"] ?? 0, 16.8, accuracy: 0.2)
        XCTAssertEqual(sizes["emParagraph"] ?? 0, 13.125, accuracy: 0.2)
        XCTAssertLessThan(sizes["paragraph"] ?? 100, 20,
                          "1.05 倍で WebKit 既定 root の 1.68 倍へ跳ばない")
    }

    /// cooViewer-oxr.77: 書籍自身の html-level font-family は、既定
    /// フォントの後置注入に上書きされない。
    func testBookHTMLFontFamilyOverridesDefaultFontFamily() async throws {
        let harness = try PaginationStyleHarness(
            bodyHTML: "<p>書籍指定のフォント</p>",
            headCSS: """
                @layer book-root {
                  :where(html) { font-family: "Book Root Family", serif; }
                }
                """)
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(with: settings(
            defaultFontFamily: "Washi Reader Default"))

        let result: String = try await harness.evaluate("""
            const reader = document.getElementById('washi-default-font');
            const book = document.getElementById('book-head-css');
            const readerPrecedesBook = !!(reader.compareDocumentPosition(book)
                & Node.DOCUMENT_POSITION_FOLLOWING);
            return `${getComputedStyle(document.documentElement).fontFamily}`
                + `|${readerPrecedesBook}`;
            """)
        XCTAssertTrue(result.contains("Book Root Family"), result)
        XCTAssertFalse(result.contains("Washi Reader Default"), result)
        XCTAssertTrue(result.hasSuffix("|true"), result)
    }

    /// cooViewer-oxr.77: 書籍が font-family を指定しない場合は既定値を
    /// html から継承する。
    func testDefaultFontFamilyAppliesWhenBookOmitsFamily() async throws {
        let harness = try PaginationStyleHarness(
            bodyHTML: "<p>既定フォントの本文</p>")
        defer { harness.close() }
        try await harness.load()
        try await harness.setup(with: settings(
            defaultFontFamily: "Washi Reader Default"))

        let family: String = try await harness.evaluate(
            "return getComputedStyle(document.documentElement).fontFamily;")
        XCTAssertTrue(family.contains("Washi Reader Default"), family)
    }

    /// cooViewer-oxr.33: reader の近似行間を 2 倍にすると、長い横組み
    /// fixture の実測ページ数が増えることを検証する。
    func testLineHeightScaleRaisesLongFixturePageCount() async throws {
        let body = (1...90).map {
            "<p>段落 \($0) は、十分に長い本文を含みます。本文本文本文本文本文。</p>"
        }.joined()
        let harness = try PaginationStyleHarness(
            bodyHTML: body, size: NSSize(width: 320, height: 240))
        defer { harness.close() }
        try await harness.load()
        let normal = try await harness.setupPageCount(with: settings())
        var tall = settings()
        tall.lineHeightScale = 2
        let scaled = try await harness.repaginatedPageCount(with: tall)
        XCTAssertGreaterThan(scaled, normal,
                             "lineHeightScale=2 must add at least one page")
    }

    /// cooViewer-oxr.33: 字間は横組みのページ割りを変える一方、setup 時の
    /// 縦組み印によって縦組みでは無効になることを検証する。
    func testLetterSpacingDoesNotChangeVerticalWritingPagination() async throws {
        let text = String(repeating: "日本語の長い本文です。", count: 420)
        var spaced = settings()
        spaced.letterSpacingEm = 0.2

        let horizontal = try PaginationStyleHarness(
            bodyHTML: "<p>\(text)</p>",
            size: NSSize(width: 300, height: 240))
        defer { horizontal.close() }
        try await horizontal.load()
        let horizontalBase = try await horizontal.setupPageCount(with: settings())
        let horizontalSpaced = try await horizontal.repaginatedPageCount(with: spaced)
        XCTAssertNotEqual(horizontalSpaced, horizontalBase,
                          "horizontal letter spacing must affect pagination")

        let vertical = try PaginationStyleHarness(
            bodyHTML: "<p>\(text)</p>", size: NSSize(width: 300, height: 240),
            headCSS: "html { writing-mode: vertical-rl; }")
        defer { vertical.close() }
        try await vertical.load()
        let verticalBase = try await vertical.setupPageCount(with: settings())
        let verticalSpaced = try await vertical.repaginatedPageCount(with: spaced)
        let computedSpacing: String = try await vertical.evaluate(
            "return getComputedStyle(document.querySelector('p')).letterSpacing;")
        XCTAssertEqual(verticalSpaced, verticalBase)
        XCTAssertEqual(computedSpacing, "normal")
    }
}
