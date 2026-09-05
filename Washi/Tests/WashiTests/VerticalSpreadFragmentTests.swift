import XCTest
@testable import Washi

// cooViewer-oxr.5: 既存の縦書き見開きテスト群に、章ラッパーと長い段落の着地を追加。
extension VerticalSpreadPagingTests {
    func testFragmentAndMediaOverlayLandOnFirstColumnFragment() async throws {
        let body = "<style>html { writing-mode:vertical-rl; }</style>"
            + "<div id=\"sec\"><p id=\"long\">"
            + String(repeating: "縦書きの長い段落と章の先頭断片を検証します。", count: 350)
            + "</p></div>"
        let harness = try ReaderScriptTestHarness(entries: EPUBFixtures.singleSpineEntries(bodyHTML: body))
        defer { harness.close() }
        try await harness.load()
        let setup = try await harness.setup()
        XCTAssertEqual(setup["verticalRL"], 1)
        XCTAssertEqual(setup["pagesPerScreen"], 2)
        XCTAssertGreaterThan(try XCTUnwrap(setup["pageCount"]), 4)

        for id in ["sec", "long"] {
            let fragmented: Bool = try await harness.evaluate("""
                const el = document.getElementById('\(id)');
                const rects = el.getClientRects();
                return rects.length > 2 && el.getBoundingClientRect().left < rects[0].left - 640;
                """)
            XCTAssertTrue(fragmented, id)
            let landed: Int = try await harness.evaluate("""
                __washi.showLastPage();
                return __washi.showFragment('\(id)');
                """)
            XCTAssertEqual(landed, 0, id)
            let progression: Double = try await harness.evaluate("return __washi.currentProgression();")
            XCTAssertEqual(progression, 0, id)
            let visibleHighlight: Int = try await harness.evaluate(
                "return __washi.mediaOverlayHighlight('\(id)', 'washi-test-active');")
            XCTAssertEqual(visibleHighlight, 0, id)
            let movedHighlight: Int = try await harness.evaluate("""
                __washi.showLastPage();
                return __washi.mediaOverlayHighlight('\(id)', 'washi-test-active');
                """)
            XCTAssertEqual(movedHighlight, 0, id)
        }
    }
}
