import CoreGraphics
import Foundation
import Washi
import XCTest

@testable import cooViewer

/// 解析済み publication の再利用と、同名 EPUB 差替え時のアトラス更新を検証する。
@MainActor
final class EPUBAtlasStoreTests: XCTestCase {
    @MainActor
    private final class AtlasStub: EPUBScreenAtlasing {
        let publication: EPUBPublication
        private(set) var invalidateCount = 0

        init(publication: EPUBPublication) {
            self.publication = publication
        }

        func screenPlan(
            metrics: EPUBScreenMetrics
        ) async -> (counts: [Int], pagesPerScreen: Int)? {
            ([1], metrics.pagesPerScreen)
        }

        func thumbnail(spineIndex: Int, pageInItem: Int,
                       metrics: EPUBScreenMetrics, isDark: Bool,
                       width: CGFloat) async -> CGImage? {
            nil
        }

        func invalidate() {
            invalidateCount += 1
        }
    }

    private var metrics: EPUBScreenMetrics {
        EPUBScreenMetrics(
            viewportSize: CGSize(width: 640, height: 900),
            settings: EPUBReaderSettings())
    }

    func testScreenPlanUsesMatchingPreparsedPublication() async throws {
        let directory = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        let alias = directory.appendingPathComponent("book-link.epub")
        try Self.epubData(identifier: "preparsed", body: "本文").write(to: url)
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: url)
        let publication = try EPUBPublication(url: url, readStrategy: .alwaysCopy)
        var received: EPUBPublication?
        let store = EPUBAtlasStore(makeAtlas: {
            received = $0
            return AtlasStub(publication: $0)
        })

        let plan = await store.screenPlan(
            for: alias, metrics: metrics, preparsed: publication)

        XCTAssertEqual(plan?.counts, [1])
        XCTAssertTrue(received === publication,
                      "cooViewer-oxr.42: 正規化パスが同じ解析済みインスタンスを使う")
    }

    func testThumbnailUsesMatchingPreparsedPublication() async throws {
        let directory = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        try Self.epubData(identifier: "thumbnail", body: "本文").write(to: url)
        let publication = try EPUBPublication(url: url, readStrategy: .alwaysCopy)
        var received: EPUBPublication?
        let store = EPUBAtlasStore(makeAtlas: {
            received = $0
            return AtlasStub(publication: $0)
        })

        _ = await store.thumbnail(
            for: url, spineIndex: 0, pageInItem: 0,
            metrics: metrics, isDark: false, width: 120,
            preparsed: publication)

        XCTAssertTrue(received === publication,
                      "設計書 §2.4: サムネイル経路でも再解析しない")
    }

    func testMismatchedPreparsedPublicationIsNotReused() async throws {
        let directory = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suppliedURL = directory.appendingPathComponent("supplied.epub")
        let requestedURL = directory.appendingPathComponent("requested.epub")
        try Self.epubData(identifier: "supplied", body: "供給元").write(to: suppliedURL)
        try Self.epubData(identifier: "requested", body: "要求先").write(to: requestedURL)
        let supplied = try EPUBPublication(
            url: suppliedURL, readStrategy: .alwaysCopy)
        var received: EPUBPublication?
        let store = EPUBAtlasStore(makeAtlas: {
            received = $0
            return AtlasStub(publication: $0)
        })

        _ = await store.screenPlan(
            for: requestedURL, metrics: metrics, preparsed: supplied)

        XCTAssertNotNil(received)
        XCTAssertFalse(received === supplied)
        XCTAssertEqual(received.map { CanonicalPath.normalize($0.url.path) },
                       CanonicalPath.normalize(requestedURL.path),
                       "正規化パスが違う publication は要求先の代用にしない")
    }

    func testReplacedFileInvalidatesAndRebuildsAfterFiveSeconds() async throws {
        let directory = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replace.epub")
        try Self.epubData(identifier: "first", body: "短い本文").write(to: url)
        let stalePublication = try EPUBPublication(
            url: url, readStrategy: .alwaysCopy)
        var clock: TimeInterval = 100
        var atlases: [AtlasStub] = []
        let store = EPUBAtlasStore(
            makeAtlas: {
                let atlas = AtlasStub(publication: $0)
                atlases.append(atlas)
                return atlas
            },
            now: { clock })

        _ = await store.screenPlan(
            for: url, metrics: metrics, preparsed: stalePublication)
        XCTAssertEqual(atlases.count, 1)
        XCTAssertTrue(atlases[0].publication === stalePublication)

        try Self.epubData(
            identifier: "second",
            body: String(repeating: "差替え後の長い本文。", count: 50)
        ).write(to: url, options: .atomic)
        clock = 104.9
        _ = await store.screenPlan(
            for: url, metrics: metrics, preparsed: stalePublication)
        XCTAssertEqual(atlases.count, 1, "5 秒未満では NAS の file identity を再検査しない")
        XCTAssertEqual(atlases[0].invalidateCount, 0)

        clock = 105
        _ = await store.screenPlan(
            for: url, metrics: metrics, preparsed: stalePublication)
        XCTAssertEqual(atlases.count, 2,
                       "cooViewer-oxr.66: 同名ファイルの差替え後は再構築する")
        XCTAssertEqual(atlases[0].invalidateCount, 1,
                       "差替え前のオフスクリーン資源を停止する")
        XCTAssertFalse(atlases[1].publication === stalePublication,
                       "差替え検出後は古い preparsed publication を再利用しない")

        clock = 110
        _ = await store.screenPlan(
            for: url, metrics: metrics, preparsed: stalePublication)
        XCTAssertEqual(atlases.count, 2, "file identity が同じなら再検査後も再利用する")
    }

    private nonisolated static func epubData(
        identifier: String, body: String
    ) -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">\(identifier)</dc:identifier>
            <dc:title>アトラス検証</dc:title>
            <dc:language>ja</dc:language>
            <meta property="dcterms:modified">2026-09-05T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """
        let chapter = """
        <?xml version="1.0"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>1</title></head><body><p>\(body)</p></body>
        </html>
        """
        return TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
            (Array("OEBPS/ch1.xhtml".utf8), Data(chapter.utf8)),
        ])
    }
}
