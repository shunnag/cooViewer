import CoreGraphics
import os
import XCTest

@testable import cooViewer

/// ページ寸法索引による見開き判定(デコードなし)のテスト。
/// 従来のデコード判定と同じスプレッドになること、後方めくり・巻末ジャンプが
/// デコードゼロで判定されること、表示キャップの動的更新を確認する。
@MainActor
final class PageSizeIndexTests: XCTestCase {
    private let portrait = CGSize(width: 70, height: 100)
    private let landscape = CGSize(width: 150, height: 100)

    /// imageSize を実装し、image() 呼び出し回数を数えるスタブ
    private final class SizedStubSource: BookSource, @unchecked Sendable {
        let url = URL(fileURLWithPath: "/stub/sized-book")
        let sizes: [CGSize]
        private let counter = OSAllocatedUnfairLock(initialState: 0)
        var loadCount: Int { counter.withLock { $0 } }

        var supportsDateSort: Bool { false }

        init(sizes: [CGSize]) {
            self.sizes = sizes
        }

        func entries() async throws -> [PageEntry] {
            sizes.indices.map { index in
                PageEntry(id: index, name: String(format: "p%03d.png", index),
                          pathInBook: String(format: "p%03d.png", index),
                          fileURL: nil, creationDate: nil, modificationDate: nil)
            }
        }

        func imageSize(for entry: PageEntry) async -> CGSize? {
            sizes[entry.id]
        }

        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            counter.withLock { $0 += 1 }
            var size = sizes[entry.id]
            if let cap = maxPixelSize {
                let scale = min(1, CGFloat(cap) / max(size.width, size.height))
                size = CGSize(width: size.width * scale, height: size.height * scale)
            }
            return try ImageDecoding.decode(
                TestFixtures.pngData(width: Int(size.width), height: Int(size.height)),
                maxPixelSize: nil)
        }
    }

    private func makeBook(_ sizes: [CGSize]) async throws -> Book {
        let book = try await Book.open(source: SizedStubSource(sizes: sizes))
        book.readMode = .rightToLeftSpread
        return book
    }

    /// サイズ索引によるスプレッドが従来判定(BookTests の各ケース)と一致すること
    func testSizeIndexSpreadsMatchDecodeBasedPairing() async throws {
        // 縦2枚 → 見開き
        var book = try await makeBook([portrait, portrait, portrait])
        var spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1])

        // 先頭が横長 → 単ページ
        book = try await makeBook([landscape, portrait, portrait])
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
        XCTAssertEqual(book.moveNext(), .moved)
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [1, 2])

        // 2 枚目が横長 → 単ページ
        book = try await makeBook([portrait, landscape, portrait])
        spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0])
    }

    /// 後方めくりの見開き判定がデコードなしで行われること
    func testBackwardTurnNeedsNoDecodes() async throws {
        let source = SizedStubSource(sizes: [portrait, portrait, portrait, portrait])
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSpread
        book.goTo(index: 3)
        let before = source.loadCount
        let result = await book.movePrevious()
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(book.currentIndex, 1, "見開き分(2 ページ)戻ること")
        XCTAssertEqual(source.loadCount, before,
                       "サイズ索引がある本の後方判定はデコードゼロ")
    }

    /// 巻末ジャンプの判定もデコードなし
    func testGoToLastNeedsNoDecodes() async throws {
        let source = SizedStubSource(sizes: [portrait, portrait, portrait, portrait])
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSpread
        let before = source.loadCount
        await book.goToLast()
        XCTAssertEqual(book.currentIndex, 2, "最終見開きの先頭へ")
        XCTAssertEqual(source.loadCount, before)
    }

    /// サイズが取れないソース(imageSize=nil)は従来のデコード判定へ
    func testFallsBackToDecodeWhenSizeUnavailable() async throws {
        let book = try await Book.open(source: StubSource(sizes: [portrait, portrait]))
        book.readMode = .rightToLeftSpread
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.indices, [0, 1], "従来経路でも見開きになること")
    }

    /// 表示キャップの動的更新: 上げるとキャッシュが破棄され高解像度で再デコード
    func testRaisingDisplayCapRedecodesLarger() async throws {
        let big = CGSize(width: 3000, height: 4500)
        let source = SizedStubSource(sizes: [big])
        let book = try await Book.open(source: source)
        book.displayPixelCap = 2048
        let small = await book.image(at: 0)
        XCTAssertEqual(small?.height, 2048)

        let raised = await book.updateDisplayPixelCap(4096)
        XCTAssertTrue(raised)
        let large = await book.image(at: 0)
        XCTAssertEqual(large?.height, 4096, "キャップ上昇後は高解像度で再デコード")

        // 下げてもキャッシュは維持(大きい画像をそのまま使う)
        let lowered = await book.updateDisplayPixelCap(2048)
        XCTAssertFalse(lowered)
        let kept = await book.image(at: 0)
        XCTAssertEqual(kept?.height, 4096)
    }

    /// キャップ決定の純関数
    func testDisplayCapPolicyBuckets() {
        // ウインドウ実寸を 1024 刻みで切り上げ、最低 2048・ユーザー上限まで
        XCTAssertEqual(DisplayCapPolicy.cap(
            windowLongEdgePixels: 2560, userCap: 4096, usesUserCap: false), 3072)
        XCTAssertEqual(DisplayCapPolicy.cap(
            windowLongEdgePixels: 1200, userCap: 4096, usesUserCap: false), 2048)
        XCTAssertEqual(DisplayCapPolicy.cap(
            windowLongEdgePixels: 6000, userCap: 4096, usesUserCap: false), 4096)
        // 原寸・fitWidth 系(ウインドウ外へ描くモード)はユーザー上限そのまま
        XCTAssertEqual(DisplayCapPolicy.cap(
            windowLongEdgePixels: 1200, userCap: 8192, usesUserCap: true), 8192)
        // ウインドウ不明時は従来既定(4096 とユーザー上限の小さい方)
        XCTAssertEqual(DisplayCapPolicy.cap(
            windowLongEdgePixels: 0, userCap: 8192, usesUserCap: false), 4096)
    }
}
