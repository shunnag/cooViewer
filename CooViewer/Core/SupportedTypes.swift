import Foundation
import UniformTypeIdentifiers

/// 対応ファイル種別の判定。
/// 旧実装の +fileTypes / +archiveTypes(仕様書 §2.1)に相当する。
/// EN: File-type checks for books and pages (legacy +fileTypes/+archiveTypes).
enum SupportedTypes {
    /// XADMaster で開く書庫の拡張子(仕様書 §2.1 の archiveTypes と同一)
    static let archiveExtensions: Set<String> = [
        "zip", "cbz", "rar", "cbr", "lzh", "lha", "7z", "sit",
    ]

    /// フォルダとして扱う拡張子(cvbdl = 旧 cooViewer バンドル)
    static let folderLikeExtensions: Set<String> = ["cvbdl"]

    static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return archiveExtensions.contains(ext) || isSplitVolumeExtension(ext)
    }

    /// 分割書庫の拡張子(r00-r99 / z01-z99 / 000-099 等。仕様書 §2.3 の
    /// 旧 304 拡張子のうち番号系列をパターンで受ける)
    /// EN: Split-volume extensions (rNN / zNN / NNN) accepted by pattern.
    static func isSplitVolumeExtension(_ ext: String) -> Bool {
        guard ext.count == 3 else { return false }
        if ext.hasPrefix("r") || ext.hasPrefix("z") {
            return ext.dropFirst().allSatisfy(\.isNumber)
        }
        return ext.allSatisfy(\.isNumber)
    }

    /// 分割書庫の「続き」ボリュームか(先頭巻 .001 以外の番号系列)。
    /// フォルダ統合では先頭巻だけを本として扱い、続き巻は XADMaster の
    /// スパン処理に任せる(続き巻を別の本として数えない)
    /// EN: Continuation split volumes (anything but the leading .001); folder
    /// EN: merging opens only the first volume and lets XADMaster span the rest.
    static func isSplitVolumeContinuation(_ ext: String) -> Bool {
        guard isSplitVolumeExtension(ext) else { return false }
        return ext != "001"
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// UTType 上は画像に適合するが表示できない拡張子(.ai は ImageIO でも
    /// NSImage でも開けないため除外)
    /// EN: Extensions that claim to be images but cannot actually be displayed.
    static let undisplayableImageExtensions: Set<String> = ["ai"]

    /// UTType 解決できないが表示できる拡張子。
    /// avifs: アニメ AVIF(ImageIO がデコード)。
    /// mag / max / mki: レトロ日本形式(MAG / MAKI。RetroImageDecoding が
    /// デコード)。.max は 3ds Max 等とも衝突するが、デコードは先頭マジックで
    /// ゲートするため別形式のファイルを誤描画することはない(壊れページ表示)
    /// EN: Extensions UTType cannot resolve but we can display. The retro
    /// EN: extensions collide with unrelated formats; decoding is magic-gated,
    /// EN: so foreign files never get misrendered (they show the broken page).
    static let extraImageExtensions: Set<String> = [
        "avifs", "mag", "max", "mki", "pi", "pic",
    ]

    /// ページとして表示できる画像ファイルか(拡張子ベース)。
    /// 旧実装の [NSImage imageFileTypes] 判定に相当。
    /// EN: Extension-based check for displayable page images.
    static func isImageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, !undisplayableImageExtensions.contains(ext) else { return false }
        if extraImageExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// 「本」として開ける URL か(フォルダ判定は呼び出し側で行う)
    /// EN: Whether the URL opens as a book (folders are checked by callers).
    static func isBookFile(_ url: URL) -> Bool {
        isArchive(url) || isPDF(url)
            || folderLikeExtensions.contains(url.pathExtension.lowercased())
    }
}
