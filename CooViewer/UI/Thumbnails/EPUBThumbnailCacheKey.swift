import Foundation

/// EPUB サムネイルの描画条件をディスクキャッシュ名へ写像する
/// 純関数群（cooViewer-oxr.64 / cooViewer-oxr.63、設計書 §2.4 EPUB 対応）。
enum EPUBThumbnailCacheKey {
    /// Washi と同じテーマ解決規則。システム設定時だけウインドウ外観へ従う
    /// （cooViewer-oxr.63、設計書 §2.4 EPUB 対応）。
    static func effectiveIsDark(theme: Int, windowIsDark: Bool) -> Bool {
        switch theme {
        case 1: false
        case 2: true
        default: windowIsDark
        }
    }

    /// ページ割りが同じでも描画結果が変わる条件を分離する
    /// （cooViewer-oxr.64、設計書 §2.4 EPUB 対応）。
    static func renderingVariant(metricsKey: String, isDark: Bool,
                                 forcesReadableColors: Bool) -> String {
        "metrics:\(metricsKey)#theme:\(isDark ? "d" : "l")"
            + "#readable:\(forcesReadableColors ? "1" : "0")"
    }

    /// 単体 EPUB の画面サムネイル用キーを組み立てる
    /// （cooViewer-oxr.64、設計書 §2.4 EPUB 対応）。
    static func singleBook(path: String, totalPages: Int, pagesPerScreen: Int,
                           fontScale: Double, pageMargins: Int,
                           defaultFont: String, metricsKey: String,
                           isDark: Bool, forcesReadableColors: Bool) -> String {
        let variant = renderingVariant(
            metricsKey: metricsKey, isDark: isDark,
            forcesReadableColors: forcesReadableColors)
        return "epub:\(path)#\(totalPages)x\(pagesPerScreen)"
            + "#\(fontScale)#\(pageMargins)#\(defaultFont)"
            + "#\(variant)"
    }
}
