import CoreGraphics
import XCTest
@testable import cooViewer

/// 読み込みの完了順を制御し、待機中の設定変更と競合させる(設計書 §7.3)。
@MainActor
final class BookConcurrencyTests: XCTestCase {
    func testLoweringCapKeepsLargerDecodeAlreadyInProgress() async throws {
        let source = ControlledPageSource()
        let book = try await Book.open(source: source)
        _ = book.updateDisplayPixelCap(128)
        let load = Task { await book.image(at: 0) }
        let request = await source.nextRequest()

        _ = book.updateDisplayPixelCap(64)
        await source.finish(request)
        let large = await load.value
        XCTAssertEqual(large?.height, 128)
        XCTAssertEqual(book.pageCacheStats().count, 1,
                       "上限を下げた場合は進行中の大画像も捨てず、再デコードを避ける")
    }

    func testObsoleteDecodeCannotReplaceLargerCacheAfterCapRoundTrip() async throws {
        let source = ControlledPageSource()
        let book = try await Book.open(source: source)
        _ = book.updateDisplayPixelCap(64)
        let oldLoad = Task { await book.image(at: 0) }
        let oldRequest = await source.nextRequest()

        _ = book.updateDisplayPixelCap(128)
        let newLoad = Task { await book.image(at: 0) }
        let newRequest = await source.nextRequest()
        await source.finish(newRequest)
        let large = await newLoad.value
        XCTAssertEqual(large?.height, 128)

        // 上限を下げた後も、取得済みの大きな画像を維持する仕様。
        _ = book.updateDisplayPixelCap(64)
        await source.finish(oldRequest)
        let obsolete = await oldLoad.value
        XCTAssertEqual(obsolete?.height, 64)

        let cached = await book.image(at: 0)
        XCTAssertTrue(cached === large,
                      "上限の値が一周しても失効した旧読み込みを登録し直さない")
        XCTAssertEqual(cached?.height, 128)
    }
}

/// 画像要求を継続で止める。sleep に依存せず設定変更と完了の順を固定する。
private actor ControlledPageSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/controlled-book")
    nonisolated var supportsDateSort: Bool { false }

    struct Request: Sendable {
        let id: Int
        let entryID: Int
        let cap: Int?
    }

    private var nextID = 0
    private var queued: [Request] = []
    private var observers: [CheckedContinuation<Request, Never>] = []
    private var pending: [Int: CheckedContinuation<CGImage, any Error>] = [:]

    func entries() async throws -> [PageEntry] {
        [PageEntry(id: 0, name: "p0.png", pathInBook: "p0.png",
                   fileURL: nil, creationDate: nil, modificationDate: nil)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let request = Request(id: nextID, entryID: entry.id, cap: maxPixelSize)
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            if observers.isEmpty {
                queued.append(request)
            } else {
                observers.removeFirst().resume(returning: request)
            }
        }
    }

    func nextRequest() async -> Request {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { observers.append($0) }
    }

    func finish(_ request: Request) {
        let size = request.cap ?? 256
        let context = CGContext(data: nil, width: size / 2, height: size,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pending.removeValue(forKey: request.id)?.resume(returning: context.makeImage()!)
    }
}
