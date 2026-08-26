import AppKit
import XCTest

@testable import Washi

/// composeFullPage(ページめくり演出と snapshot() が共用する全面合成)のテスト。
/// 余白がビュー背景色で塗られ、本文が指定枠に載り、backing scale の
/// ビットマップ表現(演出側の cgImage 取り出しで 1x 化されない)であること。
/// 余白を辺ごとに非対称にし、上下/左右の取り違え(flip)も検出する。
@MainActor
final class PageComposeTests: XCTestCase {
    func testComposeFillsMarginsWithBackgroundAroundContent() throws {
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.layer?.backgroundColor =
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor

        // 本文領域は非対称(左 10 / 右 50 / 下 30 / 上 10)に置く
        let webFrame = NSRect(x: 10, y: 30, width: 140, height: 60)
        let content = NSImage(
            size: webFrame.size, flipped: false
        ) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let composed = view.composeFullPage(webImage: content, in: webFrame)

        XCTAssertEqual(composed.size, NSSize(width: 200, height: 100))
        guard let rep = composed.representations.first as? NSBitmapImageRep else {
            return XCTFail("ビットマップ表現であること(1x 化で文字がぼけない)")
        }
        XCTAssertGreaterThanOrEqual(rep.pixelsWide, 400, "backing scale の解像度")

        // ポイント座標(AppKit 下原点)→ ピクセル座標(上原点)で照合する
        let scale = CGFloat(rep.pixelsWide) / 200
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            rep.colorAt(x: Int(x * scale),
                        y: Int((100 - y) * scale) - 1)?.usingColorSpace(.sRGB)
        }
        func assertBackground(_ x: CGFloat, _ y: CGFloat,
                              _ message: String) {
            XCTAssertGreaterThan(color(x, y)?.redComponent ?? 0, 0.9, message)
            XCTAssertLessThan(color(x, y)?.blueComponent ?? 1, 0.1, message)
        }
        func assertContent(_ x: CGFloat, _ y: CGFloat, _ message: String) {
            XCTAssertGreaterThan(color(x, y)?.blueComponent ?? 0, 0.9, message)
            XCTAssertLessThan(color(x, y)?.redComponent ?? 1, 0.1, message)
        }
        assertBackground(5, 50, "左余白(10pt)")
        assertBackground(170, 50, "右余白(50pt)")
        assertBackground(100, 15, "下余白(30pt)")
        assertBackground(100, 95, "上余白(10pt)")
        assertContent(20, 40, "本文の左下寄り")
        assertContent(140, 85, "本文の右上寄り")
        assertContent(80, 60, "本文の中央")
    }
}
