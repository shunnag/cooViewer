import XCTest
@testable import Washi
@testable import WashiCore

/// census 永続化レコードの検証
final class CensusRecordTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let record = EPUBCensusRecord(
            metricsKey: "{\"spread\":true}", counts: [3, 5, 2],
            releaseIdentifier: "urn:uuid:x@2026-01-01")
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(EPUBCensusRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.counts.reduce(0, +), 10)
    }

    /// cooViewer-oxr.74: unique identifier 自体がない場合の nil も保持する。
    func testCodableNilIdentifier() throws {
        let record = EPUBCensusRecord(metricsKey: "k", counts: [1],
                                      releaseIdentifier: nil)
        let decoded = try JSONDecoder().decode(
            EPUBCensusRecord.self, from: try JSONEncoder().encode(record))
        XCTAssertNil(decoded.releaseIdentifier)
    }

    /// cooViewer-oxr.74: dcterms:modified がない本では unique identifier
    /// 自体が census レコードの releaseIdentifier になる。
    func testReleaseIdentifierFallsBackToUniqueIdentifierWithoutModified()
        throws {
        let opf = EPUBFixtures.verticalNovelOPF.replacingOccurrences(
            of: "<meta property=\"dcterms:modified\">2026-01-01T00:00:00Z</meta>",
            with: "")
        let package = try PackageDocumentParser.parse(
            data: Data(opf.utf8), at: "OEBPS/package.opf")
        let record = EPUBCensusRecord(
            metricsKey: "k", counts: [1],
            releaseIdentifier: package.metadata.releaseIdentifier)

        XCTAssertNil(package.metadata.modified)
        XCTAssertEqual(record.releaseIdentifier,
                       "urn:uuid:12345678-1234-1234-1234-123456789abc")
    }

    /// cooViewer-oxr.25: engine を持たない 1.14.x 形式の census は、
    /// 現在の reader へ取り込まず一度だけ再計測させる。
    @MainActor
    func testImportRejectsLegacyPaginationEngineKey() throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-legacy-census.epub"))
        let view = EPUBReaderView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        view.load(publication: publication)
        let legacy = EPUBCensusRecord(
            metricsKey: #"{"fixedLayout":false,"height":552,"width":688}"#,
            counts: Array(repeating: 1, count: publication.readingOrder.count),
            releaseIdentifier: publication.metadata.releaseIdentifier)

        XCTAssertFalse(view.importCensus(legacy))
    }
}
