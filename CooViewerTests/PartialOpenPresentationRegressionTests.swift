import CoreGraphics
import SwiftUI
import Washi
import XCTest
@testable import cooViewer

@MainActor
final class PartialOpenPresentationRegressionTests: XCTestCase {
    func testBookmarkEditorOKRefusesPartialEditsAndPreservesUnnormalizedStoredArrays() async throws {
        let suite = "test.cooViewer.partial-editor.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = try TestFixtures.makeTempDir()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(true, forKey: "RememberBookSettings")
        let source = PartialPresentationSource(indexed: true)
        let original = BookHistoryStore(defaults: defaults, directory: root)
        original.saveImageBook(path: source.url.path, snapshot: .init(displayName: "book", pageIndex: 88,
            pagePath: "2.png", settings: .init(readMode: .leftToRightSingle, sortMode: .name,
                marks: PageMarks(), bookmarks: [.init(name: "keep", pageIndex: 88, pagePath: "2.png")])))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "json" && $0.lastPathComponent != "recents.json" })
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        stored["marks"] = ["8", "2", "8", "invalid"]
        try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys]).write(to: file)
        func indexArrays(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["marks": object["marks"]!, "bookmarks": object["bookmarks"]!],
                options: [.sortedKeys])
        }
        let before = try indexArrays(stored)
        let store = BookHistoryStore(defaults: defaults, directory: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = ReaderWindowController(window: window, history: store)
        let book = try await Book.open(source: source)
        let persistence = await controller.restoreBookState(for: book, skipPageRestore: true,
            generation: controller.openGeneration)
        controller.replaceBook(book, persistence: persistence)
        defer {
            if let editor = controller.bookmarkEditorWindow { window.endSheet(editor) }
            controller.bookmarkEditorWindow = nil
            controller.replaceBook(nil)
            window.orderOut(nil)
        }
        let bookmarks = book.bookmarks
        controller.editBookmarks()
        let editor = try XCTUnwrap(controller.bookmarkEditorWindow?.contentViewController
            as? NSHostingController<BookmarkEditorView>)
        editor.rootView.onSave([.init(name: "overwritten", pageIndex: 0, pagePath: "0.png")])
        XCTAssertEqual(book.bookmarks, bookmarks)
        XCTAssertEqual(controller.lastReaderNotice,
            String(localized: "Bookmarks cannot be changed while volumes are missing"))
        book.goTo(index: 1)
        controller.saveCurrentBookState()
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(try indexArrays(after), before)
        XCTAssertEqual(after["lastPageIndex"] as? Int, 88)
        XCTAssertEqual(after["lastPagePath"] as? String, "2.png")
        XCTAssertTrue(book.marks.legacyArray.isEmpty)
    }

    func testPartialPositionRestoresByPathEvenWhenStoredIndexIsZero() async throws {
        let suite = "test.cooViewer.partial-position.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = try TestFixtures.makeTempDir()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(true, forKey: "RememberBookSettings")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        let shared = UserDefaults.standard
        let previous = shared.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["GoToLastPage"] = 1
        shared.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { shared.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let source = PartialPresentationSource(indexed: true)
        let store = BookHistoryStore(defaults: defaults, directory: root)
        let controller = ReaderWindowController(window: nil, history: store)
        let cases: [(Int, String?, Int)] = [(0, "2.png", 2), (99, "2.png", 2), (2, nil, 0)]
        for (storedIndex, storedPath, expected) in cases {
            store.saveImageBook(path: source.url.path, snapshot: .init(displayName: "book",
                pageIndex: storedIndex, pagePath: storedPath,
                settings: .init(readMode: .leftToRightSingle, sortMode: .name,
                    marks: PageMarks(), bookmarks: [])))
            let book = try await Book.open(source: source)
            _ = await controller.restoreBookState(for: book, skipPageRestore: false,
                generation: controller.openGeneration)
            XCTAssertEqual(book.currentIndex, expected)
            book.cancelPrefetch()
        }
    }

    func testNonPartialBookmarkNavigationRetainsOutOfRangeIndicesAndClampsAtJump() async throws {
        let source = StubSource(sizes: Array(repeating: CGSize(width: 2, height: 3), count: 3))
        let book = try await Book.open(source: source)
        book.bookmarks = [.init(name: "先", pageIndex: 100), .init(name: "前", pageIndex: -10)]
        XCTAssertEqual(book.resolvedBookmarkIndices, [100, -10])
        XCTAssertEqual(book.nextBookmarkIndex(), 100)
        book.goTo(index: try XCTUnwrap(book.nextBookmarkIndex()))
        XCTAssertEqual(book.currentIndex, 2)
        XCTAssertEqual(book.previousBookmarkIndex(), -10)
        book.goTo(index: try XCTUnwrap(book.previousBookmarkIndex()))
        XCTAssertEqual(book.currentIndex, 0)
        book.cancelPrefetch()
    }

    func testCardedPathRestoreConfirmsResolvedIndexAndPreservesStoredRecord() async throws {
        let suite = "test.cooViewer.partial-card-anchor.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = try TestFixtures.makeTempDir()
        let shared = UserDefaults.standard
        let previous = shared.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            shared.setVolatileDomain(previous, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        shared.setVolatileDomain(previous.merging(["GoToLastPage": 0]) { _, new in new },
                                 forName: UserDefaults.argumentDomain)
        let source = PartialPresentationSource(indexed: true)
        let store = BookHistoryStore(defaults: defaults, directory: directory)
        store.noteOpened(path: source.url.path)
        for anchor in [nil, "sub/volume.zip/010.png"] as [String?] {
            store.noteClosed(path: source.url.path, pageIndex: 103, pagePath: anchor)
            let controller = ReaderWindowController(window: nil, history: store)
            let book = try await Book.open(source: source)
            var confirmations: [Int] = []
            controller.confirmLastPageRestore = { confirmations.append($0); return true }
            let snapshot = await controller.restoreBookState(for: book, skipPageRestore: false,
                                                            generation: controller.openGeneration)
            controller.replaceBook(book, persistence: snapshot)
            XCTAssertEqual(confirmations, anchor == nil ? [] : [1])
            XCTAssertEqual(book.currentIndex, anchor == nil ? 0 : 1)
            controller.saveCurrentBookState()
            let saved = try XCTUnwrap(store.savedPage(forPath: source.url.path, inRecents: true))
            XCTAssertEqual(saved.page, 103)
            XCTAssertEqual(saved.pagePath, anchor)
            controller.replaceBook(nil)
            book.cancelPrefetch()
        }
    }

    func testMissingVolumeSuffixIsInsidePageLabelPadding() async throws {
        let controller = ReaderWindowController(window: nil)
        let book = try await Book.open(source: PartialPresentationSource(indexed: true))
        controller.replaceBook(book)
        defer { controller.replaceBook(nil); book.cancelPrefetch() }
        controller.updatePageIndicators(indices: [1])
        XCTAssertTrue(controller.pageLabel.stringValue.hasSuffix(book.incompleteSuffix + " "))
        XCTAssertFalse(controller.pageLabel.stringValue.hasSuffix(" " + book.incompleteSuffix))
        let marker = try XCTUnwrap(book.entries[1].unreadableVolume)
        let guidance = try XCTUnwrap(marker.message.components(separatedBy: "\n\n").last)
        XCTAssertEqual(guidance.components(separatedBy: "\n").count, 2)
    }

    func testUnresolvedBookmarkMenuUsesMissingVolumeLabelAndValidation() async throws {
        let controller = ReaderWindowController(window: nil)
        let book = try await Book.open(source: PartialPresentationSource(indexed: true))
        book.bookmarks = [.init(name: "失った位置", pageIndex: -1, pagePath: "gone.zip/page.png"),
                          .init(name: "残った位置", pageIndex: 2, pagePath: "2.png")]
        controller.replaceBook(book)
        defer { book.cancelPrefetch(); controller.replaceBook(nil) }
        let menu = NSMenu()
        let delegate = BookmarkListMenuDelegate(controller: controller)
        delegate.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items[0].title, "失った位置  " + String(localized: "(Missing volume)"))
        XCTAssertNil(menu.items[0].representedObject)
        XCTAssertFalse(controller.validateMenuItem(menu.items[0]))
        XCTAssertTrue(controller.validateMenuItem(menu.items[1]))
    }

    func testCollectionThumbnailPlanKeepsCardsStandaloneWithoutChangingReflowPairing() async throws {
        let original = try await PartialPresentationSource(indexed: true).entries()
        let metrics = EPUBScreenMetrics(viewportSize: CGSize(width: 1400, height: 900), settings: EPUBReaderSettings())
        let plan = CollectionThumbnailPlan.make(bookEntries: original, counts: [3: [4]],
            perBookPagesPerScreen: [3: 2], metrics: metrics, isDark: false)
        XCTAssertEqual(plan.entries[1].unreadableVolume, original[1].unreadableVolume)
        XCTAssertEqual(plan.targets[1], .bookPage(index: 1))
        let model = ThumbnailOverlayModel()
        model.present(snapshot: .init(entries: plan.entries))
        defer { model.clear() }
        XCTAssertEqual(model.knownLargePages, [1])
        XCTAssertTrue(plan.entries.dropFirst(3).allSatisfy { $0.unreadableVolume == nil })
    }

    func testCardsAndReflowPlaceholdersStayStandaloneAcrossNavigation() async throws {
        for indexed in [false, true] {
            let source = PartialPresentationSource(indexed: indexed)
            let book = try await Book.open(source: source)
            book.readMode = .leftToRightSpread
            book.marks.setForcedPair(firstIndex: 0)
            book.marks.setForcedPair(firstIndex: 2)
            for index in book.entries.indices {
                book.goTo(index: index)
                let spread = await book.currentSpread()
                XCTAssertEqual(spread.indices, [index])
                let predicted = await book.predictedAdjacentSpreads(forward: true, maxPages: 4)
                XCTAssertTrue(predicted.allSatisfy { $0.count == 1 })
            }
            book.goTo(index: 2)
            let reanchored = await book.reanchorToLeadingPartition()
            XCTAssertTrue(reanchored)
            XCTAssertEqual(book.currentIndex, 2)
            let movedToLast = await book.goToLast()
            XCTAssertTrue(movedToLast)
            XCTAssertEqual(book.currentIndex, 3)
            _ = await book.movePrevious()
            XCTAssertEqual(book.currentIndex, 2)
            book.cancelPrefetch()
        }
    }

    func testCardsDoNotAcquireEPUBCensusSemantics() async throws {
        let entries = try await PartialPresentationSource(indexed: true).entries()
        let map = CollectionPageMap.make(folderPath: "/synthetic", metricsKey: "test",
            entries: entries, counts: [1: [99], 3: [2, 3]])
        XCTAssertEqual(map.total, 8)
        XCTAssertTrue(map.isComplete)
        XCTAssertEqual(map.target(forGlobalPage: 1), .bookPage(index: 1))
        XCTAssertEqual(map.pageCount(forEntry: 1), 1)
        XCTAssertNil(map.segments[1].epubURL)
        XCTAssertEqual(map.pageCount(forEntry: 3), 5)
    }

    func testThumbnailComicModeKeepsCardAsItsOwnJumpTarget() async throws {
        let suite = "test.cooViewer.partial-presentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ThumbnailComicMode")
        let model = ThumbnailOverlayModel(defaults: defaults)
        let entries = try await PartialPresentationSource(indexed: true).entries()
        model.present(snapshot: .init(entries: entries))
        defer { model.clear() }
        XCTAssertTrue(model.knownLargePages.contains(1))
        XCTAssertFalse(model.knownLargePages.contains(3))
        XCTAssertEqual(model.layout.cellGroups, [[0], [1], [2, 3]])
    }
}

private struct PartialPresentationSource: BookSource {
    let url = URL(fileURLWithPath: "/synthetic/partial-presentation")
    let indexed: Bool
    var supportsDateSort: Bool { false }

    func entries() async throws -> [PageEntry] {
        (0..<4).map { index in
            PageEntry(id: index, name: "\(index).png", pathInBook: "\(index).png",
                fileURL: nil, creationDate: nil, modificationDate: nil,
                reflowEPUBURL: index == 3 ? url.appendingPathComponent("text.epub") : nil,
                unreadableVolume: index == 1
                    ? .init(relativePath: "sub/volume.zip", cause: .accessDenied) : nil)
        }
    }

    func imageSize(for entry: PageEntry) async -> CGSize? {
        indexed ? CGSize(width: 2, height: 3) : nil
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try ImageDecoding.decode(TestFixtures.pngData(width: 2, height: 3), maxPixelSize: nil)
    }
}
