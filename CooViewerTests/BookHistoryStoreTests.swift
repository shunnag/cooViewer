import XCTest

@testable import cooViewer

/// 本ごとの状態ストア v2(1 冊 = 1 JSON + recents.json)のテスト。
/// 旧仕様(§7)の挙動互換と、旧形式からの一括インポート変換を確認する。
@MainActor
final class BookHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: BookHistoryStore!
    private var tempDir: URL!
    private var stateDir: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "test.cooViewer.history")
        defaults.removePersistentDomain(forName: "test.cooViewer.history")
        defaults.set(10, forKey: "OpenRecentLimit")
        tempDir = try TestFixtures.makeTempDir()
        stateDir = tempDir.appendingPathComponent("BookStates")
        store = BookHistoryStore(defaults: defaults, directory: stateDir)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: "test.cooViewer.history")
        try FileManager.default.removeItem(at: tempDir)
    }

    private func makeBookFile(_ name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.resolvingSymlinksInPath().path
    }

    // MARK: - 挙動互換(§7)

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
        XCTAssertEqual(store.savedPage(forPath: a)?.page, 42)
        XCTAssertEqual(store.mostRecentBook()?.page, 42)
    }

    func testNoteOpenedPreservesSavedPageForRestore() throws {
        // 開き直しで履歴を作り直しても保存ページを失わない(仕様書 §4.1.2 手順 7-8)
        let a = try makeBookFile("a.zip")
        store.noteClosed(path: a, pageIndex: 42)
        store.noteOpened(path: a)
        XCTAssertEqual(store.savedPage(forPath: a)?.page, 42)
        XCTAssertEqual(store.recentBookPaths(), [a])
    }

    func testPagePathRoundTripsWithSavedPage() throws {
        let a = try makeBookFile("a.zip")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosed(path: a, pageIndex: 42, pagePath: "inner.zip/p043.png")
        let saved = store.savedPage(forPath: a)
        XCTAssertEqual(saved?.page, 42)
        XCTAssertEqual(saved?.pagePath, "inner.zip/p043.png")
        store.noteOpened(path: a)
        XCTAssertEqual(store.savedPage(forPath: a)?.pagePath, "inner.zip/p043.png")
    }

    func testPageZeroIsNotRemembered() throws {
        // page==0 は「復帰なし」と不可分(仕様書 §7.3)
        let a = try makeBookFile("a.zip")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosed(path: a, pageIndex: 0)
        XCTAssertNil(store.savedPage(forPath: a)?.page)
    }

    func testEvictedBookRestoreFollowsFlagAtCloseTime() throws {
        // 一覧から外れた本の復元可否は「閉じた時点」の AlwaysRememberLastPage で
        // 決まる(旧 LastPages の write-time 意味論 §7.3)。後から切り替えても
        // 過去の記録の扱いは変わらない
        defaults.set(1, forKey: "OpenRecentLimit")
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        let c = try makeBookFile("c.zip")

        // OFF のまま閉じた a: 後から ON にしても復元されない
        store.noteClosed(path: a, pageIndex: 42)
        store.noteOpened(path: c)  // a が一覧から外れる(limit 1)
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        XCTAssertNil(store.savedPage(forPath: a))

        // ON で閉じた b: 後から OFF にしても復元される
        store.noteClosed(path: b, pageIndex: 7)
        store.noteOpened(path: c)  // b が一覧から外れる
        defaults.set(false, forKey: "AlwaysRememberLastPage")
        XCTAssertEqual(store.savedPage(forPath: b)?.page, 7)
    }

    func testRecentsSkipDeletedBooks() throws {
        // 消えた本は一覧・最後の本から飛ばす(旧 §7.2)。一覧自体は保持し、
        // ドライブ再接続などで実体が戻れば再び現れる
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        store.noteOpened(path: b)
        store.noteOpened(path: a)  // a が最新
        try FileManager.default.removeItem(atPath: a)
        XCTAssertEqual(store.recentBookPaths(), [b])
        XCTAssertEqual(store.mostRecentBook()?.path, b,
                       "消えた本を飛ばして次の実在する本へ")
        try Data("x".utf8).write(to: URL(fileURLWithPath: a))  // 復活
        XCTAssertEqual(store.recentBookPaths(), [a, b])
    }

    func testRelocationFollowsMovedBook() throws {
        // 本を移動しても URL ブックマークで状態を追跡し、一覧も付け替える
        let a = try makeBookFile("moved.zip")
        store.noteClosed(path: a, pageIndex: 5)
        store.save(displayName: "moved.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: [.init(name: "x", pageIndex: 2)]))
        let newDir = tempDir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newPath = newDir.appendingPathComponent("moved.zip")
            .resolvingSymlinksInPath().path
        try FileManager.default.moveItem(atPath: a, toPath: newPath)

        // 新しいストアインスタンス(メモリキャッシュなし)で新パスを参照
        let fresh = BookHistoryStore(defaults: defaults, directory: stateDir)
        let settings = fresh.settings(displayName: "moved.zip", path: newPath)
        XCTAssertEqual(settings?.bookmarks.first?.pageIndex, 2, "状態が追跡されること")
        XCTAssertEqual(fresh.recentBookPaths(), [newPath], "一覧も付け替わること")
        XCTAssertEqual(fresh.savedPage(forPath: newPath)?.page, 5)
    }

    func testReconciledIndexFollowsPagePath() {
        func entry(_ path: String) -> PageEntry {
            PageEntry(id: 0, name: (path as NSString).lastPathComponent,
                      pathInBook: path, fileURL: nil,
                      creationDate: nil, modificationDate: nil)
        }
        let entries = [entry("a.png"), entry("b.png"), entry("c.png")]
        XCTAssertEqual(BookHistoryStore.reconciledIndex(
            saved: 1, pagePath: "b.png", entries: entries), 1)
        XCTAssertEqual(BookHistoryStore.reconciledIndex(
            saved: 2, pagePath: "b.png", entries: entries), 1)
        XCTAssertEqual(BookHistoryStore.reconciledIndex(
            saved: 2, pagePath: "gone.png", entries: entries), 2)
        XCTAssertEqual(BookHistoryStore.reconciledIndex(
            saved: 2, pagePath: nil, entries: entries), 2)
    }

    func testBookmarksRoundTrip() throws {
        let a = try makeBookFile("book.zip")
        let settings = BookHistoryStore.BookSettings(
            readMode: nil, sortMode: nil, marks: PageMarks(),
            bookmarks: [.init(name: "p5", pageIndex: 4, pagePath: "ch1/p005.png")])
        store.save(displayName: "book.zip", path: a, settings: settings)
        let loaded = store.settings(displayName: "book.zip", path: a)
        XCTAssertEqual(loaded?.bookmarks,
                       [.init(name: "p5", pageIndex: 4, pagePath: "ch1/p005.png")])
    }

    func testBookmarksSavedEvenWithoutRememberBookSettings() throws {
        // RememberBookSettings=NO でも bookmarks は保存(仕様書 §7.1)
        let a = try makeBookFile("book.zip")
        defaults.set(false, forKey: "RememberBookSettings")
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: .leftToRightSpread, sortMode: nil,
                                   marks: PageMarks(),
                                   bookmarks: [.init(name: "x", pageIndex: 1)]))
        let loaded = store.settings(displayName: "book.zip", path: a)
        XCTAssertEqual(loaded?.bookmarks.count, 1)
        XCTAssertNil(loaded?.readMode)  // remember=NO なので保存されない
    }

    func testRememberBookSettingsPersistsModes() throws {
        let a = try makeBookFile("book.zip")
        defaults.set(true, forKey: "RememberBookSettings")
        var marks = PageMarks()
        marks.setForcedSingle(2)
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: .leftToRightSpread, sortMode: .shuffle,
                                   marks: marks, bookmarks: []))
        let loaded = store.settings(displayName: "book.zip", path: a)
        XCTAssertEqual(loaded?.readMode, .leftToRightSpread)
        XCTAssertEqual(loaded?.sortMode, .shuffle)
        XCTAssertEqual(loaded?.marks.legacyArray, ["3"])
    }

    func testEmptySettingsRemovesStateFile() throws {
        let a = try makeBookFile("book.zip")
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: [.init(name: "x", pageIndex: 1)]))
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: []))
        XCTAssertNil(store.settings(displayName: "book.zip", path: a))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(files.filter { $0.lastPathComponent != "recents.json" }.isEmpty,
                      "実内容が空になった状態ファイルは消えること")
    }

    func testStatePersistsAcrossStoreInstances() throws {
        // メモリキャッシュではなくファイルに永続化されていること
        let a = try makeBookFile("book.zip")
        store.noteClosed(path: a, pageIndex: 7)
        store.save(displayName: "book.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: [.init(name: "b", pageIndex: 3)]))
        let fresh = BookHistoryStore(defaults: defaults, directory: stateDir)
        XCTAssertEqual(fresh.savedPage(forPath: a)?.page, 7)
        XCTAssertEqual(fresh.settings(displayName: "book.zip", path: a)?
            .bookmarks.first?.pageIndex, 3)
    }

    // MARK: - 旧形式からの一括インポート(§13.5 v2)

    func testMigrationConvertsLegacyData() throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        // 旧 BookSettings: しおりは 1 始まり文字列、readMode/marks 付き
        defaults.set([
            "a.zip": [
                "temppath": a,
                "readMode": 2,
                "sortMode": 0,
                "marks": ["3", "5-6"],
                "bookmarks": [
                    ["name": "章 1", "page": "5", "path": "ch1/p005.png"],
                    ["name": "章 2", "page": "12"],
                ],
            ],
        ], forKey: "BookSettings")
        // 旧 LastPages(0 始まり)と RecentItems(先頭最新。page は Recents 優先)
        defaults.set([["temppath": a, "page": 10, "pagepath": "ch1/p011.png"]],
                     forKey: "LastPages")
        defaults.set([
            ["temppath": b, "page": 3],
            ["temppath": a, "page": 20],
        ], forKey: "RecentItems")

        store.migrateLegacyDataIfNeeded()

        // しおり: 1 始まり文字列 → 0 始まり Int
        let settings = store.settings(displayName: "a.zip", path: a)
        XCTAssertEqual(settings?.bookmarks, [
            .init(name: "章 1", pageIndex: 4, pagePath: "ch1/p005.png"),
            .init(name: "章 2", pageIndex: 11),
        ])
        XCTAssertEqual(settings?.readMode, ReadMode(rawValue: 2))
        XCTAssertEqual(settings?.marks.legacyArray, ["3", "5-6"])
        // 保存ページ: RecentItems の値が LastPages を上書き(旧探索順の再現)
        XCTAssertEqual(store.savedPage(forPath: a)?.page, 20)
        XCTAssertEqual(store.savedPage(forPath: b)?.page, 3)
        // 最近の一覧の並びを維持
        XCTAssertEqual(store.recentBookPaths(), [b, a])
        // 旧キーは凍結保持(1.x 用に消さない)
        XCTAssertNotNil(defaults.dictionary(forKey: "BookSettings"))
        XCTAssertNotNil(defaults.array(forKey: "RecentItems"))
    }

    func testMigrationRunsOnlyOnce() throws {
        let a = try makeBookFile("a.zip")
        defaults.set([["temppath": a, "page": 5]], forKey: "RecentItems")
        store.migrateLegacyDataIfNeeded()
        XCTAssertEqual(store.savedPage(forPath: a)?.page, 5)

        // 2 回目は旧データを読み直さない(新ストアの値が上書きされない)
        store.noteClosed(path: a, pageIndex: 9)
        store.migrateLegacyDataIfNeeded()
        XCTAssertEqual(store.savedPage(forPath: a)?.page, 9)
    }

    func testMigrationMergesDuplicatePathEntriesDeterministically() throws {
        // 同じパスへ解決する複数キーはフィールド単位でマージし、
        // しおりのない後発エントリがしおりを消さないこと
        let a = try makeBookFile("dup.zip")
        defaults.set([
            "dup.zip": [
                "temppath": a,
                "bookmarks": [["name": "keep", "page": "3"]],
            ],
            "dup.zip#2": [
                "temppath": a,
                "readMode": 1,
            ],
        ], forKey: "BookSettings")
        store.migrateLegacyDataIfNeeded()
        let settings = store.settings(displayName: "dup.zip", path: a)
        XCTAssertEqual(settings?.bookmarks, [.init(name: "keep", pageIndex: 2)],
                       "しおりが空エントリに上書きされないこと")
        XCTAssertEqual(settings?.readMode, ReadMode(rawValue: 1))
    }

    func testMigrationDeduplicatesDuplicateRecentPaths() throws {
        // 壊れた RecentItems が同一パスへ collapse しても(例: 全件 temppath='null.rar')
        // recents とページ状態に重複を残さず、最初=最新のエントリを採用する(cooViewer-0pk)
        let a = try makeBookFile("dup-recent.zip")
        defaults.set([
            ["temppath": a, "page": 20],   // offset 0 = 最新
            ["temppath": a, "page": 5],
            ["temppath": a, "page": 8],
        ], forKey: "RecentItems")
        store.migrateLegacyDataIfNeeded()
        // 一覧は 1 件へ集約(重複しない)
        XCTAssertEqual(store.recentBookPaths(), [a])
        // ページは最初=最新の 20(以前は最後=最古が上書きしていた)
        XCTAssertEqual(store.savedPage(forPath: a)?.page, 20)
    }

    func testMigrationImportsLastPagesAsRememberedBeyondRecents() throws {
        // LastPages にある=閉じた時点で AlwaysRememberLastPage が ON だった本。
        // 一覧に載っていなくてもグローバル設定に関係なく復元できること
        let a = try makeBookFile("old.zip")
        defaults.set([["temppath": a, "page": 15]], forKey: "LastPages")
        store.migrateLegacyDataIfNeeded()
        defaults.set(false, forKey: "AlwaysRememberLastPage")
        XCTAssertEqual(store.savedPage(forPath: a)?.page, 15)
    }

    func testMigrationHandlesDisplayNameCollisionSuffix() throws {
        let a = try makeBookFile("same.zip")
        defaults.set([
            "same.zip#2": [
                "temppath": a,
                "bookmarks": [["name": "x", "page": "2"]],
            ],
        ], forKey: "BookSettings")
        store.migrateLegacyDataIfNeeded()
        XCTAssertEqual(store.settings(displayName: "same.zip", path: a)?
            .bookmarks, [.init(name: "x", pageIndex: 1)])
    }

    // MARK: - 一過性の読み取り失敗で状態を潰さない(cooViewer-iuj)

    /// stateDir 内の非 recents 状態ファイル URL(private stateURL を避ける)
    private func stateFileURL() throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil)
        return try XCTUnwrap(files.first { $0.pathExtension == "json"
            && $0.lastPathComponent != "recents.json" })
    }

    func testUnreadableStateFileIsNotOverwrittenOnClose() throws {
        let a = try makeBookFile("a.zip")
        store.save(displayName: "a.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: [.init(name: "mark", pageIndex: 5)]))
        let url = try stateFileURL()
        let garbage = Data("garbage".utf8)
        try garbage.write(to: url)
        // 別ストア(=別プロセス相当。読みキャッシュ前)で在るのに読めない状態を再現
        let fresh = BookHistoryStore(defaults: defaults, directory: stateDir)
        fresh.noteClosed(path: a, pageIndex: 0)  // 旧なら isEmpty で削除
        fresh.save(displayName: "a.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: []))  // 旧なら空で上書き
        // ファイルは存在し、中身は garbage のまま(削除も上書きもされない)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testUnreadableStateFileSelfHealsForReads() throws {
        let a = try makeBookFile("a.zip")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosed(path: a, pageIndex: 42)
        let url = try stateFileURL()
        let good = try Data(contentsOf: url)
        // 破損 → 読めないので settings/savedPage は nil(復元しない=安全側)
        let fresh = BookHistoryStore(defaults: defaults, directory: stateDir)
        try Data("garbage".utf8).write(to: url)
        XCTAssertNil(fresh.savedPage(forPath: a))
        // 正バイト復旧 → 別ストアで読み直せる(unreadable を負キャッシュしない)
        try good.write(to: url)
        let healed = BookHistoryStore(defaults: defaults, directory: stateDir)
        XCTAssertEqual(healed.savedPage(forPath: a)?.page, 42)
    }

    func testUnreadableThenRecoveredStillSuppressesWrite() throws {
        let a = try makeBookFile("a.zip")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosed(path: a, pageIndex: 42)
        let url = try stateFileURL()
        let good = try Data(contentsOf: url)
        let fresh = BookHistoryStore(defaults: defaults, directory: stateDir)
        try Data("garbage".utf8).write(to: url)
        _ = fresh.savedPage(forPath: a)   // 読み → unreadableObserved に記録
        try good.write(to: url)           // 回復
        fresh.noteClosed(path: a, pageIndex: 3)  // 同セッションは書込抑止継続
        // 別ストアで読むと元の 42 のまま(回復後もその session は書かない)
        let other = BookHistoryStore(defaults: defaults, directory: stateDir)
        XCTAssertEqual(other.savedPage(forPath: a)?.page, 42)
    }

    func testStateVersionMismatchIsNotOverwritten() throws {
        let a = try makeBookFile("a.zip")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosed(path: a, pageIndex: 42)
        let url = try stateFileURL()
        // BookState としてデコード可・version のみ未来
        let future = Data(#"{"version":3,"path":"\#(a)","marks":[],"bookmarks":[]}"#.utf8)
        try future.write(to: url)
        let fresh = BookHistoryStore(defaults: defaults, directory: stateDir)
        XCTAssertNil(fresh.savedPage(forPath: a))  // 未知版は復元しない
        fresh.noteClosed(path: a, pageIndex: 0)
        fresh.save(displayName: "a.zip", path: a,
                   settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                   bookmarks: []))
        XCTAssertEqual(try Data(contentsOf: url), future)  // 上書きしていない
    }

    func testUnreadableRecentsIsNotClobbered() throws {
        let a = try makeBookFile("a.zip")
        let b = try makeBookFile("b.zip")
        store.noteOpened(path: a)
        store.noteOpened(path: b)
        let recentsURL = stateDir.appendingPathComponent("recents.json")
        let garbage = Data("garbage".utf8)
        try garbage.write(to: recentsURL)
        let fresh = BookHistoryStore(defaults: defaults, directory: stateDir)
        XCTAssertEqual(fresh.recentBookPaths(), [])  // 読めない → 空(復元しない)
        let c = try makeBookFile("c.zip")
        fresh.noteOpened(path: c)  // touchRecents → writeRecents は拒否
        XCTAssertEqual(try Data(contentsOf: recentsURL), garbage)  // 潰していない
    }
}
