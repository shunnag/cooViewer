import Foundation

/// EPUB で扱うメディアタイプの定数と拡張子推定。
/// マニフェスト宣言を第一に信頼し、宣言がないリソース(補助ファイル等)の
/// 配信時だけ拡張子から推定する。
public enum EPUBMediaType {
    public static let xhtml = "application/xhtml+xml"
    public static let ncx = "application/x-dtbncx+xml"
    public static let opf = "application/oebps-package+xml"
    public static let epub = "application/epub+zip"
    public static let svg = "image/svg+xml"
    public static let css = "text/css"
    public static let javascript = "application/javascript"
    public static let smil = "application/smil+xml"

    /// コア画像タイプ(EPUB 3.3 core media types)
    public static let coreImageTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", svg,
    ]

    static let byExtension: [String: String] = [
        "xhtml": xhtml, "html": xhtml, "htm": xhtml,
        "css": css,
        "js": javascript, "mjs": javascript,
        "svg": svg,
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "avif": "image/avif",
        "otf": "font/otf", "ttf": "font/ttf",
        "woff": "font/woff", "woff2": "font/woff2",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/mp4",
        "ogg": "audio/ogg", "opus": "audio/ogg", "wav": "audio/wav",
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm",
        "smil": smil, "ncx": ncx, "opf": opf,
        "xml": "application/xml", "json": "application/json",
        "txt": "text/plain",
    ]

    /// 拡張子からの推定(不明は octet-stream)
    public static func guessed(fromPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? "application/octet-stream"
    }

    /// フォントか(難読化対象の判定などに使う)
    public static func isFont(_ mediaType: String) -> Bool {
        mediaType.hasPrefix("font/")
            || mediaType == "application/font-woff"
            || mediaType == "application/vnd.ms-opentype"
            || mediaType == "application/x-font-ttf"
            || mediaType == "application/x-font-otf"
            || mediaType == "application/x-font-truetype"
            || mediaType == "application/x-font-opentype"
    }

    /// ブラウザに解釈させる文書タイプか(charset 付与の判定)
    public static func isTextual(_ mediaType: String) -> Bool {
        mediaType.hasPrefix("text/")
            || mediaType.hasSuffix("+xml")
            || mediaType == javascript
            || mediaType == "application/xml"
            || mediaType == "application/json"
    }
}
