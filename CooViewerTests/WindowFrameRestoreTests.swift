import XCTest
@testable import cooViewer

/// ウインドウ位置復元の判定(終了時と画面解像度が一致するときのみ復元)
final class WindowFrameRestoreTests: XCTestCase {
    private let laptop = CGSize(width: 1728, height: 1117)
    private let external = CGSize(width: 2560, height: 1440)

    func testMatchingResolutionRestores() {
        XCTAssertTrue(ReaderWindowController.shouldRestorePosition(
            savedScreenSize: "{1728, 1117}", screenSizes: [laptop]))
    }

    func testMatchingAnyAttachedScreenRestores() {
        // 外部ディスプレイ側の解像度でも、まだ繋がっていれば復元する
        XCTAssertTrue(ReaderWindowController.shouldRestorePosition(
            savedScreenSize: "{2560, 1440}", screenSizes: [laptop, external]))
    }

    func testChangedResolutionRecenters() {
        XCTAssertFalse(ReaderWindowController.shouldRestorePosition(
            savedScreenSize: "{2560, 1440}", screenSizes: [laptop]))
    }

    func testMissingOrGarbageValueRecenters() {
        XCTAssertFalse(ReaderWindowController.shouldRestorePosition(
            savedScreenSize: nil, screenSizes: [laptop]))
        XCTAssertFalse(ReaderWindowController.shouldRestorePosition(
            savedScreenSize: "not-a-size", screenSizes: [laptop]))
        XCTAssertFalse(ReaderWindowController.shouldRestorePosition(
            savedScreenSize: "{0, 0}", screenSizes: [laptop]))
    }

    // MARK: - タイル状態の除去(macOS 26 の tilingState 付き autosave)

    func testTiledFrameKeepsFrameAndDropsTilingState() {
        // フィルタイルのまま終了した保存値 → フレームはそのまま、JSON だけ除去
        // (見た目は終了時どおりに復元し、タイルとしては復活させない)
        let saved = "0 51 1728 1033 0 0 1728 1084 "
            + #"{"tilingState":{"tilingPosition":9,"normalizedSize":1,"#
            + #""untiledFrame":"{{513, 409}, {1215, 657}}"}}"#
        XCTAssertEqual(ReaderWindowController.untiledFrameString(from: saved),
                       "0 51 1728 1033 0 0 1728 1084 ")
    }

    func testPlainFrameIsLeftAlone() {
        XCTAssertNil(ReaderWindowController.untiledFrameString(
            from: "300 400 900 700 0 0 1728 1084 "))
    }

    func testMalformedTilingInfoIsLeftAlone() {
        // JSON が壊れている/tilingState 以外の JSON → 触らない(従来動作)
        XCTAssertNil(ReaderWindowController.untiledFrameString(
            from: "0 51 1728 1033 0 0 1728 1084 {not-json"))
        XCTAssertNil(ReaderWindowController.untiledFrameString(
            from: #"0 51 1728 1033 0 0 1728 1084 {"unknownKey":1}"#))
    }
}
