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
        let ext = url.pathExtension.lowercased()
        return archiveExtensions.contains(ext) || isSplitVolumeExtension(ext)
    }

    /// 分割書庫の拡張子(r00-r99 / z01-z99 / 000-099 等。仕様書 §2.3 の
    /// 旧 304 拡張子のうち番号系列をパターンで受ける)
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
    static func isSplitVolumeContinuation(_ ext: String) -> Bool {
        guard isSplitVolumeExtension(ext) else { return false }
        return ext != "001"
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// EPUB か(拡張子ベース。UTI は org.idpf.epub-container)。
    /// 固定レイアウトは EPUBSource(画像パイプライン)、リフローは同じ
    /// リーダーウインドウの EPUB 表示モード(設計書 §2.4 EPUB 対応)
    static func isEPUB(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "epub"
    }

    /// UTType 上は画像に適合するが表示できない拡張子(.ai は ImageIO でも
    /// NSImage でも開けないため除外)
    static let undisplayableImageExtensions: Set<String> = ["ai"]

    /// UTType 解決できないが表示できる拡張子か。
    /// avifs: アニメ AVIF(ImageIO がデコード)。
    /// mag / max / mki / pi / pic / pnm: 独自デコーダの形式(高度設定の
    /// トグルで個別に無効化できる)。.max は 3ds Max、.pic は Softimage 等と
    /// 衝突するが、デコードは先頭マジックでゲートするため別形式のファイルを
    /// 誤描画することはない(壊れページ表示)
    static func isExtraImageExtension(_ ext: String) -> Bool {
        switch ext {
        case "avifs":
            return true
        case "mag", "max":
            return RetroFormatToggle.isEnabled(RetroFormatToggle.magKey)
        case "mki":
            return RetroFormatToggle.isEnabled(RetroFormatToggle.makiKey)
        case "pi":
            return RetroFormatToggle.isEnabled(RetroFormatToggle.piKey)
        case "pic":
            return RetroFormatToggle.isEnabled(RetroFormatToggle.picKey)
        case "pnm":
            return RetroFormatToggle.isEnabled(RetroFormatToggle.pnmKey)
        default:
            return false
        }
    }

    /// ページとして表示できる画像ファイルか(拡張子ベース)。
    /// 旧実装の [NSImage imageFileTypes] 判定に相当。
    static func isImageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, !undisplayableImageExtensions.contains(ext) else { return false }
        if isExtraImageExtension(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    /// 「本」として開ける URL か(フォルダ判定は呼び出し側で行う)
    static func isBookFile(_ url: URL) -> Bool {
        isArchive(url) || isPDF(url) || isEPUB(url)
            || folderLikeExtensions.contains(url.pathExtension.lowercased())
    }
}
