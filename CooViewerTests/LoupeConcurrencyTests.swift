import AppKit
import XCTest
@testable import cooViewer

@MainActor
final class LoupeConcurrencyTests: XCTestCase {
    func testOldBookCannotReplaceNewBooksLoupeWithSamePageID() async throws {
        let source = LoupeBookSource(pausesFirst: true)
        let book = try await makeBook(source)
        let controller = ReaderWindowController(window: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = controller.readerViewForInput
        window.contentView = view
        controller.replaceBook(book)
        try await show(book, in: view)
        let oldRequest = try XCTUnwrap(controller.requestLoupeHighResolution())
        await fulfillment(of: [source.paused], timeout: 2)

        let nextBook = try await makeBook(LoupeBookSource(pausesFirst: false, height: 2))
        controller.replaceBook(nextBook)
        try await show(nextBook, in: view)
        await controller.requestLoupeHighResolution()?.value
        XCTAssertEqual(loupeImageHeights(in: view), [2])
        await source.resume()
        await oldRequest.value
        XCTAssertEqual(loupeImageHeights(in: view), [2], "ソース内 ID が同じでも別の本")
        view.disableLoupe()
        window.contentView = nil
    }

    func testLaterRequestWinsWhenEarlierDecodeFinishesLast() async throws {
        let source = LoupeBookSource(pausesFirst: true)
        let book = try await makeBook(source)
        let controller = ReaderWindowController(window: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = controller.readerViewForInput
        window.contentView = view
        controller.replaceBook(book)
        try await show(book, in: view)
        let first = try XCTUnwrap(controller.requestLoupeHighResolution())
        await fulfillment(of: [source.paused], timeout: 2)
        await controller.requestLoupeHighResolution()?.value
        XCTAssertEqual(loupeImageHeights(in: view), [2])
        await source.resume()
        await first.value
        XCTAssertEqual(loupeImageHeights(in: view), [2], "古い倍率の要求を後から反映しない")
        view.disableLoupe()
        window.contentView = nil
    }

    private func makeBook(_ source: LoupeBookSource) async throws -> Book {
        let book = try await Book.open(source: source)
        book.readMode = .rightToLeftSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        return book
    }

    private func show(_ book: Book, in view: ReaderView) async throws {
        let image = await book.image(at: 0)
        view.setPages([try XCTUnwrap(image)], ids: [0], readsFromLeft: false)
        view.enableLoupe(size: 16, rate: 1)
        XCTAssertTrue(view.isLoupeEnabled)
    }

    /// 公開済みのレイヤーツリーから実際にルーペへ貼られた画像を調べる。
    private func loupeImageHeights(in view: ReaderView) -> [Int] {
        func images(in layer: CALayer) -> [Int] {
            var heights: [Int] = []
            if let contents = layer.contents,
               CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
                let image = contents as! CGImage
                if image.width == 8192 { heights.append(image.height) }
            }
            for child in layer.sublayers ?? [] { heights += images(in: child) }
            return heights
        }
        return view.layer.map(images(in:)) ?? []
    }
}

private actor LoupeBookSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/loupe-\(UUID())")
    nonisolated var supportsDateSort: Bool { false }
    nonisolated let paused = XCTestExpectation(description: "ルーペ画像の取得を停止")
    private let pausesFirst: Bool
    private let height: Int
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(pausesFirst: Bool, height: Int = 1) {
        self.pausesFirst = pausesFirst
        self.height = height
    }

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "p.png", pathInBook: "p.png", fileURL: nil,
                   creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        makeImage(width: 2, height: 4)
    }

    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        calls += 1
        let request = calls
        if pausesFirst && request == 1 {
            await withCheckedContinuation {
                continuation = $0
                paused.fulfill()
            }
        }
        // 目標長辺の上限を満たすので、設定によらず超解像やディスク保存は起こさない。
        return makeImage(width: 8192, height: height + request - 1)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func makeImage(width: Int, height: Int) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}
