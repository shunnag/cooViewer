import CoreGraphics
import XCTest
@testable import cooViewer

@MainActor
final class LibraryActionConcurrencyTests: XCTestCase {
    func testSpreadToggleDoesNotModifyBookReplacedDuringDecode() async throws {
        let source = LibraryActionSource()
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        let controller = ReaderWindowController(window: nil)
        controller.replaceBook(book)
        let action = try XCTUnwrap(controller.switchSingleSpread())
        await fulfillment(of: [source.paused], timeout: 2)
        // 保存対象を無くしてから再開する。実ユーザーの履歴には書き込まない。
        controller.replaceBook(nil)
        await source.resume()
        await action.value
        XCTAssertTrue(book.marks.legacyArray.isEmpty, "破棄済みの本へ操作を適用しない")
    }
}

private actor LibraryActionSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/library-action")
    nonisolated var supportsDateSort: Bool { false }
    nonisolated let paused = XCTestExpectation(description: "見開き判定の画像待機")
    private var continuation: CheckedContinuation<Void, Never>?

    func entries() async throws -> [PageEntry] {
        (0..<2).map {
            PageEntry(id: $0, name: "\($0).png", pathInBook: "\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        await withCheckedContinuation {
            continuation = $0
            paused.fulfill()
        }
        return CGContext(data: nil, width: 20, height: 40, bitsPerComponent: 8,
                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
