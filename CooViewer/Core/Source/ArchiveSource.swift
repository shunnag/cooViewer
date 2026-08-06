import CoreGraphics
import Foundation
import XADMaster

/// 書庫(zip/rar/7z 等)を本として読む(仕様書 §2.4, §4.17)。
/// XADArchive はスレッド安全でないため actor で直列化する。
/// ファイル名エンコーディングは XADMaster + UniversalDetector が自動判定する。
actor ArchiveSource: BookSource {
    nonisolated let url: URL
    private let archive: XADArchive
    private let pageEntries: [PageEntry]

    nonisolated var supportsDateSort: Bool { false }

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

    func entries() async throws -> [PageEntry] {
        pageEntries
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        guard let data = archive.contents(ofEntry: Int32(entry.id)) else {
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
}
