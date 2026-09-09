import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C40: 保存済みハイライトの描画。
final class HighlightModelTests: XCTestCase {
    func testCodingRoundTrip() throws {
        let highlight = EPUBHighlight(id: "h1", spineIndex: 2, idref: "c3",
                                      utf16Offset: 100, utf16Length: 25,
                                      style: .green, note: "覚え書き")
        let data = try JSONEncoder().encode(highlight)
        let decoded = try JSONDecoder().decode(EPUBHighlight.self, from: data)
        XCTAssertEqual(decoded, highlight)
        XCTAssertEqual(decoded.note, "覚え書き")
        XCTAssertEqual(decoded.textRange.utf16Offset, 100)
    }

    /// 壊れた保存データを持ち込ませない
    func testDecodingClampsBadValues() throws {
        let json = Data("""
            {"id":"x","spineIndex":0,"utf16Offset":-5,"utf16Length":0,"style":"chartreuse"}
            """.utf8)
        let decoded = try JSONDecoder().decode(EPUBHighlight.self, from: json)
        XCTAssertEqual(decoded.utf16Offset, 0)
        XCTAssertEqual(decoded.utf16Length, 1)
        XCTAssertEqual(decoded.style, .yellow, "未知の見た目は既定へ落とす")
    }

    func testInitializerClampsBadValues() {
        let highlight = EPUBHighlight(id: "x", spineIndex: 0,
                                      utf16Offset: -3, utf16Length: -1)
        XCTAssertEqual(highlight.utf16Offset, 0)
        XCTAssertEqual(highlight.utf16Length, 1)
    }
}

/// 実際に本を開き、CSS Custom Highlight API へ登録されるところまで見る。
@MainActor
final class HighlightRenderingTests: XCTestCase {
    func testHighlightsAreRegisteredForTheVisibleItem() async throws {
        let body = (0..<60).map { "<p>本文の段落 \($0) です。検証用の文章。</p>" }
            .joined()
        let publication = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.singleSpineEntries(bodyHTML: body), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-highlight.epub"))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 480, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil) }

        view.load(publication: publication)
        for _ in 0..<300 where view.pageCountInItem <= 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(view.pageCountInItem, 1)

        view.highlights = [
            EPUBHighlight(id: "a", spineIndex: 0, utf16Offset: 5, utf16Length: 8,
                          style: .yellow),
            EPUBHighlight(id: "b", spineIndex: 0, utf16Offset: 40, utf16Length: 6,
                          style: .green, note: "メモ"),
            // 別の項目のものは描かない
            EPUBHighlight(id: "c", spineIndex: 5, utf16Offset: 0, utf16Length: 3),
        ]
        try await Task.sleep(for: .milliseconds(400))

        let registered = try await view.evaluateForTest(
            "return CSS.highlights ? Array.from(CSS.highlights.keys()).sort() : [];")
        let keys = try XCTUnwrap(registered as? [String])
        XCTAssertEqual(keys, ["washi-hl-green", "washi-hl-yellow"],
                       "登録された見た目が期待と違う: \(keys)")

        // 空にすると解除される
        view.highlights = []
        try await Task.sleep(for: .milliseconds(300))
        let cleared = try await view.evaluateForTest(
            "return CSS.highlights ? CSS.highlights.size : -1;")
        XCTAssertEqual(cleared as? Int, 0, "解除されていない")
    }
}
