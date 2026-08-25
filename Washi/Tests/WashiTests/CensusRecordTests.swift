import XCTest
@testable import Washi

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

    /// releaseIdentifier nil もラウンドトリップする(未バージョンの本)
    func testCodableNilIdentifier() throws {
        let record = EPUBCensusRecord(metricsKey: "k", counts: [1],
                                      releaseIdentifier: nil)
        let decoded = try JSONDecoder().decode(
            EPUBCensusRecord.self, from: try JSONEncoder().encode(record))
        XCTAssertNil(decoded.releaseIdentifier)
    }
}
