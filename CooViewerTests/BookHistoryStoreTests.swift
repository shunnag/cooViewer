import XCTest
@testable import cooViewer

@MainActor
final class BookHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: BookHistoryStore!
    private var tempDir: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "test.cooViewer.history")
        defaults.removePersistentDomain(forName: "test.cooViewer.history")
        defaults.set(10, forKey: "OpenRecentLimit")
        store = BookHistoryStore(defaults: defaults)
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: "test.cooViewer.history")
        try FileManager.default.removeItem(at: tempDir)
    }

    private func makeBookFile(_ name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    func testRecentItemsNewestFirstAndDeduplicated() throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        store.noteOpened(path: a)
        store.noteOpened(path: b)
        store.noteOpened(path: a)
        XCTAssertEqual(store.recentBookPaths(), [a, b])
    }

    func testSavedPageFromRecentAndLastPages() throws {
        let a = try makeBookFile("a.zip")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteOpened(path: a)
        store.noteClosed(path: a, pageIndex: 42)
        XCTAssertEqual(store.savedPage(forPath: a), 42)
        XCTAssertEqual(store.mostRecentBook()?.page, 42)
    }

    func testNoteOpenedPreservesSavedPageForRestore() throws {
        // 開き直しで履歴エントリを作り直しても保存ページを失わない
        // (最終ページ復元が読み出す前に消える回帰の防止。仕様書 §4.1.2 手順 7-8)
        let a = try makeBookFile("a.zip")
        store.noteClosed(path: a, pageIndex: 42)
        store.noteOpened(path: a)
        XCTAssertEqual(store.savedPage(forPath: a), 42)
        XCTAssertEqual(store.recentBookPaths(), [a])
    }

    func testPageZeroIsNotRemembered() throws {
        // page==0 は「復帰なし」と不可分(仕様書 §7.3)
        let a = try makeBookFile("a.zip")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosed(path: a, pageIndex: 0)
        XCTAssertNil(store.savedPage(forPath: a))
    }

    func testBookSettingsRoundTripWithLegacyBookmarkFormat() throws {
        let a = try makeBookFile("book.zip")
        let settings = BookHistoryStore.BookSettings(
            readMode: nil, sortMode: nil, marks: PageMarks(),
            bookmarks: [.init(name: "p5", pageIndex: 4)])
        store.save(displayName: "book.zip", path: a, settings: settings)

        // 保存形式は 1 始まり文字列(仕様書 §7.1)
        let raw = defaults.dictionary(forKey: "BookSettings") as? [String: [String: Any]]
        let bookmarks = raw?["book.zip"]?["bookmarks"] as? [[String: Any]]
        XCTAssertEqual(bookmarks?.first?["page"] as? String, "5")

        let loaded = store.settings(displayName: "book.zip", path: a)
        XCTAssertEqual(loaded?.bookmarks, [.init(name: "p5", pageIndex: 4)])
    }

    func testBookmarksSavedEvenWithoutRememberBookSettings() throws {
        // RememberBookSettings=NO でも bookmarks は保存(仕様書 §7.1)
        let a = try makeBookFile("book.zip")
        defaults.set(false, forKey: "RememberBookSettings")
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: .leftToRightSpread, sortMode: nil,
                                   marks: PageMarks(), bookmarks: [.init(name: "x", pageIndex: 1)]))
        let loaded = store.settings(displayName: "book.zip", path: a)
        XCTAssertEqual(loaded?.bookmarks.count, 1)
        XCTAssertNil(loaded?.readMode)  // remember=NO なので保存されない
    }

    func testEmptySettingsRemovesEntry() throws {
        let a = try makeBookFile("book.zip")
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: [.init(name: "x", pageIndex: 1)]))
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: []))
        let raw = defaults.dictionary(forKey: "BookSettings") ?? [:]
        XCTAssertTrue(raw.isEmpty)
    }
}
