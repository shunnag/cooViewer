import AppKit
import XCTest
@testable import cooViewer

@MainActor
final class OpenFlowConcurrencyTests: XCTestCase {
    func testCloseDuringUnlockDoesNotInstallLatePlaceholder() async throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source.url) }
        let controller = makeController(source: source)
        let opening = controller.openBook(at: source.url)
        await fulfillment(of: [source.paused], timeout: 2)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await source.resume()
        await opening.value
        XCTAssertNil(controller.book, "閉窓後に旧解除結果の本を確定しない")
        XCTAssertFalse(controller.isOpeningBook)
    }

    func testLaterOpenIsNotReplacedByEarlierUnlockCancellation() async throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source.url) }
        let controller = makeController(source: source)
        let opening = controller.openBook(at: source.url)
        await fulfillment(of: [source.paused], timeout: 2)
        let replacement = Book(source: source, entries: [])
        controller.replaceBook(replacement)
        // 存在しないパスの新要求を最後にする。履歴への保存やダイアログは起きない。
        let missing = source.url.appendingPathExtension("missing")
        await controller.openBook(at: missing).value
        await source.resume()
        await opening.value
        XCTAssertTrue(controller.book === replacement, "旧フローの取消表示で新要求を上書きしない")
    }

    func testCloseBeforeOpeningTaskStartsPreventsSourceAccess() async throws {
        let source = try makeSource(pauses: false)
        defer { try? FileManager.default.removeItem(at: source.url) }
        let controller = makeController(source: source)
        let opening = controller.openBook(at: source.url)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await opening.value
        let checks = await source.encryptionChecks
        XCTAssertEqual(checks, 0, "まだ走っていない要求も閉窓で失効する")
        XCTAssertNil(controller.book)
    }

    private func makeSource(pauses: Bool = true) throws -> OpeningBookSource {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooviewer-open-review-\(UUID()).zip")
        try Data().write(to: url)
        return OpeningBookSource(url: url, pauses: pauses)
    }

    private func makeController(source: OpeningBookSource) -> ReaderWindowController {
        let controller = ReaderWindowController(window: nil)
        controller.preparedNextBook = (
            source.url.path, source, controller.settings.effectiveArchiveEngine)
        return controller
    }
}

private actor OpeningBookSource: BookSource {
    nonisolated let url: URL
    nonisolated var supportsDateSort: Bool { false }
    nonisolated let paused = XCTestExpectation(description: "解除判定の暗号化状態を停止")
    private let pauses: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var encryptionChecks = 0

    init(url: URL, pauses: Bool) {
        self.url = url
        self.pauses = pauses
    }

    func entries() async throws -> [PageEntry] { [] }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        throw BookSourceError.unreadable(url)
    }

    func isEncrypted() async -> Bool {
        encryptionChecks += 1
        if pauses && encryptionChecks == 2 {
            await withCheckedContinuation {
                continuation = $0
                paused.fulfill()
            }
        }
        // XCTest の既存抑止経路により、パスワード UI は出ず取消扱いになる。
        return true
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
