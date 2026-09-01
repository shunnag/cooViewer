import XCTest

@testable import cooViewer

/// リフロー EPUB の読書位置(spine index + 進行率)の保存・復元(cooViewer-c6s.10)。
/// 固定ページの savedPage と同じ復元ゲート(§7.3 write-time 意味論)を共有する
@MainActor
final class EPUBReflowPositionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: BookHistoryStore!
    private var tempDir: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "test.cooViewer.reflow")
        defaults.removePersistentDomain(forName: "test.cooViewer.reflow")
        defaults.set(10, forKey: "OpenRecentLimit")
        tempDir = try TestFixtures.makeTempDir()
        store = BookHistoryStore(
            defaults: defaults,
            directory: tempDir.appendingPathComponent("BookStates"))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: "test.cooViewer.reflow")
        try FileManager.default.removeItem(at: tempDir)
    }

    private func makeBookFile(_ name: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.resolvingSymlinksInPath().path
    }

    func testSaveAndRestore() throws {
        let path = try makeBookFile("novel.epub")
        store.noteOpened(path: path)  // 開いた時に recents へ入る(位置保存では動かさない)
        store.noteClosedReflow(path: path, spineIndex: 3, progression: 0.5)
        let position = try XCTUnwrap(store.savedReflowPosition(forPath: path))
        XCTAssertEqual(position.spineIndex, 3)
        XCTAssertEqual(position.progression, 0.5, accuracy: 0.0001)
        XCTAssertEqual(store.recentBookPaths(), [path])
    }

    /// census は「既存の状態を持つ本」にだけ相乗りで保存される
    /// (census 専用ファイルは作らない=BookStates の際限ない肥大を防ぐ)
    func testCensusSaveAndRestore() throws {
        let path = try makeBookFile("novel.epub")
        // 状態が無い本には census を保存しない(ファイルを新規作成しない)
        store.noteReflowCensus(path: path, metricsKey: "m1", counts: [4, 6, 2],
                               releaseIdentifier: "urn:uuid:x@2026")
        XCTAssertNil(store.savedReflowCensus(forPath: path))

        // 位置を持つ「読んでいる本」には相乗りで保存・読み出しできる
        store.noteOpened(path: path)
        store.noteClosedReflow(path: path, spineIndex: 1, progression: 0.4)
        store.noteReflowCensus(path: path, metricsKey: "m2", counts: [4, 6, 2],
                               releaseIdentifier: "urn:uuid:x@2026")
        let census = try XCTUnwrap(store.savedReflowCensus(forPath: path))
        XCTAssertEqual(census.metricsKey, "m2")
        XCTAssertEqual(census.counts, [4, 6, 2])
        XCTAssertEqual(census.releaseIdentifier, "urn:uuid:x@2026")
        // 位置と併存し、位置更新でも census は保持される
        store.noteClosedReflow(path: path, spineIndex: 2, progression: 0.6)
        XCTAssertNotNil(store.savedReflowCensus(forPath: path))
        XCTAssertNotNil(store.savedReflowPosition(forPath: path))
    }

    /// 位置保存は recents の順序を動かさない(ページ送りのたびのデバウンス保存や
    /// ⌘Q の両ウインドウ保存で「昔開いた EPUB」が最前列へ来ないように)
    func testPositionSaveDoesNotReorderRecents() throws {
        let epub = try makeBookFile("novel.epub")
        let zip = try makeBookFile("comic.zip")
        store.noteOpened(path: epub)
        store.noteOpened(path: zip)
        store.noteClosedReflow(path: epub, spineIndex: 2, progression: 0.5)
        XCTAssertEqual(store.recentBookPaths(), [zip, epub])
    }

    /// コレクション(合本)経由の子 EPUB は recents に入れない設計のため、
    /// force フラグで書込時に復元ゲートを通しておく(cooViewer-4gc)
    func testCollectionChildRestoresWithoutRecents() throws {
        let path = try makeBookFile("child.epub")
        // recents には入れない(noteOpened しない)
        store.noteClosedReflow(path: path, spineIndex: 2, progression: 0.25,
                               forceRememberBeyondRecents: true)
        let position = try XCTUnwrap(store.savedReflowPosition(forPath: path))
        XCTAssertEqual(position.spineIndex, 2)
        XCTAssertTrue(store.recentBookPaths().isEmpty, "recents は汚さない")
        // 対照: force なしの recents 外保存は復元されない(既存の §7.3 規則)
        let other = try makeBookFile("other.epub")
        store.noteClosedReflow(path: other, spineIndex: 1, progression: 0.5)
        XCTAssertNil(store.savedReflowPosition(forPath: other))
    }

    func testBookStartIsNotSaved() throws {
        // 先頭位置は「復帰なし」と不可分のため保存しない(savedPage と同じ規則)
        let path = try makeBookFile("novel.epub")
        store.noteOpened(path: path)
        store.noteClosedReflow(path: path, spineIndex: 0, progression: 0)
        XCTAssertNil(store.savedReflowPosition(forPath: path))
        // 途中位置 → 先頭に戻して閉じたら消える
        store.noteClosedReflow(path: path, spineIndex: 2, progression: 0.3)
        XCTAssertNotNil(store.savedReflowPosition(forPath: path))
        store.noteClosedReflow(path: path, spineIndex: 0, progression: 0)
        XCTAssertNil(store.savedReflowPosition(forPath: path))
    }

    func testRecentsGateFollowsWriteTimeSemantics() throws {
        // 一覧から外れた本は「閉じた時点で」AlwaysRememberLastPage が ON の
        // ときだけ復元できる(§7.3 の write-time 意味論を共有)
        let path = try makeBookFile("novel.epub")
        defaults.set(false, forKey: "AlwaysRememberLastPage")
        store.noteOpened(path: path)
        store.noteClosedReflow(path: path, spineIndex: 1, progression: 0.8)
        // 一覧内なら復元できる
        XCTAssertNotNil(store.savedReflowPosition(forPath: path))
        // 他の本で一覧から追い出す(表示上限 10 件)
        for i in 0..<12 {
            store.noteOpened(path: try makeBookFile("other\(i).zip"))
        }
        XCTAssertNil(store.savedReflowPosition(forPath: path))
    }

    /// ファイル移動後も URL ブックマークで読書位置を追跡できる
    /// (noteClosedReflow が urlBookmark を書くこと。cooViewer-c6s.18)
    func testRelocationAfterMove() throws {
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        let oldURL = tempDir.appendingPathComponent("moved-novel.epub")
        try Data("x".utf8).write(to: oldURL)
        let oldPath = oldURL.resolvingSymlinksInPath().path
        store.noteOpened(path: oldPath)
        store.noteClosedReflow(path: oldPath, spineIndex: 4, progression: 0.25)

        // 同名のまま別ディレクトリへ移動(relocateState は同ファイル名が対象)
        let newDir = tempDir.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: newDir,
                                                withIntermediateDirectories: true)
        let newURL = newDir.appendingPathComponent("moved-novel.epub")
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let newPath = newURL.resolvingSymlinksInPath().path

        let position = try XCTUnwrap(store.savedReflowPosition(forPath: newPath))
        XCTAssertEqual(position.spineIndex, 4)
        XCTAssertEqual(position.progression, 0.25, accuracy: 0.0001)
    }

    func testCoexistsWithFixedPageState() throws {
        // 固定ページ(lastPageIndex)としおりとリフロー位置は同居できる
        let path = try makeBookFile("mixed.epub")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosed(path: path, pageIndex: 7)
        store.noteClosedReflow(path: path, spineIndex: 2, progression: 0.25)
        XCTAssertEqual(store.savedPage(forPath: path)?.page, 7)
        XCTAssertEqual(store.savedReflowPosition(forPath: path)?.spineIndex, 2)
    }

    // MARK: - columnMode(s キーの単/見開き固定。cooViewer-0dh)

    /// 別インスタンスから読み直す(= アプリ再起動)。ディスク永続を実証する
    private func reopenStore() -> BookHistoryStore {
        BookHistoryStore(defaults: defaults,
                         directory: tempDir.appendingPathComponent("BookStates"))
    }

    /// RememberBookSettings が ON なら columnMode は再起動を跨いで残る
    func testColumnModeSurvivesRestart() throws {
        let path = try makeBookFile("novel.epub")
        defaults.set(true, forKey: "RememberBookSettings")
        store.noteReflowColumnMode(path: path, columnMode: 2)  // double
        XCTAssertEqual(store.savedReflowColumnMode(forPath: path), 2)
        // 別インスタンス(再起動相当)からもディスク経由で読める
        XCTAssertEqual(reopenStore().savedReflowColumnMode(forPath: path), 2)
    }

    /// 表示設定なので RememberBookSettings が OFF のときは残さない
    /// (既存値も消す=save() の readMode/marks と同じ規則)
    func testColumnModeNotPersistedWhenRememberOff() throws {
        let path = try makeBookFile("novel.epub")
        defaults.set(true, forKey: "RememberBookSettings")
        store.noteReflowColumnMode(path: path, columnMode: 1)
        XCTAssertEqual(store.savedReflowColumnMode(forPath: path), 1)
        // OFF にして書くと既存値も消える
        defaults.set(false, forKey: "RememberBookSettings")
        store.noteReflowColumnMode(path: path, columnMode: 2)
        XCTAssertNil(store.savedReflowColumnMode(forPath: path))
        XCTAssertNil(reopenStore().savedReflowColumnMode(forPath: path))
    }

    /// auto(0)は「固定なし」= 既定なので保存しない(空状態の肥大防止)
    func testColumnModeAutoNotPersisted() throws {
        let path = try makeBookFile("novel.epub")
        defaults.set(true, forKey: "RememberBookSettings")
        store.noteReflowColumnMode(path: path, columnMode: 0)
        XCTAssertNil(store.savedReflowColumnMode(forPath: path))
    }

    /// marks と同じく、recents から外れても復元できる(位置と違い表示設定は
    /// recents ゲートを持たない)。位置・census とも同居する
    func testColumnModeHasNoRecentsGateAndCoexists() throws {
        let path = try makeBookFile("novel.epub")
        defaults.set(true, forKey: "RememberBookSettings")
        // recents にも AlwaysRememberLastPage にも入れない
        defaults.set(false, forKey: "AlwaysRememberLastPage")
        store.noteReflowColumnMode(path: path, columnMode: 2)
        store.noteClosedReflow(path: path, spineIndex: 3, progression: 0.5)
        // 位置は recents ゲートで復元不可でも、columnMode は残る
        XCTAssertNil(store.savedReflowPosition(forPath: path))
        XCTAssertEqual(store.savedReflowColumnMode(forPath: path), 2)
    }

    /// columnMode を持たない旧 JSON はデコード互換(nil で読める)
    func testColumnModeBackwardCompatibleWithOldState() throws {
        let path = try makeBookFile("novel.epub")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteClosedReflow(path: path, spineIndex: 1, progression: 0.4)
        XCTAssertNil(store.savedReflowColumnMode(forPath: path))
        XCTAssertNil(reopenStore().savedReflowColumnMode(forPath: path))
    }

    /// columnMode を消した結果 census だけが残る場合は census も落とす
    /// (合本の子で s→census→Remember OFF 解除。census 単独ファイルを残さない)
    func testClearingColumnModeDropsOrphanedCensus() throws {
        let path = try makeBookFile("child.epub")
        defaults.set(true, forKey: "RememberBookSettings")
        store.noteReflowColumnMode(path: path, columnMode: 2)  // state を作る
        store.noteReflowCensus(path: path, metricsKey: "m", counts: [1, 2],
                               releaseIdentifier: nil)  // 相乗り
        XCTAssertNotNil(store.savedReflowCensus(forPath: path))
        // Remember OFF で columnMode を解除 → census だけの状態を残さない
        defaults.set(false, forKey: "RememberBookSettings")
        store.noteReflowColumnMode(path: path, columnMode: 2)
        XCTAssertNil(store.savedReflowColumnMode(forPath: path))
        XCTAssertNil(store.savedReflowCensus(forPath: path))
        XCTAssertNil(reopenStore().savedReflowCensus(forPath: path))
    }

    /// 位置がある本では columnMode 解除でも census は残す(過剰削除しない)
    func testClearingColumnModeKeepsCensusWhenPositionPresent() throws {
        let path = try makeBookFile("novel.epub")
        defaults.set(true, forKey: "RememberBookSettings")
        defaults.set(true, forKey: "AlwaysRememberLastPage")
        store.noteReflowColumnMode(path: path, columnMode: 2)
        store.noteClosedReflow(path: path, spineIndex: 2, progression: 0.5)
        store.noteReflowCensus(path: path, metricsKey: "m", counts: [1, 2],
                               releaseIdentifier: nil)
        defaults.set(false, forKey: "RememberBookSettings")
        store.noteReflowColumnMode(path: path, columnMode: 2)
        XCTAssertNil(store.savedReflowColumnMode(forPath: path))
        XCTAssertNotNil(store.savedReflowCensus(forPath: path))
        XCTAssertNotNil(store.savedReflowPosition(forPath: path))
    }
}
