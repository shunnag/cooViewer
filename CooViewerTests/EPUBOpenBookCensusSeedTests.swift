import XCTest

@testable import cooViewer

/// 開いている巻だけ atlas の再計測を省ける判定を検証する
/// （cooViewer-oxr.65 / cooViewer-oxr.70、設計書 §2.4）。
final class EPUBOpenBookCensusSeedTests: XCTestCase {
    func testMatchingMetricsProducesSeed() {
        XCTAssertEqual(
            EPUBOpenBookCensusSeed.make(
                requestedMetricsKey: "same", viewMetricsKey: "same",
                counts: [2, 3], pagesPerScreen: 2, entryIndex: 4),
            EPUBOpenBookCensusSeed(
                entryIndex: 4, counts: [2, 3], pagesPerScreen: 2))
    }

    func testMismatchedOrIncompleteCensusDoesNotProduceSeed() {
        XCTAssertNil(EPUBOpenBookCensusSeed.make(
            requestedMetricsKey: "new", viewMetricsKey: "old",
            counts: [2], pagesPerScreen: 1, entryIndex: 0))
        XCTAssertNil(EPUBOpenBookCensusSeed.make(
            requestedMetricsKey: "same", viewMetricsKey: "same",
            counts: nil, pagesPerScreen: 1, entryIndex: 0))
    }
}
