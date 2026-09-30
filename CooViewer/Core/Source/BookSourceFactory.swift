import Foundation
import Washi

enum BookSourceFactory {
    /// URL から適切な BookSource を生成する。
    /// 単一画像ファイル → 親フォルダの読み替え(仕様書 §4.1.2 手順 2)は呼び出し側で
    /// 済ませておくこと。
    /// nestedPasswordProvider: 暗号化されたネスト書庫/PDF のパスワードを UI に
    /// 求めるコールバック(nil なら既知パスワードのみ試して黙って飛ばす)
    static func make(for url: URL, readSubFolders: Bool,
                     nestedPasswordProvider: NestedPasswordProvider? = nil,
                     preparsedEPUB: EPUBPublication? = nil,
                     vault: PasswordVault? = PasswordVault.sharedIfEnabled(),
                     archiveEngine: ArchiveEngineKind = .kaitokit)
        async throws -> any BookSource {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BookSourceError.unreadable(url)
        }
        let unlocker = NestedUnlocker(provider: nestedPasswordProvider, vault: vault)
        if isDirectory.boolValue {
            let folder = try FolderSource(url: url, readSubFolders: readSubFolders)
            // 書庫/PDF を含むフォルダは統合ソースで包む(旧ネストローダー §2.4)。
            // 画像だけなら従来どおり(並列ロード・日付ソート可を維持)
            if folder.nestedBookCandidates.isEmpty {
                return folder
            }
            return NestedFolderSource(
                folder: folder, unlocker: unlocker,
                preferredEngine: archiveEngine)
        }
        if SupportedTypes.isPDF(url) {
            return try PDFSource(url: url)
        }
        if SupportedTypes.isEPUB(url) {
            // FXL と画像のみ EPUB が対象(通常のリフローは openBookFlow が
            // 専用リーダーへ振り分け済み)。
            if let preparsedEPUB,
               CanonicalPath.normalize(preparsedEPUB.url.path)
                   == CanonicalPath.normalize(url.path) {
                // ルーティング済み Publication を引き継ぎ、同じ EPUB の
                // OCF/package を読み直さない(cooViewer-oxr.42、設計書 §2.4)。
                return try EPUBSource(publication: preparsedEPUB, url: url)
            }
            return try EPUBSource(url: url)
        }
        if SupportedTypes.isArchive(url) {
            return try ArchiveSource(url: url, unlocker: unlocker,
                                     persistenceKey: .file(path: url.path),
                                     preferredEngine: archiveEngine)
        }
        throw BookSourceError.unsupportedFormat(url)
    }
}
