import Foundation
import UniformTypeIdentifiers

/// 対応ファイル種別の判定。
/// 旧実装の +fileTypes / +archiveTypes(仕様書 §2.1)に相当する。
enum SupportedTypes {
    /// XADMaster で開く書庫の拡張子(仕様書 §2.1 の archiveTypes と同一)
    static let archiveExtensions: Set<String> = [
        "zip", "cbz", "rar", "cbr", "lzh", "lha", "7z", "sit",
    ]

    /// フォルダとして扱う拡張子(cvbdl = 旧 cooViewer バンドル)
    static let folderLikeExtensions: Set<String> = ["cvbdl"]

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// UTType 上は画像に適合するが表示できない拡張子(.ai は ImageIO でも
    /// NSImage でも開けないため除外)
    static let undisplayableImageExtensions: Set<String> = ["ai"]

    /// ページとして表示できる画像ファイルか(拡張子ベース)。
    /// 旧実装の [NSImage imageFileTypes] 判定に相当。
    static func isImageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, !undisplayableImageExtensions.contains(ext) else { return false }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// 「本」として開ける URL か(フォルダ判定は呼び出し側で行う)
    static func isBookFile(_ url: URL) -> Bool {
        isArchive(url) || isPDF(url)
            || folderLikeExtensions.contains(url.pathExtension.lowercased())
    }
}
