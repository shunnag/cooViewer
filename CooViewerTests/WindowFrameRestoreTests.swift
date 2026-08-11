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
}
