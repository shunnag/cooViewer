import Foundation
import UniformTypeIdentifiers

/// 対応ファイル種別の判定。
/// 旧実装の +fileTypes / +archiveTypes(仕様書 §2.1)に相当する。
enum SupportedTypes {
    /// 書庫エンジン(既定 KaitoKit)で開く書庫の拡張子。
    /// 仕様書 §2.1 の archiveTypes を基に拡張する(設計書 §2.4)。
    static let archiveExtensions: Set<String> = [
        "zip", "cbz", "rar", "cbr", "lzh", "lha", "7z", "cb7", "sit", "sitx", "sea", "hqx",
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
    /// フォルダ統合では続き巻を別の本として数えず、KaitoKit の分割巻処理へ渡す。
    /// .z01…zip、.r00/.partN、.001 系の兄弟探索は file 入口で行う(設計書 §2.4)。
    static func isSplitVolumeContinuation(_ ext: String) -> Bool {
        guard isSplitVolumeExtension(ext) else { return false }
        return ext != "001"
    }

    /// KaitoKit と同じ規則で .partN.rar を分解し、元の綴りを保つ(設計書 §2.4)。
    static func rarPartPattern(_ name: String)
        -> (prefix: String, marker: String, digits: String, number: UInt64, ext: String)? {
        guard let part = rarPartComponents(name),
              let number = UInt64(part.digits), number > 0 else { return nil }
        return (part.prefix, part.marker, part.digits, number, part.ext)
    }

    private static func rarPartComponents(_ name: String)
        -> (prefix: String, marker: String, digits: String, ext: String)? {
        guard name.lowercased().hasSuffix(".rar") else { return nil }
        let stem = String(name.dropLast(4))
        guard let marker = stem.range(of: ".part", options: [.backwards, .caseInsensitive]) else { return nil }
        let digits = String(stem[marker.upperBound...])
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return (String(stem[..<marker.lowerBound]), String(stem[marker]), digits, String(name.suffix(4)))
    }

    /// KaitoKit が先頭巻の綴りから生成する名前を、ファイルシステムの比較規則に合わせて照合する。
    /// 正規化形の違いは常に吸収し、大小文字はボリュームが区別しない場合だけ同一視する。
    /// 巻番号が先頭巻の幅を超える場合だけ、ゼロ埋めなしの桁数増加を許す(設計書 §2.4、§7.4)。
    static func rarPartContinuationIndices(in paths: [String], caseSensitive: Bool) -> Set<Int> {
        var firstParts: [[UInt8]: Set<Int>] = [:]
        var continuations: [(index: Int, key: [UInt8], width: Int, hasLeadingZero: Bool)] = []
        for (index, path) in paths.enumerated() {
            let name = (path as NSString).lastPathComponent
            guard let part = rarPartComponents(name) else { continue }
            // 数値型の上限に関係なく、任意のゼロ埋めと 2 以上の巻番号を扱う(設計書 §2.4)。
            let number = part.digits.drop(while: { $0 == "0" })
            guard !number.isEmpty else { continue }
            // 名前の先頭が結合文字でも、直前の区切りを同じ書記素として削らない。
            let parent = String(decoding: path.utf8.dropLast(name.utf8.count), as: UTF8.self)
            let family = parent + part.prefix + part.marker + part.ext
            let compared = caseSensitive ? family : family.folding(
                options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            let key = Array(compared.precomposedStringWithCanonicalMapping.utf8)
            if number == "1" {
                firstParts[key, default: []].insert(part.digits.count)
            } else {
                continuations.append((index, key, part.digits.count, part.digits.first == "0"))
            }
        }
        return Set(continuations.compactMap { continuation in
            guard let widths = firstParts[continuation.key],
                  widths.contains(continuation.width)
                    || (!continuation.hasLeadingZero && widths.contains { $0 < continuation.width })
            else { return nil }
            return continuation.index
        })
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
