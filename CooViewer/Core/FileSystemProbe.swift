import Foundation

/// ディレクトリ直下の 1 項目(名前と「ディレクトリか」)。
struct DirectoryItem: Sendable, Hashable {
    let name: String
    let isDirectory: Bool
}

/// 本ファイルの同一性(サムネイルキャッシュキーの材料)。stat できなければ 0
struct BookFileIdentity: Sendable, Equatable {
    var modified: TimeInterval = 0
    var size: Int = 0
}

/// ディレクトリ列挙・存在判定・ファイル属性取得の注入点。SMB/NAS では stat 1 回が数 ms、
/// 応答しないマウントでは SMB タイムアウトまで止まるため、呼び出し側は
/// これをメインアクター外で使い、テストは遅延する偽物へ差し替える
/// (設計書 §7.3。PowerStateProviding と同じ差し替え方式)。
protocol FileSystemProbing: Sendable {
    /// 直下の項目。隠しファイルの除外は呼び出し側が名前で行う
    /// (`.skipsHiddenFiles` は hidden フラグ付きの項目も落とし、旧来の
    /// ドット始まり判定と結果がずれる)。列挙できなければ throw
    func directoryItems(at directory: URL) throws -> [DirectoryItem]
    func fileExists(atPath path: String) -> Bool
    func identity(at url: URL) -> BookFileIdentity
}

/// FileManager 直結の既定実装。ディレクトリ判定は一括列挙で先読みした
/// リソース値を使い、項目ごとの stat を避ける。
struct FileManagerProbe: FileSystemProbing {
    func directoryItems(at directory: URL) throws -> [DirectoryItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // リソース値はシンボリックリンクを辿らないが、旧来の
            // fileExists(isDirectory:) は辿っていた。リンクだけ従来どおり stat する
            if values?.isSymbolicLink == true {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return DirectoryItem(name: url.lastPathComponent,
                                     isDirectory: isDirectory.boolValue)
            }
            return DirectoryItem(name: url.lastPathComponent,
                                 isDirectory: values?.isDirectory == true)
        }
    }

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func identity(at url: URL) -> BookFileIdentity {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return BookFileIdentity(
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: attributes?[.size] as? Int ?? 0)
    }
}
