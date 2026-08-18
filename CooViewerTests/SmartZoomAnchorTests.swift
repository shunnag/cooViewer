import AppKit
import XCTest
@testable import cooViewer

/// スマートズームのアンカー計算(contentAnchorRatio / scroll(toAnchorRatio:))の検証
@MainActor
final class SmartZoomAnchorTests: XCTestCase {
    /// 縦長 1 ページを表示した実物の ReaderView(ウインドウなしでレイアウト済み)
    private func makeView(viewSize: CGSize = CGSize(width: 400, height: 300),
                          imageSize: (w: Int, h: Int) = (200, 400)) -> ReaderView {
        let context = CGContext(
            data: nil, width: imageSize.w, height: imageSize.h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: imageSize.w, height: imageSize.h))
        let view = ReaderView(frame: CGRect(origin: .zero, size: viewSize))
        view.setPages([context.makeImage()!], readsFromLeft: false)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testAnchorRatioAtContentCenterIsHalf() {
        let view = makeView()
        // 全体フィット: 縦 300pt に合わせ 150x300 が中央 (125..275) に置かれる
        let ratio = view.contentAnchorRatio(for: CGPoint(x: 200, y: 150))
        XCTAssertEqual(ratio.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(ratio.y, 0.5, accuracy: 0.01)
    }

    func testAnchorRatioClampsOutsideContent() {
        let view = makeView()
        // コンテンツ外(左端の余白)は 0 へクランプ
        let ratio = view.contentAnchorRatio(for: CGPoint(x: 0, y: 0))
        XCTAssertEqual(ratio.x, 0)
        XCTAssertEqual(ratio.y, 0)
    }

    func testScrollToAnchorCentersTargetInFitWidth() {
        let view = makeView()
        view.fitMode = .fitWidth
        // 幅フィット: 400x800 になり縦スクロールが生まれる。下端 80% を狙う
        view.scroll(toAnchorRatio: CGPoint(x: 0.5, y: 0.8))
        view.layoutSubtreeIfNeeded()
        // 内容 800pt の 80%=640pt が視界(高さ 300)の中央 → offset=640-150=490
        // …だが最大 500 の範囲内なので 490 のまま
        XCTAssertEqual(view.debugScrollOffset.y, 490, accuracy: 1)
    }

    func testScrollToAnchorClampsAtEdges() {
        let view = makeView()
        view.fitMode = .fitWidth
        view.scroll(toAnchorRatio: CGPoint(x: 0.5, y: 1.0))
        XCTAssertEqual(view.debugScrollOffset.y, 500, accuracy: 1)  // 800-300
        view.scroll(toAnchorRatio: CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(view.debugScrollOffset.y, 0, accuracy: 1)
    }
}
