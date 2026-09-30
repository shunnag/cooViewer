import Foundation

/// 本番の BookHistoryStore と依存する値型を一緒に swiftc -O でコンパイルする。
/// 従来の 4 回更新と一括保存を交互に実行し、書込回数・時間・復元結果を比較する。
@main
struct BookStateBenchmark {
    @MainActor
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cooviewer-book-state-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let domain = "test.cooViewer.book-state-benchmark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "RememberBookSettings")
        let bookURL = root.appendingPathComponent("book.epub")
        try Data("book".utf8).write(to: bookURL)
        let sequentialDirectory = root.appendingPathComponent("sequential", isDirectory: true)
        let snapshotDirectory = root.appendingPathComponent("snapshot", isDirectory: true)
        let sequentialStore = BookHistoryStore(defaults: defaults, directory: sequentialDirectory)
        let snapshotStore = BookHistoryStore(defaults: defaults, directory: snapshotDirectory)
        let bookmarks = (0..<20).map {
            (name: "mark\($0)", spineIndex: $0, progression: 0.5, idref: "chapter\($0)")
        }
        let counts = (0..<100).map { $0 % 8 + 1 }
        let snapshot = ReflowBookStateSnapshot(
            position: .init(spineIndex: 50, progression: 0.5, idref: "chapter50"),
            columnMode: 2,
            bookmarks: bookmarks.map {
                .init(name: $0.name, position: .init(
                    spineIndex: $0.spineIndex, progression: $0.progression, idref: $0.idref))
            },
            census: .init(metricsKey: "m", counts: counts, releaseIdentifier: "v1"),
            forceRememberBeyondRecents: true)

        func saveSequentially() {
            sequentialStore.noteClosedReflow(
                path: bookURL.path, spineIndex: 50, progression: 0.5, idref: "chapter50",
                forceRememberBeyondRecents: true)
            sequentialStore.noteReflowCensus(
                path: bookURL.path, metricsKey: "m", counts: counts, releaseIdentifier: "v1")
            sequentialStore.noteReflowColumnMode(path: bookURL.path, columnMode: 2)
            sequentialStore.noteReflowBookmarks(path: bookURL.path, bookmarks: bookmarks)
        }
        func saveSnapshot() {
            precondition(snapshotStore.saveReflowBook(path: bookURL.path, snapshot: snapshot) == .saved)
        }
        // 初回のディレクトリ作成とキャッシュ準備は計測から外す。
        saveSequentially()
        saveSnapshot()
        let iterations = 200
        for round in 0..<6 {
            for mode in round.isMultiple(of: 2) ? ["sequential", "snapshot"] : ["snapshot", "sequential"] {
                let store = mode == "snapshot" ? snapshotStore : sequentialStore
                let writesBefore = store.stateFileWriteCount
                let start = ContinuousClock.now
                for _ in 0..<iterations {
                    if mode == "snapshot" { saveSnapshot() } else { saveSequentially() }
                }
                let elapsed = (ContinuousClock.now - start).components
                let milliseconds = Double(elapsed.seconds) * 1_000
                    + Double(elapsed.attoseconds) / 1e15
                print("round=\(round) mode=\(mode) saves=\(iterations) writes=\(store.stateFileWriteCount - writesBefore) ms=\(milliseconds)")
            }
        }

        // メモリ上の値でなく、保存されたファイルから同じ読書状態を復元できるか確かめる。
        for directory in [sequentialDirectory, snapshotDirectory] {
            let fresh = BookHistoryStore(defaults: defaults, directory: directory)
            let position = fresh.savedReflowPosition(forPath: bookURL.path)
            precondition(position?.spineIndex == 50 && position?.progression == 0.5
                         && position?.idref == "chapter50")
            precondition(fresh.savedReflowColumnMode(forPath: bookURL.path) == 2)
            precondition(fresh.savedReflowCensus(forPath: bookURL.path)?.counts == counts)
            let restored = fresh.savedReflowBookmarks(forPath: bookURL.path)
            precondition(restored.count == bookmarks.count)
            for (actual, expected) in zip(restored, bookmarks) {
                precondition(actual.name == expected.name && actual.spineIndex == expected.spineIndex
                             && actual.progression == expected.progression && actual.idref == expected.idref)
            }
        }
        print("restored_state=match")
    }
}
