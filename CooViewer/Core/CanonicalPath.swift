import Foundation

/// パスの正規形(シンボリックリンク解決込み)。本の同一性判定の共通規則で、
/// BookHistoryStore の v2 ストアと PasswordVault が同じ形を共有する —
/// 「コレクションフォルダ内の zip」と「単体で開いた同じ zip」が同一キーに
/// なることはこの正規化に依存する(FolderSource の列挙 URL は生のまま
/// 格納されるため、キー生成側で必ずこれを通すこと)
enum CanonicalPath {
    nonisolated static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
