import AppKit
import XCTest
@testable import Washi

/// cooViewer-oxr.46 C08: 再生エンジンのタイマーが実行ループの追跡モードでも
/// 動くこと。ライブリサイズやメニュー追跡の間 tick が止まると、音声だけ先へ
/// 進んで clipEnd を跨ぎ、復帰後の連続判定が外れて clipBegin へ巻き戻る。
@MainActor
final class MediaOverlayPlaybackTests: XCTestCase {
    private func publication(parCount: Int) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.silentMediaOverlayEntries(parCount: parCount), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-silent-mo.epub"))
    }

    /// 実行ループを追跡モード(.eventTracking)だけで回しても par が進むこと。
    /// Timer.scheduledTimer(= .default のみ)では 1 つも進まない。
    func testPlaybackAdvancesWhileRunLoopIsInTrackingMode() throws {
        let book = try publication(parCount: 4)
        XCTAssertNotNil(book.mediaOverlay(forSpineIndex: 0))
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.load(publication: book)
        let controller = MediaOverlayController(
            reader: view, publication: book, activeClass: "-epub-media-overlay-active")
        // 実際の経路と同じく reader に持たせる(世代・所有権のガードが働く)
        view.mediaOverlayController = controller
        controller.continuesToNextItem = false
        controller.play(fromSpineIndex: 0)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.currentParIndex, 0)

        // 音声の無い par は 0.4 秒で次へ進む。追跡モードだけで 1.4 秒回す。
        let deadline = Date().addingTimeInterval(1.4)
        while Date() < deadline {
            RunLoop.main.run(mode: .eventTracking,
                             before: Date().addingTimeInterval(0.05))
        }

        XCTAssertGreaterThan(controller.currentParIndex, 0,
                             "追跡モード中に par が進まない(タイマーが .default モード)")
        controller.stop()
    }

    /// cooViewer-oxr.46 C07: 1 つの SMIL が複数の XHTML を束ねる本で、
    /// 別文書を指す par に来たらその文書へ移ってからハイライトする。
    func testParPointingAtAnotherDocumentMovesThere() throws {
        let book = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.multiDocumentMediaOverlayEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-multi-mo.epub"))
        XCTAssertEqual(book.readingOrder.count, 2)
        let overlay = try XCTUnwrap(book.mediaOverlay(forSpineIndex: 0))
        XCTAssertEqual(overlay.parallels.count, 4, "SMIL が 2 文書分の par を持つ")

        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.load(publication: book)
        let controller = MediaOverlayController(
            reader: view, publication: book, activeClass: "-epub-media-overlay-active")
        // 実際の経路と同じく reader に持たせる(世代・所有権のガードが働く)
        view.mediaOverlayController = controller
        controller.continuesToNextItem = false
        controller.play(fromSpineIndex: 0)
        XCTAssertEqual(controller.currentSpineIndex, 0)

        // 無音 par は 0.4 秒で進む。3 つめ(b.xhtml)まで進める
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, controller.currentParIndex < 2 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(controller.currentParIndex, 2, "par が進まない")
        XCTAssertEqual(controller.currentSpineIndex, 1,
                       "別文書を指す par で文書を移っていない")
        controller.stop()
    }

    /// 同じ SMIL を指す隣の項目へは連続再生で戻らない(頭から鳴らし直さない)。
    func testNextItemSkipsSpineItemsSharingTheSameOverlay() throws {
        let book = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.multiDocumentMediaOverlayEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-multi-mo2.epub"))
        XCTAssertEqual(book.mediaOverlayPath(forSpineIndex: 0),
                       book.mediaOverlayPath(forSpineIndex: 1),
                       "2 項目が同じ SMIL を指す前提")
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.load(publication: book)
        let controller = MediaOverlayController(
            reader: view, publication: book, activeClass: "-epub-media-overlay-active")
        view.mediaOverlayController = controller
        controller.play(fromSpineIndex: 0)
        // 最後まで進めても、同じ SMIL を par 0 から鳴らし直さない
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, controller.isPlaying {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(controller.isPlaying, "同じ SMIL を鳴らし直して終わらない")
    }

    /// 破棄した後もタイマーが起き続けないこと(次の発火で自分を止める)。
    func testTimerStopsAfterControllerIsReleased() throws {
        let book = try publication(parCount: 8)
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.load(publication: book)
        weak var weakController: MediaOverlayController?
        do {
            let controller = MediaOverlayController(
                reader: view, publication: book,
                activeClass: "-epub-media-overlay-active")
            controller.continuesToNextItem = false
            controller.play(fromSpineIndex: 0)
            weakController = controller
        }
        XCTAssertNil(weakController, "所有者が消えたら解放される(タイマーが強参照しない)")
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
