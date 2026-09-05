import AppKit
import WebKit
import XCTest
@testable import Washi
@testable import WashiCore

@MainActor
final class EPUBPaginationCensusTests: XCTestCase {
    /// cooViewer-oxr.68: 完了から 20 秒相当で WebKit を解放し、同じ census の
    /// 次回計測で遅延再構築して同じ結果を返す。
    func testIdleReleaseTearsDownWebViewAndNextMeasureRebuilds() async throws {
        let publication = try makeReflowPublication()
        let scheduler = ManualOffscreenIdleScheduler()
        let census = EPUBPaginationCensus(
            idleTimerScheduler: scheduler.scheduler)
        defer { census.invalidate() }
        let metrics = makeMetrics()

        guard let first = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }

        XCTAssertTrue(census.hasLiveWebView)
        let idle = try XCTUnwrap(scheduler.lastActiveEntry)
        XCTAssertEqual(idle.delay, EPUBOffscreenIdleReleaseTimer.defaultInterval)

        scheduler.fire(idle)
        XCTAssertFalse(census.hasLiveWebView)

        let rebuilt = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)
        XCTAssertEqual(rebuilt, Optional(first))
        XCTAssertTrue(census.hasLiveWebView)
    }

    /// cooViewer-oxr.68: 新しい計測が始めた時点で旧 idle callback を失効させ、
    /// callback が競合して到着しても進行中の WebKit を畳まない。
    func testStaleIdleTimerDoesNotInterruptInFlightMeasure() async throws {
        let publication = try makeReflowPublication()
        let scheduler = ManualOffscreenIdleScheduler()
        let census = EPUBPaginationCensus(
            idleTimerScheduler: scheduler.scheduler)
        defer { census.invalidate() }
        let metrics = makeMetrics()
        guard let first = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }
        let staleIdle = try XCTUnwrap(scheduler.lastActiveEntry)

        let inFlight = Task { @MainActor in
            await census.measure(
                publication: publication,
                optionsJSON: metrics.censusOptionsJSON,
                contentSize: metrics.contentSize)
        }
        for _ in 0..<100 {
            if staleIdle.isCancelled { break }
            await Task.yield()
        }
        XCTAssertTrue(staleIdle.isCancelled)

        scheduler.fire(staleIdle, includingCancelled: true)
        XCTAssertTrue(census.hasLiveWebView)
        let inFlightResult = await inFlight.value
        XCTAssertEqual(inFlightResult, Optional(first))
    }

    /// cooViewer-oxr.22: spine 内の欠損 XHTML は 1 ページへ縮退し、
    /// 後続の正常項目まで含む census を完成させる。
    func testMissingSpineResourceCountsAsOneAndCensusContinues() async throws {
        let publication = try makePublicationWithMissingSpineResource()
        let census = EPUBPaginationCensus()
        defer { census.invalidate() }
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600), settings: settings)

        let counts = await census.measure(
            publication: publication, optionsJSON: metrics.censusOptionsJSON,
            contentSize: metrics.contentSize)

        XCTAssertEqual(counts, [1, 1])
    }

    /// cooViewer-oxr.22/53: caller cancellation は部分結果へ縮退せず nil を返す。
    func testCancellationReturnsNil() async throws {
        let publication = try makePublicationWithMissingSpineResource()
        let census = EPUBPaginationCensus()
        defer { census.invalidate() }
        let metrics = EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600),
            settings: EPUBReaderSettings())
        let task = Task { @MainActor in
            await census.measure(
                publication: publication,
                optionsJSON: metrics.censusOptionsJSON,
                contentSize: metrics.contentSize)
        }
        task.cancel()

        let counts = await task.value
        XCTAssertNil(counts)
    }

    /// cooViewer-oxr.22/53: WebKit の load 中断・プロセス終了は壊れた項目の
    /// 1 ページ縮退ではなく、census 全体を中断する一過性エラーとして扱う。
    func testTransientWebKitFailuresAbortMeasurement() {
        XCTAssertTrue(EPUBPaginationCensus.mustAbortMeasurement(for: NSError(
            domain: "WebKitErrorDomain", code: 102)))
        XCTAssertTrue(EPUBPaginationCensus.mustAbortMeasurement(for: NSError(
            domain: WKError.errorDomain,
            code: WKError.Code.webContentProcessTerminated.rawValue)))
        XCTAssertFalse(EPUBPaginationCensus.mustAbortMeasurement(for: URLError(
            .fileDoesNotExist)))
    }

    private func makePublicationWithMissingSpineResource() throws
        -> EPUBPublication {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:census-missing</dc:identifier>
                <dc:title>Census missing item</dc:title>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="missing" href="text/missing.xhtml"
                      media-type="application/xhtml+xml"/>
                <item id="present" href="text/present.xhtml"
                      media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="missing"/>
                <itemref idref="present"
                         properties="rendition:layout-pre-paginated"/>
              </spine>
            </package>
            """
        let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Present</title></head>
              <body><p>Present spine item.</p></body>
            </html>
            """
        let entries: [(name: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(EPUBFixtures.containerXML.utf8)),
            ("OEBPS/package.opf", Data(opf.utf8)),
            ("OEBPS/text/present.xhtml", Data(xhtml.utf8)),
        ]
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-census-missing.epub"))
    }

    private func makeReflowPublication() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.reflowSpreadEntries(
                    renditionSpread: .none,
                    bodyHTML: "<p>Idle census lifecycle fixture.</p>"),
                method: 8),
            displayURL: URL(
                fileURLWithPath: "/tmp/washi-census-idle-release.epub"))
    }

    private func makeMetrics() -> EPUBScreenMetrics {
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        return EPUBScreenMetrics(
            viewportSize: CGSize(width: 420, height: 600), settings: settings)
    }
}
