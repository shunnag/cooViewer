import XCTest
import Washi
@testable import cooViewer

/// 同一 URL の並行 EPUB 解析が 1 本に合流することの検証(cooViewer-7rl)。
@MainActor
final class EPUBParseCoalescingTests: XCTestCase {
    private enum InjectedParseError: LocalizedError, Equatable {
        case failed

        var errorDescription: String? { "注入した EPUB 解析エラー" }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testConcurrentSameURLParsesOnce() async {
        let counter = Counter()
        let parseStarted = DispatchSemaphore(value: 0)
        let requestCoalesced = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let coalescer = EPUBParseCoalescer(
            parse: { _ in
                counter.increment()
                parseStarted.signal()
                gate.wait()
                throw InjectedParseError.failed
            },
            onCoalescedRequest: { requestCoalesced.signal() })
        let url = URL(fileURLWithPath: "/x/a.epub")
        let a = Task { await coalescer.publication(at: url) }
        let didStart = await Self.waitForSignal(parseStarted)
        let b = Task { await coalescer.publication(at: url) }
        let didCoalesce = await Self.waitForSignal(requestCoalesced)
        // 失敗時に 2 本目が別パースへ進んでもテストを停止させない。
        gate.signal()
        gate.signal()
        _ = await (a.value, b.value)
        XCTAssertTrue(didStart, "最初の解析が制限時間内に開始される")
        XCTAssertTrue(didCoalesce, "2 本目が実行中の解析へ合流する")
        XCTAssertEqual(counter.count, 1, "同一 URL の並行解析は 1 回だけ")
    }

    private nonisolated static func waitForSignal(
        _ semaphore: DispatchSemaphore
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning:
                    semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    func testDifferentURLsParseIndependently() async {
        let counter = Counter()
        let coalescer = EPUBParseCoalescer(parse: { _ in
            counter.increment(); throw InjectedParseError.failed
        })
        _ = await coalescer.publication(at: URL(fileURLWithPath: "/x/a.epub"))
        _ = await coalescer.publication(at: URL(fileURLWithPath: "/x/b.epub"))
        XCTAssertEqual(counter.count, 2)
    }

    func testInFlightClearedAfterCompletion() async {
        // 完了後は合流窓が閉じ、同 URL の再要求は新規パース(結果キャッシュなし)
        let counter = Counter()
        let coalescer = EPUBParseCoalescer(parse: { _ in
            counter.increment(); throw InjectedParseError.failed
        })
        let url = URL(fileURLWithPath: "/x/a.epub")
        _ = await coalescer.publication(at: url)
        _ = await coalescer.publication(at: url)
        XCTAssertEqual(counter.count, 2)
    }

    func testPublicationResultPropagatesInjectedError() async {
        let coalescer = EPUBParseCoalescer(parse: { _ in
            throw InjectedParseError.failed
        })

        switch await coalescer.publication(
            at: URL(fileURLWithPath: "/x/broken.epub")) {
        case .success:
            XCTFail("解析失敗が成功に変換された")
        case .failure(let error):
            XCTAssertEqual(error as? InjectedParseError, .failed)
            XCTAssertEqual(error.localizedDescription, "注入した EPUB 解析エラー")
        }
    }

    func testPublicationCompatibilityAccessorReturnsNilOnFailure() async {
        let coalescer = EPUBParseCoalescer(parse: { _ in
            throw InjectedParseError.failed
        })

        let publication = await coalescer.publicationIfAvailable(
            at: URL(fileURLWithPath: "/x/broken.epub"))

        XCTAssertNil(publication)
    }

    func testPreparsedPublicationBypassesInjectedParser() async throws {
        let url = URL(fileURLWithPath: "/x/preparsed.epub")
        let publication = try makePublication(displayURL: url)
        let counter = Counter()
        let coalescer = EPUBParseCoalescer(parse: { _ in
            counter.increment()
            throw InjectedParseError.failed
        })

        switch await coalescer.publication(at: url, preparsed: publication) {
        case .success(let result):
            XCTAssertTrue(result === publication)
        case .failure:
            XCTFail("事前解析済み publication が再解析された")
        }
        XCTAssertEqual(counter.count, 0)
    }

    func testEPUBOpenFailureMessageIncludesDescription() {
        XCTAssertEqual(
            ReaderWindowController.epubOpenFailureMessage(
                description: "注入した EPUB 解析エラー"),
            "この EPUB を開けません: 注入した EPUB 解析エラー")
    }

    private func makePublication(displayURL: URL) throws -> EPUBPublication {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/package.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
          unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">preparsed-test</dc:identifier>
            <dc:title>事前解析</dc:title><dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="c" href="c.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>本文</title></head>
          <body><p>本文</p></body></html>
        """
        return try EPUBPublication(data: TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
            (Array("OEBPS/c.xhtml".utf8), Data(chapter.utf8)),
        ]), displayURL: displayURL)
    }
}
