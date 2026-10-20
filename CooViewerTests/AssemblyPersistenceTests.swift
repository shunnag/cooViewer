import CoreGraphics
import XCTest
@testable import cooViewer

@MainActor
final class AssemblyPersistenceTests: XCTestCase {
    func testLegacyBookmarkPathIsFilledOnlyForCompleteBook() async throws {
        for exclusions in [0, 1] {
            let (controller, book, store, path) = try await prepare(exclusions: exclusions)
            book.bookmarks = [.init(name: "legacy", pageIndex: 1)]
            controller.saveCurrentBookState()
            let saved = try XCTUnwrap(store.settings(displayName: book.displayName, path: path)?.bookmarks.first)
            XCTAssertEqual(saved.pagePath, exclusions == 0 ? "1.png" : nil)
        }
    }

    func testAbsentLastPageIsKeptUntilNavigationAndOverwrittenAfterMoving() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1, savedPage: "missing.zip/4.png")
        let landed = book.currentIndex
        controller.saveCurrentBookState()
        var saved = try XCTUnwrap(store.savedPage(forPath: path, inRecents: true))
        XCTAssertEqual(saved.page, 7)
        XCTAssertEqual(saved.pagePath, "missing.zip/4.png")
        book.goTo(index: landed == 1 ? 2 : 1)
        controller.saveCurrentBookState()
        saved = try XCTUnwrap(store.savedPage(forPath: path, inRecents: true))
        XCTAssertEqual(saved.page, book.currentIndex)
        XCTAssertEqual(saved.pagePath, "\(book.currentIndex).png")
    }

    func testMovingAwayAndBackStillReplacesMissingStoredPage() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1, savedPage: "missing.zip/4.png")
        let landed = book.currentIndex
        book.goTo(index: landed == 1 ? 2 : 1)
        book.goTo(index: landed)
        controller.saveCurrentBookState()
        let state = try XCTUnwrap(store.savedPage(forPath: path, inRecents: true))
        XCTAssertEqual(state.page, landed)
        XCTAssertEqual(state.pagePath, "\(landed).png")
    }

    func testIncompleteRestoreKeepsLegacyBookmarkIndexOutsidePartialEntries() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1)
        let bookmark = PageBookmark(name: "legacy", pageIndex: 7)
        store.save(displayName: book.displayName, path: path,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(), bookmarks: [bookmark]))
        let persistence = await controller.restoreBookState(
            for: book, skipPageRestore: true, generation: controller.openGeneration)
        controller.replaceBook(book, persistence: persistence)
        controller.saveCurrentBookState()
        XCTAssertEqual(store.settings(displayName: book.displayName, path: path)?.bookmarks, [bookmark])
    }

    func testNewToggledBookmarkIsAnchoredWhileLegacyBookmarkStaysPathless() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1)
        let legacy = PageBookmark(name: "legacy", pageIndex: 0)
        book.bookmarks = [legacy]
        controller.toggleBookmark()
        let saved = try XCTUnwrap(store.settings(displayName: book.displayName, path: path)?.bookmarks)
        XCTAssertEqual(saved.first, legacy)
        XCTAssertEqual(saved.last?.pagePath, "1.png")
    }

    func testBookmarkEditorPreservesUnchangedAnchorsAndResolvesAddedOrChangedPages() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1)
        let legacy = PageBookmark(name: "legacy", pageIndex: 7)
        let anchored = PageBookmark(name: "anchored", pageIndex: 0, pagePath: "missing/old.png")
        let items = [
            BookmarkEditorView.Item(name: "renamed legacy", pageNumber: 8, original: legacy),
            BookmarkEditorView.Item(name: "renamed anchored", pageNumber: 1, original: anchored),
            BookmarkEditorView.Item(name: "added", pageNumber: 2),
            BookmarkEditorView.Item(name: "changed", pageNumber: 3, original: anchored)
        ]
        book.bookmarks = items.enumerated().map { offset, item in
            item.bookmark(offset: offset, pageCount: book.pageCount, bookIsComplete: false) {
                book.entries[$0].pathInBook
            }
        }
        controller.saveCurrentBookState()
        let saved = try XCTUnwrap(store.settings(displayName: book.displayName, path: path)?.bookmarks)
        XCTAssertEqual(saved[0].pageIndex, 7)
        XCTAssertNil(saved[0].pagePath)
        XCTAssertEqual(saved[1].pagePath, "missing/old.png")
        XCTAssertEqual(saved[2].pagePath, "1.png")
        XCTAssertEqual(saved[3].pagePath, "2.png")
    }

    func testReadModeAndMarkEditsWithoutNavigationKeepMissingAnchor() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1, savedPage: "missing.zip/4.png")
        let revision = book.explicitNavigationRevision
        book.readMode = .leftToRightSpread
        book.marks.setForcedSingle(book.currentIndex)
        controller.saveCurrentBookState()
        XCTAssertEqual(book.explicitNavigationRevision, revision)
        let saved = try XCTUnwrap(store.savedPage(forPath: path, inRecents: true))
        XCTAssertEqual(saved.page, 7)
        XCTAssertEqual(saved.pagePath, "missing.zip/4.png")
    }

    func testPreparedSnapshotDoesNotReplaceCurrentSnapshotBeforeAdoption() async throws {
        let (controller, current, store, path) = try await prepare(exclusions: 1, savedPage: "missing.zip/4.png")
        let other = try await Book.open(source: IncompleteBookSource(
            url: URL(fileURLWithPath: "/synthetic/other"), exclusions: 0))
        let snapshot = await controller.restoreBookState(
            for: other, skipPageRestore: true, generation: controller.openGeneration)
        XCTAssertEqual(controller.imageBookPersistence?.bookID, ObjectIdentifier(current))
        controller.openGeneration &+= 1
        controller.saveCurrentBookState()
        XCTAssertEqual(store.savedPage(forPath: path, inRecents: true)?.pagePath, "missing.zip/4.png")
        controller.replaceBook(nil)
        XCTAssertNil(controller.imageBookPersistence)
        controller.replaceBook(other)
        XCTAssertNil(controller.imageBookPersistence)
        controller.replaceBook(other, persistence: snapshot)
        XCTAssertEqual(controller.imageBookPersistence?.bookID, ObjectIdentifier(other))
    }

    func testCoverSingleReanchoringKeepsMissingAnchorUntilRealPageTurn() async throws {
        let (controller, book, store, path) = try await prepare(
            exclusions: 1, savedPage: "missing.zip/4.png", landedIndex: 2)
        book.readMode = .leftToRightSpread
        let landed = book.currentIndex
        book.coverSingleFirst = true
        let reanchored = await book.reanchorToLeadingPartition()
        XCTAssertTrue(reanchored)
        XCTAssertNotEqual(book.currentIndex, landed)
        controller.saveCurrentBookState()
        XCTAssertEqual(store.savedPage(forPath: path, inRecents: true)?.pagePath, "missing.zip/4.png")
        _ = book.moveNext()
        controller.saveCurrentBookState()
        XCTAssertEqual(store.savedPage(forPath: path, inRecents: true)?.pagePath, "\(book.currentIndex).png")
    }

    func testCancelledTentativeNavigationRestoresMissingAnchorProtection() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1, savedPage: "missing.zip/4.png")
        let origin = book.navigationCheckpoint
        _ = book.moveNext()
        XCTAssertTrue(book.restoreNavigation(origin, ifUnchanged: book.navigationCheckpoint))
        controller.saveCurrentBookState()
        XCTAssertEqual(store.savedPage(forPath: path, inRecents: true)?.pagePath, "missing.zip/4.png")
        _ = book.moveNext()
        controller.saveCurrentBookState()
        XCTAssertEqual(store.savedPage(forPath: path, inRecents: true)?.pagePath, "2.png")
    }

    func testSortResetKeepsMissingAnchorWithoutExplicitNavigation() async throws {
        let (controller, book, store, path) = try await prepare(exclusions: 1, savedPage: "missing.zip/4.png")
        let revision = book.explicitNavigationRevision
        _ = await book.setSortMode(.literalName).value
        XCTAssertEqual(book.currentIndex, 0)
        XCTAssertEqual(book.explicitNavigationRevision, revision)
        controller.saveCurrentBookState()
        XCTAssertEqual(store.savedPage(forPath: path, inRecents: true)?.pagePath, "missing.zip/4.png")
    }

    func testBookmarkEditorClampsKnownPositionsButPreservesIncompleteLegacyIndex() {
        for complete in [false, true] {
            for path in [nil, "missing/old.png"] as [String?] {
                let original = PageBookmark(name: "old", pageIndex: 7, pagePath: path)
                let item = BookmarkEditorView.Item(name: "renamed", pageNumber: 8, original: original)
                let saved = item.bookmark(offset: 0, pageCount: 3, bookIsComplete: complete) { "\($0).png" }
                XCTAssertEqual(saved.pageIndex, !complete && path == nil ? 7 : 2)
                XCTAssertEqual(saved.pagePath, path)
                let changed = BookmarkEditorView.Item(name: "changed", pageNumber: 99, original: original)
                    .bookmark(offset: 0, pageCount: 3, bookIsComplete: complete) { "\($0).png" }
                XCTAssertEqual(changed.pageIndex, 2)
                XCTAssertEqual(changed.pagePath, "2.png")
            }
        }
    }

    private func prepare(exclusions: Int, savedPage: String? = nil, landedIndex: Int = 1) async throws
        -> (ReaderWindowController, Book, BookHistoryStore, String) {
        let root = try TestFixtures.makeTempDir()
        let suite = "test.cooViewer.assembly-persistence.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "RememberBookSettings")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("collection")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = BookHistoryStore(defaults: defaults, directory: root.appendingPathComponent("states"))
        if let savedPage {
            store.saveImageBook(path: url.path, snapshot: .init(
                displayName: url.lastPathComponent, pageIndex: 7, pagePath: savedPage,
                settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(), bookmarks: [])))
        }
        let source = IncompleteBookSource(url: url, exclusions: exclusions)
        let book = try await Book.open(source: source)
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        book.readMode = .leftToRightSingle
        book.goTo(index: landedIndex)
        let controller = ReaderWindowController(window: nil, history: store)
        // 復帰確認 UI を避け、着地の保存保護だけを検証する(設計書 §7.4)。
        let persistence = await controller.restoreBookState(
            for: book, skipPageRestore: true, generation: controller.openGeneration)
        controller.replaceBook(book, persistence: persistence)
        return (controller, book, store, url.path)
    }
}

private struct IncompleteBookSource: BookSource {
    let url: URL
    let exclusions: Int
    let supportsDateSort = false
    func entries() async throws -> [PageEntry] {
        (0..<3).map { .init(id: $0, name: "\($0).png", pathInBook: "\($0).png",
                           fileURL: nil, creationDate: nil, modificationDate: nil) }
    }
    func excludedChildCount() async -> Int { exclusions }
    func imageSize(for entry: PageEntry) async -> CGSize? { CGSize(width: 70, height: 100) }
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        throw BookSourceError.pageLoadFailed(entry.name)
    }
}
