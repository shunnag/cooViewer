import CoreGraphics
import Foundation
import Washi
import XCTest

@testable import cooViewer

/// 保存済み実測を使う合本も、全巻を測った合本と同じ通しページになる。
@MainActor
final class CollectionSavedCensusTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var history: BookHistoryStore!

    override func setUp() async throws {
        try await MainActor.run {
            directory = try TestFixtures.makeTempDir()
            suiteName = "test.cooViewer.collection-census.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)
            history = reopenHistory()
        }
    }

    override func tearDown() async throws {
        try await MainActor.run {
            defaults.removePersistentDomain(forName: suiteName)
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func reopenHistory() -> BookHistoryStore {
        BookHistoryStore(defaults: defaults,
                         directory: directory.appendingPathComponent("BookStates"))
    }

    private var metrics: EPUBScreenMetrics {
        EPUBScreenMetrics(viewportSize: CGSize(width: 1000, height: 800),
                          settings: EPUBReaderSettings())
    }

    func testTwoSavedChildrenSkipAtlasAndMatchFullyMeasuredMap() async throws {
        let publications = try (0..<3).map { try publication("book\($0)") }
        let source = SourceStub(url: directory, publications: publications)
        let expected = [[2, 3], [4, 1], [3, 2]]
        for index in 0..<2 {
            save(publications[index], counts: expected[index], key: metrics.cacheKey)
            // 新しい不一致版面があっても、MRU 内の一致する実測を使う。
            save(publications[index], counts: [99, 99], key: "different-metrics")
        }
        history = reopenHistory()
        let cached = AtlasProbe(counts: expected, latency: .milliseconds(50))
        let uncached = AtlasProbe(counts: expected, latency: .milliseconds(50))
        let clock = ContinuousClock()
        let cachedStart = clock.now
        let counts = await build(publications, source: source, atlas: cached.store)
        let cachedTime = cachedStart.duration(to: clock.now)
        let measuredStart = clock.now
        let measured = await CollectionPageMapBuilder.counts(
            placeholders: placeholders(publications), metrics: metrics, seededCounts: [:],
            collectionSource: source,
            history: BookHistoryStore(defaults: defaults,
                                      directory: directory.appendingPathComponent("EmptyStates")),
            atlasStore: uncached.store)
        let measuredTime = measuredStart.duration(to: clock.now)

        XCTAssertEqual(cached.requests, [publications[2].url])
        XCTAssertEqual(cached.createdAtlases, 1, "保存値がある巻の WebKit を作らない")
        XCTAssertEqual(uncached.requests.count, 3)
        XCTAssertEqual(cached.censusTime, .milliseconds(50))
        XCTAssertEqual(uncached.censusTime, .milliseconds(150))
        XCTAssertEqual(counts, measured)
        let entries = try await source.entries()
        let map = CollectionPageMap.make(folderPath: directory.path,
                                        metricsKey: metrics.cacheKey, entries: entries, counts: counts)
        let reference = CollectionPageMap.make(folderPath: directory.path,
                                              metricsKey: metrics.cacheKey, entries: entries, counts: measured)
        XCTAssertTrue(map.isComplete)
        XCTAssertEqual(map.total, 15)
        XCTAssertEqual(map.total, reference.total)
        XCTAssertEqual(map.missingEntries, reference.missingEntries)
        XCTAssertEqual(map.segments.map(\.globalStart), reference.segments.map(\.globalStart))
        for page in 0..<map.total {
            XCTAssertEqual(map.target(forGlobalPage: page), reference.target(forGlobalPage: page))
        }
        print("Collection census: seeded=\(cached.requests.count) runs / \(cachedTime), "
              + "all=\(uncached.requests.count) runs / \(measuredTime), fake latency=50ms/run")
    }

    func testDifferentMetricsAreRemeasured() async throws {
        let book = try publication("book0")
        let source = SourceStub(url: directory, publications: [book])
        var alternatives: [EPUBScreenMetrics] = []
        var settings = EPUBReaderSettings()
        settings.fontScale = 1.25
        alternatives.append(EPUBScreenMetrics(viewportSize: CGSize(width: 1000, height: 800), settings: settings))
        settings = EPUBReaderSettings()
        settings.insets.left += 10
        alternatives.append(EPUBScreenMetrics(viewportSize: CGSize(width: 1000, height: 800), settings: settings))
        settings = EPUBReaderSettings()
        settings.defaultFontFamily = "serif"
        alternatives.append(EPUBScreenMetrics(viewportSize: CGSize(width: 1000, height: 800), settings: settings))
        settings = EPUBReaderSettings()
        settings.columnMode = .single
        alternatives.append(EPUBScreenMetrics(viewportSize: CGSize(width: 1000, height: 800), settings: settings))
        settings = EPUBReaderSettings()
        settings.userCSS = "body { writing-mode: vertical-rl; }"
        alternatives.append(EPUBScreenMetrics(viewportSize: CGSize(width: 1000, height: 800), settings: settings))
        alternatives.append(EPUBScreenMetrics(viewportSize: CGSize(width: 800, height: 1000), settings: EPUBReaderSettings()))
        alternatives.append(EPUBScreenMetrics(viewportSize: CGSize(width: 1001, height: 800), settings: EPUBReaderSettings()))
        for alternative in alternatives {
            XCTAssertNotEqual(alternative.cacheKey, metrics.cacheKey)
            save(book, counts: [99, 99], key: alternative.cacheKey)
            let probe = AtlasProbe(counts: [[2, 3]])
            let counts = await build([book], source: source, atlas: probe.store)
            XCTAssertEqual(probe.requests, [book.url])
            XCTAssertEqual(counts[0], [2, 3])
        }
    }

    func testInvalidEditionSpineOrCountsAreRemeasured() async throws {
        let book = try publication("book0")
        let source = SourceStub(url: directory, publications: [book])
        for counts in [[], [1], [0, 1], [-1, 1], [Int.max, 1]] {
            save(book, counts: counts, key: metrics.cacheKey)
            let probe = AtlasProbe(counts: [[2, 3]])
            let result = await build([book], source: source, atlas: probe.store)
            XCTAssertEqual(probe.requests.count, 1)
            XCTAssertEqual(result[0], [2, 3])
        }
        save(book, counts: [99, 99], key: metrics.cacheKey, releaseIdentifier: "older-edition")
        let probe = AtlasProbe(counts: [[2, 3]])
        let result = await build([book], source: source, atlas: probe.store)
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(result[0], [2, 3])
    }

    func testOldPaginationVersionIsRemeasured() async throws {
        let book = try publication("book0")
        var options = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(metrics.cacheKey.utf8)) as? [String: Any])
        options["engine"] = EPUBScreenMetrics.paginationVersion - 1
        let data = try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        save(book, counts: [99, 99], key: String(decoding: data, as: UTF8.self))
        let probe = AtlasProbe(counts: [[2, 3]])
        let result = await build([book], source: SourceStub(url: directory, publications: [book]),
                                 atlas: probe.store)
        XCTAssertEqual(probe.requests, [book.url])
        XCTAssertEqual(result[0], [2, 3])
    }

    func testPublicationSpreadAndFlowUseReaderMetricsKey() async throws {
        for metadata in [
            "<meta property=\"rendition:spread\">none</meta>",
            "<meta property=\"rendition:flow\">scrolled-doc</meta>"
        ] {
            let book = try publication("book0", metadata: metadata)
            let key = metrics.applyingRenditionSpread(book.metadata.rendition.spread)
                .applyingRenditionFlow(book.metadata.rendition.flow).cacheKey
            XCTAssertNotEqual(key, metrics.cacheKey)
            save(book, counts: [2, 3], key: key)
            let probe = AtlasProbe(counts: [[99, 99]])
            let result = await build([book], source: SourceStub(url: directory, publications: [book]),
                                     atlas: probe.store)
            XCTAssertEqual(result[0], [2, 3])
            XCTAssertEqual(probe.createdAtlases, 0)
        }
    }

    func testSavedCensusCanBeValidatedWithoutPreparsedPublication() async throws {
        let book = try publication("book0")
        save(book, counts: [2, 3], key: metrics.cacheKey)
        let source = SourceStub(url: directory, publications: [])
        let probe = AtlasProbe(counts: [[99, 99]])
        let result = await build([book], source: source, atlas: probe.store)
        XCTAssertEqual(result[0], [2, 3])
        XCTAssertEqual(probe.createdAtlases, 0)
    }

    func testExistingLiveAndPartialMapSeedsTakePrecedence() async throws {
        let books = try [publication("book0"), publication("book1")]
        for book in books { save(book, counts: [99, 99], key: metrics.cacheKey) }
        let probe = AtlasProbe(counts: [[99, 99], [99, 99]])
        let counts = await CollectionPageMapBuilder.counts(
            placeholders: placeholders(books), metrics: metrics,
            seededCounts: [0: [2, 3], 1: [4, 1]],
            collectionSource: SourceStub(url: directory, publications: []),
            history: history, atlasStore: probe.store)
        XCTAssertEqual(counts, [0: [2, 3], 1: [4, 1]])
        XCTAssertEqual(probe.createdAtlases, 0)
    }

    private func build(_ publications: [EPUBPublication], source: SourceStub,
                       atlas: EPUBAtlasStore) async -> [Int: [Int]] {
        await CollectionPageMapBuilder.counts(
            placeholders: placeholders(publications), metrics: metrics, seededCounts: [:],
            collectionSource: source, history: history, atlasStore: atlas)
    }

    private func placeholders(_ publications: [EPUBPublication]) -> [(index: Int, url: URL)] {
        publications.enumerated().map { ($0.offset, $0.element.url) }
    }

    private func save(_ book: EPUBPublication, counts: [Int], key: String,
                      releaseIdentifier: String? = nil) {
        history.noteClosedReflow(path: book.url.path, spineIndex: 1, progression: 0.5,
                                 forceRememberBeyondRecents: true)
        history.noteReflowCensus(path: book.url.path, metricsKey: key, counts: counts,
                                releaseIdentifier: releaseIdentifier ?? book.metadata.releaseIdentifier)
    }

    private func publication(_ name: String, metadata: String = "") throws -> EPUBPublication {
        let container = """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
        <rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="uid">\(name)</dc:identifier><dc:title>検証</dc:title><dc:language>ja</dc:language>
        <meta property="dcterms:modified">2026-10-29T00:00:00Z</meta>\(metadata)</metadata>
        <manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine></package>
        """
        let chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>章</title></head><body><p>本文</p></body></html>"
        let data = TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("package.opf".utf8), Data(package.utf8)),
            (Array("ch1.xhtml".utf8), Data(chapter.utf8)),
            (Array("ch2.xhtml".utf8), Data(chapter.utf8))
        ])
        let url = directory.appendingPathComponent("\(name).epub")
        try data.write(to: url)
        return try EPUBPublication(data: data, displayURL: url)
    }

    private struct SourceStub: BookSource {
        let url: URL
        let publications: [EPUBPublication]
        var supportsDateSort: Bool { false }

        func entries() async throws -> [PageEntry] {
            publications.enumerated().map { index, book in
                PageEntry(id: index, name: book.url.lastPathComponent,
                          pathInBook: book.url.lastPathComponent, fileURL: book.url,
                          creationDate: nil, modificationDate: nil, reflowEPUBURL: book.url)
            }
        }

        func preparsedReflowPublication(for url: URL) async -> EPUBPublication? {
            publications.first { $0.url == url }
        }

        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
    }

    @MainActor
    private final class AtlasProbe {
        let counts: [[Int]]
        let latency: Duration
        var requests: [URL] = []
        var createdAtlases = 0
        var censusTime: Duration = .zero
        lazy var store = EPUBAtlasStore(makeAtlas: { [unowned self] publication in
            createdAtlases += 1
            return AtlasStub(publication: publication, probe: self)
        })

        init(counts: [[Int]], latency: Duration = .zero) {
            self.counts = counts
            self.latency = latency
        }
    }

    private final class AtlasStub: EPUBScreenAtlasing {
        let publication: EPUBPublication
        unowned let probe: AtlasProbe
        var offscreenEnergyPolicy: EPUBOffscreenEnergyPolicy = .followSystem

        init(publication: EPUBPublication, probe: AtlasProbe) {
            self.publication = publication
            self.probe = probe
        }

        func screenPlan(metrics: EPUBScreenMetrics) async -> (counts: [Int], pagesPerScreen: Int)? {
            probe.requests.append(publication.url)
            probe.censusTime += probe.latency
            try? await Task.sleep(for: probe.latency)
            let index = Int(publication.url.deletingPathExtension().lastPathComponent.dropFirst(4)) ?? 0
            return (probe.counts[index], metrics.pagesPerScreen)
        }

        func thumbnail(spineIndex: Int, pageInItem: Int, metrics: EPUBScreenMetrics,
                       isDark: Bool, maxPixelSize: Int) async -> CGImage? { nil }
        func invalidate() {}
    }
}
