import CoreGraphics
import Foundation
import XADMaster

/// 書庫(zip/rar/7z 等)を本として読む(仕様書 §2.4, §4.17)。
/// XADArchive はスレッド安全でないため actor で直列化する。
/// ファイル名エンコーディングは XADMaster + UniversalDetector が自動判定する。
///
/// ネットワークドライブや solid 書庫でも快適に読めるよう、開いた後に
/// バックグラウンドで全ページをローカル一時領域へ逐次展開する(スプール。
/// 設計書「キャッシュ・先読み設計」)。スプール済みページはローカル読みになる。
actor ArchiveSource: BookSource {
    nonisolated let url: URL
    private let archive: XADArchive
    private let pageEntries: [PageEntry]

    private var spoolDirectory: URL?
    private var spooledIDs: Set<Int> = []
    private var spoolTask: Task<Void, Never>?

    /// スプールする合計展開サイズの上限(これを超える書庫はオンデマンドのみ)
    static let defaultSpoolSizeLimit: Int64 = 4 << 30

    nonisolated var supportsDateSort: Bool { false }

    /// スプールの置き場所。<pid>-<uuid> のサブディレクトリを掘る
    /// (起動時掃除で生存プロセスのものを残すため。仕様書 §4.17 の残骸問題への対策)。
    nonisolated static func spoolRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cooViewer-spool")
    }

    init(url: URL) throws {
        self.url = url
        guard let archive = XADArchive(file: url.path) else {
            throw BookSourceError.unreadable(url)
        }
        self.archive = archive

        // 旧実装(XADWrapper)同様、ディレクトリとサイズ 0 のエントリを除外する。
        // 加えて画像以外のファイルと macOS メタデータ(__MACOSX/、._*)も除外する。
        var entries: [PageEntry] = []
        for index in 0..<archive.numberOfEntries() {
            guard let name = archive.name(ofEntry: index) else { continue }
            guard !archive.entryIsDirectory(index), archive.size(ofEntry: index) != 0 else {
                continue
            }
            let lastComponent = (name as NSString).lastPathComponent
            guard !lastComponent.hasPrefix("."),
                  !name.hasPrefix("__MACOSX"),
                  SupportedTypes.isImageFile(lastComponent) else { continue }

            entries.append(PageEntry(
                id: Int(index),
                name: lastComponent,
                pathInBook: name,
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            ))
        }
        self.pageEntries = entries
    }

    deinit {
        spoolTask?.cancel()
        if let directory = spoolDirectory {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    func entries() async throws -> [PageEntry] {
        pageEntries
    }

    func imageData(for entry: PageEntry) async -> Data? {
        spooledData(for: entry.id) ?? archive.contents(ofEntry: Int32(entry.id))
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        let data: Data
        if let spooled = spooledData(for: entry.id) {
            data = spooled
        } else if let extracted = archive.contents(ofEntry: Int32(entry.id)) {
            data = extracted
        } else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
    }

    func isEncrypted() async -> Bool {
        archive.isEncrypted()
    }

    /// パスワードを設定し、先頭エントリの展開を試して検証する(仕様書 §4.1.3)。
    func checkAndSetPassword(_ password: String) async -> Bool {
        guard let first = pageEntries.first else { return false }
        archive.setPassword(password)
        return archive.contents(ofEntry: Int32(first.id)) != nil
    }

    // MARK: - スプール

    /// 全ページのローカル展開を開始する(パスワード解除後に呼ぶこと)。
    /// 書庫順=エントリ順の逐次展開なので、ネットワーク越しでも solid 書庫でも
    /// 最速のアクセスパターンになる。展開中のページ要求は従来経路で応える。
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {
        beginSpooling(sizeLimit: spoolSizeLimit)
    }

    func beginSpooling(sizeLimit: Int64) {
        guard spoolTask == nil, !pageEntries.isEmpty else { return }
        var total: Int64 = 0
        for entry in pageEntries {
            total += Int64(archive.size(ofEntry: Int32(entry.id)))
        }
        guard total <= sizeLimit else { return }

        let directory = Self.spoolRoot().appendingPathComponent(
            "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil else { return }
        spoolDirectory = directory

        let ids = pageEntries.map(\.id)
        spoolTask = Task { [weak self] in
            for id in ids {
                if Task.isCancelled { return }
                await self?.spoolEntry(id)
                // 表示中のページ要求が割り込めるよう 1 エントリごとに譲る
                await Task.yield()
            }
        }
    }

    /// スプール完了を待つ(テスト・診断用)
    func waitForSpoolCompletion() async {
        await spoolTask?.value
    }

    var spooledEntryCount: Int { spooledIDs.count }

    private func spoolEntry(_ id: Int) {
        guard let directory = spoolDirectory, !spooledIDs.contains(id) else { return }
        guard let data = archive.contents(ofEntry: Int32(id)) else { return }
        let fileURL = directory.appendingPathComponent(String(id))
        if (try? data.write(to: fileURL, options: .atomic)) != nil {
            spooledIDs.insert(id)
        }
    }

    private func spooledData(for id: Int) -> Data? {
        guard spooledIDs.contains(id), let directory = spoolDirectory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(String(id)))
    }
}
