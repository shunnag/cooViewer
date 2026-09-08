import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// cooViewer-oxr.46 C52: 読書位置・しおりのテキストアンカー。
/// 進行率だけの復元は font 倍率や画面幅が変わると数ページずれるため、
/// 画面先頭の文字の抽出本文位置を併記して同じ文へ戻す。
final class TextAnchorLocatorTests: XCTestCase {
    func testLocatorCarriesAnchorThroughCoding() throws {
        let locator = EPUBLocator(spineIndex: 3, progression: 0.42,
                                  idref: "chap4", textOffset: 12_345)
        let data = try JSONEncoder().encode(locator)
        let decoded = try JSONDecoder().decode(EPUBLocator.self, from: data)
        XCTAssertEqual(decoded, locator)
        XCTAssertEqual(decoded.textOffset, 12_345)
    }

    /// アンカーを持たない旧い保存データはそのまま読める(進行率で復元する)
    func testOldSavedLocatorDecodesWithoutAnchor() throws {
        let json = Data("""
            {"spineIndex":2,"progression":0.5,"idref":"c3"}
            """.utf8)
        let decoded = try JSONDecoder().decode(EPUBLocator.self, from: json)
        XCTAssertEqual(decoded.spineIndex, 2)
        XCTAssertNil(decoded.textOffset)
    }

    /// 壊れた値(負数)はアンカー無しとして扱う
    func testNegativeAnchorIsIgnored() throws {
        let json = Data("""
            {"spineIndex":0,"progression":0,"textOffset":-5}
            """.utf8)
        XCTAssertNil(try JSONDecoder().decode(EPUBLocator.self, from: json).textOffset)
        XCTAssertNil(EPUBLocator(spineIndex: 0, textOffset: -1).textOffset)
    }

    /// アンカーは等価性に含まれる(別位置として保存できる)
    func testAnchorParticipatesInEquality() {
        let a = EPUBLocator(spineIndex: 1, progression: 0.5, textOffset: 10)
        let b = EPUBLocator(spineIndex: 1, progression: 0.5, textOffset: 99)
        let c = EPUBLocator(spineIndex: 1, progression: 0.5)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

/// 実際に本を開いて、画面先頭の位置が取れて同じ位置へ戻せることまで見る。
@MainActor
final class TextAnchorRoundTripTests: XCTestCase {
    func testAnchorIsCapturedAndRestoresToTheSamePlace() async throws {
        let body = (0..<300)
            .map { "<p>本文の段落 \($0) です。ここは読書位置の検証用の文章。</p>" }
            .joined()
        let publication = try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.singleSpineEntries(bodyHTML: body), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-anchor.epub"))
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
        XCTAssertGreaterThan(view.pageCountInItem, 1, "ページ割りが済んでいない")

        // 途中まで進めてからアンカー付きの位置を取る
        view.go(to: publication.locator(forSpineIndex: 0, progression: 0.5))
        try await Task.sleep(for: .milliseconds(400))
        let saved = await view.currentLocatorWithTextAnchor()
        let anchor = try XCTUnwrap(saved.textOffset, "アンカーを取得できていない")
        XCTAssertGreaterThan(anchor, 0)
        let savedPage = view.pageInItem

        // 先頭へ戻してから、保存した位置へ復元する
        view.go(to: publication.locator(forSpineIndex: 0, progression: 0))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(view.pageInItem, 0)

        view.go(to: saved)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(view.pageInItem, savedPage, "アンカーで同じページへ戻れていない")
    }
}
