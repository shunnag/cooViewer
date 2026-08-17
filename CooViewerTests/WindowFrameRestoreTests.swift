import XCTest
@testable import cooViewer

/// ウインドウ位置の永続化(タイル状態除去)の検証。
///
/// 位置・サイズの復元自体は AppKit の setFrameAutosaveName に委ねる(復元時に
/// constrainFrameRect で必ず画面内へ収まる)。以前あった独自の画面解像度ゲートは
/// 不一致時に window.center() が保存位置を破壊していた(クラッシュ/強制終了で解像度
/// 記録が残らないと毎回リセット)ため撤去した。ここではタイル状態除去のみを検証する。
final class WindowFrameRestoreTests: XCTestCase {
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
