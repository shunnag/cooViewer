import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class ReaderViewDelegateSpy: EPUBReaderViewDelegate {
    var keys: [EPUBKeyEvent] = []
    var droppedURLs: [URL] = []
    var failures: [any Error] = []
    var censusUpdateCount = 0
    var moveCount = 0

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moveCount += 1
    }

    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {
        keys.append(event)
    }

    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool {
        droppedURLs.append(url)
        return true
    }

    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {
        failures.append(error)
    }

    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {
        censusUpdateCount += 1
    }
}

@MainActor
final class EPUBReaderViewRegressionTests: XCTestCase {
    private func makePublication() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-reader-regression.epub"))
    }

    private func makePublication(spread: RenditionSpread) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.reflowSpreadEntries(
                    renditionSpread: spread,
                    bodyHTML: "<p>\(String(repeating: "本文。", count: 200))</p>"),
                method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-reader-\(spread.rawValue).epub"))
    }

    private func makePublication(
        spread: RenditionSpread, itemProperties: String
    ) throws -> EPUBPublication {
        var entries = EPUBFixtures.reflowSpreadEntries(
            renditionSpread: spread,
            bodyHTML: "<p>\(String(repeating: "本文。", count: 200))</p>")
        let index = try XCTUnwrap(
            entries.firstIndex { $0.name == "OEBPS/package.opf" })
        let opf = String(decoding: entries[index].data, as: UTF8.self)
            .replacingOccurrences(
                of: #"<itemref idref="c"/>"#,
                with: #"<itemref idref="c" properties="\#(itemProperties)"/>"#)
        entries[index].data = Data(opf.utf8)
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-reader-item-spread.epub"))
    }

    private func makeSpreadTransitionPublication() throws -> EPUBPublication {
        var entries = EPUBFixtures.reflowSpreadEntries(
            renditionSpread: .both,
            bodyHTML: "<p>first</p>")
        let packageIndex = try XCTUnwrap(
            entries.firstIndex { $0.name == "OEBPS/package.opf" })
        let package = String(decoding: entries[packageIndex].data, as: UTF8.self)
            .replacingOccurrences(
                of: #"<manifest><item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/></manifest>"#,
                with: #"<manifest><item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="text/c2.xhtml" media-type="application/xhtml+xml"/></manifest>"#)
            .replacingOccurrences(
                of: #"<spine><itemref idref="c"/></spine>"#,
                with: #"<spine><itemref idref="c"/><itemref idref="c2" properties="rendition:spread-none"/></spine>"#)
        entries[packageIndex].data = Data(package.utf8)
        entries.append((
            "OEBPS/text/c2.xhtml",
            Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>second</body></html>".utf8)))
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-reader-spread-transition.epub"))
    }

    private func setupOptions(of view: EPUBReaderView) throws -> [String: Any] {
        let data = try XCTUnwrap(view.setupOptionsJSON().data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                                size: view.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        return window
    }

    private func close(_ window: NSWindow, view: EPUBReaderView) {
        view.cancelPageCensus()
        view.delegate = nil
        window.contentView = nil
        window.close()
    }

    /// cooViewer-oxr.27: Swift API の既定値と setup JSON の opt-in 配線を検証する。
    func testSetupOptionsPassesTapDeferralPreference() throws {
        var settings = EPUBReaderSettings()
        XCTAssertFalse(settings.defersTapsForDoubleClick)

        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.settings = settings
        var options = try setupOptions(of: view)
        XCTAssertEqual(options["deferTaps"] as? Bool, false)
        XCTAssertNil(options["doubleClickDelayMS"])

        settings.defersTapsForDoubleClick = true
        view.settings = settings
        options = try setupOptions(of: view)
        XCTAssertEqual(options["deferTaps"] as? Bool, true)
        XCTAssertGreaterThan(options["doubleClickDelayMS"] as? Double ?? 0, 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// spreadInsets 適用後の狭い実幅ではなく、基準余白の幅でライブ側も
    /// census と同じ見開き判定をする
    func testSetupSpreadMatchesScreenMetricsAcrossMismatchWindow() throws {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(
            top: 24, left: 56, bottom: 24, right: 56)
        settings.spreadInsets = EPUBReaderInsets(
            top: 24, left: 100, bottom: 24, right: 100)

        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 812, height: 900))
        view.settings = settings
        for width in [CGFloat(812), 850, 899] {
            view.frame.size.width = width
            let options = try setupOptions(of: view)
            let liveSpread = try XCTUnwrap(options["spread"] as? Bool)
            let metrics = EPUBScreenMetrics(
                viewportSize: view.bounds.size, settings: settings)
            XCTAssertEqual(liveSpread, metrics.pagesPerScreen == 2,
                           "viewport width: \(width)")
        }
    }

    func testSetupSpreadHonorsPublicationRenditionSpread() throws {
        let bothView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 900))
        bothView.load(publication: try makePublication(spread: .both))
        XCTAssertEqual(try setupOptions(of: bothView)["spread"] as? Bool, true)

        let noneView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        noneView.load(publication: try makePublication(spread: .none))
        XCTAssertEqual(try setupOptions(of: noneView)["spread"] as? Bool, false)
    }

    /// cooViewer-oxr.51: 文書既定が見開きでも、現在 itemref の override が
    /// ライブ setup を単ページへ切り替える。
    func testSetupSpreadHonorsCurrentItemOverride() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        view.load(publication: try makePublication(
            spread: .both, itemProperties: "rendition:spread-none"))

        XCTAssertEqual(try setupOptions(of: view)["spread"] as? Bool, false)
        XCTAssertEqual(view.plannedPagesPerScreen, 1)
    }

    /// cooViewer-oxr.51: 単ページ override の spine を直接開く場合、旧項目の
    /// 見開き余白を WebView の初期フレームへ残さない。
    func testSpineTransitionUpdatesFrameForItemSpreadInsets() throws {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(
            top: 20, left: 20, bottom: 20, right: 20)
        settings.spreadInsets = EPUBReaderInsets(
            top: 20, left: 100, bottom: 20, right: 100)
        let publication = try makeSpreadTransitionPublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        view.settings = settings

        view.load(
            publication: publication,
            at: EPUBLocator(spineIndex: 1, progression: 0, idref: "c2"))

        let webView = try XCTUnwrap(view.subviews.first { $0 is WKWebView })
        XCTAssertEqual(webView.frame.width, 1_160)
        XCTAssertEqual(try setupOptions(of: view)["spread"] as? Bool, false)
    }

    /// meta refresh などの .other は期待外なら reader 経由へ戻し、直前に
    /// 記録した loadSpineItem 自身の .other は一度だけ通す
    func testUnexpectedOtherNavigationRoutesWithoutConsumingExpectedLoad() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml")
        XCTAssertEqual(
            gate.disposition(
                for: "OEBPS/text/ch1.xhtml", navigationType: .linkActivated),
            .routeThroughReader)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch2.xhtml", navigationType: .other),
            .routeThroughReader)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .allowExpectedLoad)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .routeThroughReader)
    }

    /// 高速な spine 移動で decide が前後しても、自分が発行した各ロードを
    /// 文書内遷移と誤認しない
    func testCompetingExpectedSpineLoadsAreBothAllowed() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml")
        gate.expect("OEBPS/text/ch2.xhtml")
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .allowExpectedLoad)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch2.xhtml", navigationType: .other),
            .allowExpectedLoad)
    }

    /// JS へ復元先を適用した直後、最初の pageChanged より前に保存位置を
    /// 読んでも progression を失わない
    func testRestoreLocatorSurvivesSetupTargetApplication() throws {
        let publication = try makePublication()
        let locator = publication.locator(forSpineIndex: 1, progression: 0.625)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication, at: locator)

        view.applyPendingTargetAfterSetup()

        XCTAssertEqual(view.currentLocator.spineIndex, 1)
        XCTAssertEqual(view.currentLocator.progression, 0.625, accuracy: 0.0001)
    }

    /// cooViewer-oxr.19: 読み込み中の同一 spine go は旧 DOM へ送らず、
    /// 最後に指定された target を setup が消費する。
    func testSameSpineGoDuringLoadUsesNewestPendingTarget() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 1, progression: 0.2))

        view.go(to: publication.locator(
            forSpineIndex: 1, progression: 0.75))
        view.applyPendingTargetAfterSetup()

        XCTAssertEqual(view.currentLocator.spineIndex, 1)
        XCTAssertEqual(view.currentLocator.progression, 0.75, accuracy: 0.0001)
    }

    /// cooViewer-oxr.19: TOC と同一文書 href も読み込み中は共通の
    /// pendingTarget 経路を通る。
    func testSameSpineTOCAndContainerNavigationQueueDuringLoad() throws {
        let publication = try makePublication()
        let tocView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        tocView.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 0, progression: 0.6))
        tocView.go(to: try XCTUnwrap(publication.navigation.toc.first))
        XCTAssertEqual(tocView.currentLocator.progression, 0, accuracy: 0.0001)

        let hrefView = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        hrefView.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 0, progression: 0.6))
        hrefView.goToContainerPath(
            publication.readingOrder[0].resolvedContainerPath, fragment: nil)
        XCTAssertEqual(hrefView.currentLocator.progression, 0, accuracy: 0.0001)
    }

    /// cooViewer-oxr.23: .end を適用して pageChanged が届く前も、保存位置を
    /// 章頭の 0 に潰さない。
    func testCurrentLocatorKeepsEndTargetBeforePageChanged() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        view.goToBookEnd()

        view.applyPendingTargetAfterSetup()

        XCTAssertEqual(view.currentLocator.spineIndex,
                       publication.readingOrder.count - 1)
        XCTAssertEqual(view.currentLocator.progression, 1, accuracy: 0.0001)
    }

    /// cooViewer-oxr.19/23: 旧文書の遅配 pageChanged は読み込み先の
    /// pending locator を消さず、ホストへも移動通知しない。
    func testPageChangedFromOldDocumentIsIgnoredDuringLoad() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        view.load(
            publication: publication,
            at: publication.locator(forSpineIndex: 1, progression: 0.75))

        view.handleScriptMessage([
            "type": "pageChanged", "page": 5, "pageCount": 10,
            "pagesPerScreen": 1,
        ])

        XCTAssertEqual(view.pageInItem, 0)
        XCTAssertEqual(view.currentLocator.progression, 0.75, accuracy: 0.0001)
        XCTAssertEqual(delegate.moveCount, 0)
    }

    /// cooViewer-oxr.20: 画像ページの実測 1 面ではなく、画面計画 2 面を
    /// 基準に columnMode を反転する。
    func testToggleColumnModeUsesPlannedPagesForImageItem() throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.imagePageEntries(
                    bodyHTML: "<img src=\"../images/page.png\"/>") ,
                method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-toggle-image.epub"))
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        var settings = view.settings
        settings.columnMode = .double
        view.settings = settings
        view.load(publication: publication)

        XCTAssertEqual(view.pagesPerScreen, 1)
        XCTAssertEqual(view.plannedPagesPerScreen, 2)
        view.toggleColumnMode()
        XCTAssertEqual(view.settings.columnMode, .single)
        view.toggleColumnMode()
        XCTAssertEqual(view.settings.columnMode, .double)
    }

    /// cooViewer-t4e: ホストが足したオーバーレイは load による webView
    /// 再構築後も webView より前面に残る
    func testHostOverlayRemainsAboveWebViewAcrossReload() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)

        let overlay = NSView(frame: view.bounds)
        view.addSubview(overlay)
        view.load(publication: publication)

        let rebuiltWebView = try XCTUnwrap(
            view.subviews.firstIndex(where: { $0 is WKWebView }))
        let overlayIndex = try XCTUnwrap(view.subviews.firstIndex(of: overlay))
        XCTAssertLessThan(rebuiltWebView, overlayIndex)
    }

    /// 0 始まりの census ページと locator の相互変換は全ページで可逆になる
    func testCensusGlobalPageRoundTripsEveryPage() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        let counts = [1, 4, 3]
        let metricsKey = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings).censusOptionsJSON
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: metricsKey, counts: counts,
            releaseIdentifier: publication.metadata.releaseIdentifier)))

        for page in 0..<counts.reduce(0, +) {
            let locator = try XCTUnwrap(view.censusLocator(forGlobalPage: page))
            XCTAssertEqual(view.censusGlobalPage(for: locator), page,
                           "0 始まり page=\(page)")
        }
    }

    /// cooViewer-oxr.73: 公開 locator setter に入った巨大値を、trap する
    /// Double → Int 変換まで到達させない。
    func testCensusGlobalPageClampsHostileLocatorProgression() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        let metricsKey = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings).censusOptionsJSON
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: metricsKey, counts: [4, 3, 2],
            releaseIdentifier: publication.metadata.releaseIdentifier)))

        var hostile = EPUBLocator(spineIndex: 0)
        hostile.progression = 1e300
        XCTAssertEqual(view.censusGlobalPage(for: hostile), 3)
    }

    /// cooViewer-oxr.21: A 成功→B 二回失敗→A cache hit→B skip でも、
    /// B 表示中に A の総ページ数を残さない。
    func testSkippedCensusKeyInvalidatesCachedDisplayCounts() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        view.cancelPageCensus()

        let keyA = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings,
            renditionSpread: publication.metadata.rendition.spread).cacheKey
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: keyA, counts: [2, 3, 1],
            releaseIdentifier: publication.metadata.releaseIdentifier)))

        var settingsB = view.settings
        settingsB.userCSS = "body { line-height: 3; }"
        let keyB = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: settingsB,
            renditionSpread: publication.metadata.rendition.spread).cacheKey
        view.recordCensusFailure(forKey: keyB)
        view.recordCensusFailure(forKey: keyB)

        view.settings = settingsB
        view.scheduleCensusIfNeeded()
        XCTAssertNil(view.censusTotalPages)

        var settingsA = settingsB
        settingsA.userCSS = nil
        view.settings = settingsA
        view.scheduleCensusIfNeeded()
        XCTAssertEqual(view.censusTotalPages, 6)

        view.settings = settingsB
        view.scheduleCensusIfNeeded()
        XCTAssertNil(view.censusTotalPages)
        XCTAssertGreaterThanOrEqual(delegate.censusUpdateCount, 4)
    }

    /// cooViewer-oxr.72: stale spineIndex より idref を優先し、通常 go と
    /// census の逆写像が同じ spine を使う。
    func testGoAndCensusGlobalPageResolveLocatorIDRef() throws {
        let publication = try makePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication)
        let metricsKey = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings,
            renditionSpread: publication.metadata.rendition.spread).cacheKey
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: metricsKey, counts: [2, 3, 1],
            releaseIdentifier: publication.metadata.releaseIdentifier)))
        let stale = EPUBLocator(
            spineIndex: 0, progression: 0.5,
            idref: publication.readingOrder[1].itemRef.idref)

        XCTAssertEqual(view.censusGlobalPage(for: stale), 3)
        view.go(to: stale)
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertEqual(view.currentLocator.progression, 0.5, accuracy: 0.0001)
    }

    /// importCensus の照合キーが著者指定を反映した画面計画と決定的に一致する
    func testImportedCensusUsesRenditionSpreadMetricsKey() throws {
        let publication = try makePublication(spread: .both)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 900))
        view.load(publication: publication)
        let base = EPUBScreenMetrics(
            viewportSize: view.bounds.size, settings: view.settings)
        let openKey = base.applyingRenditionSpread(.both).cacheKey
        XCTAssertNotEqual(openKey, base.cacheKey)
        XCTAssertTrue(view.importCensus(EPUBCensusRecord(
            metricsKey: openKey, counts: [7],
            releaseIdentifier: publication.metadata.releaseIdentifier)))
        XCTAssertEqual(view.pageCensusMetricsKey, openKey)
    }

    /// cooViewer-oxr.24: userCSS は色だけの差し替えでなく導出レイアウトキーを
    /// 変え、現在 spine の pageCount を再計測する。
    func testUserCSSChangeRepaginatesCurrentItem() async throws {
        let body = (1...36).map { "<p>段落 \($0) 本文本文本文本文本文</p>" }
            .joined()
        let publication = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.singleSpineEntries(bodyHTML: body), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-user-css-layout.epub"))
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = view.settings
        settings.columnMode = .single
        view.settings = settings
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)

        let didFinishInitialSetup = await waitUntil { delegate.moveCount > 0 }
        guard didFinishInitialSetup else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }
        let originalCount = view.pageCountInItem
        var updated = view.settings
        updated.userCSS = """
            p { break-before: column !important;
                -webkit-column-break-before: always !important; }
            """
        view.settings = updated

        let didRepaginate = await waitUntil { view.pageCountInItem > originalCount }
        XCTAssertTrue(didRepaginate)
    }

    /// cooViewer-oxr.24: setup 後に handlesKeyboardNavigation を false へ
    /// 切り替えた文書は、次の keydown を delegate へ送る。
    func testKeyboardSettingChangeUpdatesLoadedScript() async throws {
        let publication = try makePublication(spread: .none)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        let didFinishInitialSetup = await waitUntil { delegate.moveCount > 0 }
        guard didFinishInitialSetup else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }

        var updated = view.settings
        updated.handlesKeyboardNavigation = false
        view.settings = updated
        let webView = try XCTUnwrap(view.subviews.first { $0 is WKWebView } as? WKWebView)
        let dispatched = try await Task(priority: .userInitiated) { @MainActor in
            let result = try await webView.callAsyncJavaScript(
                """
                document.dispatchEvent(new KeyboardEvent('keydown', {
                    key:'x', code:'KeyX', bubbles:true
                }));
                return true;
                """,
                in: nil, contentWorld: EPUBReaderView.washiWorld)
            return result as? Bool ?? false
        }.value
        XCTAssertTrue(dispatched)

        let didForward = await waitUntil { delegate.keys.count == 1 }
        XCTAssertTrue(didForward)
        XCTAssertEqual(delegate.keys.first?.key, "x")
    }

    /// cooViewer-oxr.48: JS setup の機能検出結果を公開プロパティへ写し、
    /// 縦見開きの単ページ fallback を保持する。
    func testSetupResultPublishesUnsupportedColumnAxisFallback() {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 900))
        var settings = view.settings
        settings.columnMode = .double
        view.settings = settings

        view.applySetupResult([
            "pageCount": 8,
            "pagesPerScreen": 1,
            "imagePage": false,
            "mode": "vrl",
            "supportsColumnAxis": false,
        ])

        XCTAssertFalse(view.columnAxisSupported)
        XCTAssertEqual(view.pagesPerScreen, 1)
    }

    /// cooViewer-oxr.54: hidden view の frame 変更は census を起動せず、
    /// unhide で一度だけ延期レイアウトを消費する。
    func testHiddenLayoutDefersCensusUntilUnhide() throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.fxlComicEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-hidden-layout.epub"))
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        view.cancelPageCensus()

        view.isHidden = true
        view.frame.size.width = 1_000
        view.layout()
        XCTAssertTrue(view.hasDeferredVisibleLayout)
        XCTAssertFalse(view.isPageCensusScheduled)

        view.isHidden = false
        XCTAssertFalse(view.hasDeferredVisibleLayout)
        XCTAssertTrue(view.isPageCensusScheduled)
    }

    /// cooViewer-oxr.54: 表示中に予約済みの再ページ割りも、hide 後に
    /// 起床して不可視 WebView を更新しない。
    func testHideCancelsAlreadyScheduledRepagination() async throws {
        let publication = try makePublication(spread: .none)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        guard await waitUntil({ delegate.moveCount > 0 }) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }

        var updated = view.settings
        updated.userCSS = "body { line-height: 1.8; }"
        view.settings = updated
        XCTAssertTrue(view.isRepaginationScheduled)

        view.isHidden = true
        XCTAssertFalse(view.isRepaginationScheduled)
        XCTAssertTrue(view.hasDeferredVisibleLayout)
    }

    /// cooViewer-oxr.80: コンテナ自身が keyDown を受けても、host 優先設定なら
    /// DOM 往復なしで didReceiveKey へ配送する。
    func testReaderViewKeyDownForwardsWhenKeyboardNavigationDisabled() throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        var settings = view.settings
        settings.handlesKeyboardNavigation = false
        view.settings = settings
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 1, windowNumber: 0, context: nil,
            characters: "X", charactersIgnoringModifiers: "x",
            isARepeat: false, keyCode: 7))

        view.keyDown(with: event)

        XCTAssertEqual(delegate.keys.count, 1)
        XCTAssertEqual(delegate.keys.first?.key, "x")
        XCTAssertEqual(delegate.keys.first?.shift, true)
    }

    /// cooViewer-oxr.84: URL pasteboard が http URL を返しても、ファイル drop の
    /// delegate 契約へは流さない。
    func testDroppedHTTPURLIsRejectedBeforeDelegateDispatch() throws {
        let view = EPUBReaderView(frame: .zero)
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(
            "org.cocoadialog.WashiTests.drop.\(UUID().uuidString)"))
        pasteboard.declareTypes([.URL], owner: nil)
        let remoteURL = try XCTUnwrap(
            URL(string: "https://example.invalid/book.epub"))
        let wroteURL = pasteboard.setString(remoteURL.absoluteString, forType: .URL)

        if wroteURL {
            XCTAssertFalse(view.dispatchDroppedURL(from: pasteboard))
        } else {
            // cooViewer-oxr.84: sandbox で pasteboard service が使えない場合も
            // URL gate 自体は検証する。
            XCTAssertFalse(view.dispatchDroppedURL(remoteURL))
        }
        XCTAssertTrue(delegate.droppedURLs.isEmpty)
        XCTAssertTrue(view.dispatchDroppedURL(
            URL(fileURLWithPath: "/tmp/local.epub")))
        XCTAssertEqual(delegate.droppedURLs,
                       [URL(fileURLWithPath: "/tmp/local.epub")])
    }

    /// cooViewer-oxr.47: 三回の再試行は 0/250ms/1s と増加し、同じ 60 秒窓の
    /// 四回目以降は一度だけ失敗通知を要求する。
    func testWebContentReloadLimiterCapsAndBacksOff() {
        var limiter = WebContentReloadLimiter()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .reload(after: .zero))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .reload(after: .milliseconds(250)))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .reload(after: .seconds(1)))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .suppress(reportFailure: true))
        XCTAssertEqual(limiter.register(spineIndex: 2, at: now),
                       .suppress(reportFailure: false))
        XCTAssertEqual(
            limiter.register(spineIndex: 2, at: now.addingTimeInterval(61)),
            .reload(after: .zero))
    }

    /// cooViewer-oxr.47: windowless 中の終了は reload せず同じ要求を延期し、
    /// 短時間四回目で打ち切って delegate へ一度だけ失敗を返す。
    func testWebContentTerminationDefersWhenWindowlessAndCapsReloads() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = ReaderViewDelegateSpy()
        view.delegate = delegate
        view.load(publication: try makePublication())
        let webView = try XCTUnwrap(view.subviews.first { $0 is WKWebView } as? WKWebView)

        for _ in 0..<4 {
            view.webViewWebContentProcessDidTerminate(webView)
        }

        XCTAssertEqual(view.webContentReloadRequestCount, 3)
        XCTAssertEqual(view.webContentReloadAttemptCount, 0)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertTrue(String(describing: delegate.failures[0]).contains(
            "web content process terminated repeatedly"))
    }

    /// cooViewer-oxr.47: windowless で受理した一回の終了は、attach 時に新しい
    /// termination として数え直さず一度だけ reload する。
    func testDeferredWebContentReloadRunsOnceAfterAttach() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.load(publication: try makePublication())
        let webView = try XCTUnwrap(view.subviews.first { $0 is WKWebView } as? WKWebView)
        view.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(view.webContentReloadAttemptCount, 0)

        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        XCTAssertEqual(view.webContentReloadRequestCount, 1)
        XCTAssertEqual(view.webContentReloadAttemptCount, 1)
    }

    /// cooViewer-oxr.47: spine A で予約したバックオフ reload は、B へ
    /// 移動した後に発火して現在文書を再構築しない。
    func testSpineNavigationCancelsDelayedWebContentReload() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        let publication = try makePublication()
        view.load(publication: publication)
        let now = Date(timeIntervalSinceReferenceDate: 4_000)
        view.handleWebContentProcessTermination(at: now)
        view.handleWebContentProcessTermination(at: now)
        XCTAssertTrue(view.hasPendingWebContentReload)

        view.goToBookEnd()

        XCTAssertEqual(view.currentSpineIndex,
                       publication.readingOrder.count - 1)
        XCTAssertFalse(view.hasPendingWebContentReload)
    }

    /// cooViewer-oxr.47: 再構築前の WebView からの遅配終了通知は、現在の
    /// spine の再試行回数へ数えない。
    func testStaleWebContentTerminationDoesNotConsumeReloadBudget() throws {
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.load(publication: try makePublication())
        let stale = WKWebView(frame: .zero)

        view.webViewWebContentProcessDidTerminate(stale)

        XCTAssertEqual(view.webContentReloadRequestCount, 0)
        XCTAssertEqual(view.webContentReloadAttemptCount, 0)
    }
}
