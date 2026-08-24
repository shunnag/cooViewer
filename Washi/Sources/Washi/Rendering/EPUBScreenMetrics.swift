import Foundation

/// The **single source of truth** for screen planning. The reader
/// (EPUBReaderView), the whole-book census, and the out-of-reader list
/// expansion (EPUBScreenAtlas) all share the same formula, which
/// structurally guarantees that identical display conditions produce
/// identical pagination.
/// From `viewportSize` (the region the reader occupies) and the display
/// settings, it uniquely derives the content dimensions, the spread flag,
/// the gutter, and the options passed to `__washi.setup()`.
public struct EPUBScreenMetrics: Sendable, Equatable {
    /// Content dimensions after subtracting the margins (insets) — the
    /// actual WKWebView size.
    public let contentSize: CGSize
    /// Number of pages laid out on one screen (1 = single page / 2 = spread).
    /// A single-image item is always 1 at runtime, but this is the planned
    /// value for body text.
    public let pagesPerScreen: Int
    let gap: Double
    let gutter: Double
    let spread: Bool
    private let layoutCSS: String
    private let themedCSSLight: String
    private let themedCSSDark: String

    public init(viewportSize: CGSize, settings: EPUBReaderSettings) {
        let insets = settings.insets
        let size = CGSize(
            width: max(1, viewportSize.width - insets.left - insets.right),
            height: max(1, viewportSize.height - insets.top - insets.bottom))
        contentSize = size
        spread = Self.usesSpread(contentWidth: size.width,
                                 columnMode: settings.columnMode)
        gutter = Double(Self.spreadGutter(forContentWidth: size.width))
        gap = settings.pageGap
        pagesPerScreen = spread ? 2 : 1
        layoutCSS = settings.layoutAffectingCSS()
        themedCSSLight = settings.composedUserCSS(isDark: false)
        themedCSSDark = settings.composedUserCSS(isDark: true)
    }

    /// この内容幅で見開きにするか(auto はウインドウ幅で自動。
    /// Apple Books の 1/2 ページ判定と同じ発想)
    static func usesSpread(contentWidth: CGFloat,
                           columnMode: EPUBColumnMode) -> Bool {
        switch columnMode {
        case .single: false
        case .double: true
        case .auto: contentWidth >= 700
        }
    }

    /// 見開き時の中央ノド幅(Apple Books の版面比を目安に内容幅の約 7%)
    static func spreadGutter(forContentWidth width: CGFloat) -> CGFloat {
        min(96, max(44, (width * 0.07).rounded()))
    }

    /// census 用オプション(配色なし)。sortedKeys で直列化が決定的なので
    /// メトリクスの同一性キーとしても使う
    var censusOptionsJSON: String { optionsJSON(userCSS: layoutCSS) }

    /// Identity key for these metrics (a public accessor the host uses for
    /// cache decisions).
    public var cacheKey: String { censusOptionsJSON }

    /// サムネイル用オプション(census と同じページ割り+テーマ配色。
    /// 配色はページ数に影響しないため番号は census と一致する)
    func themedOptionsJSON(isDark: Bool) -> String {
        optionsJSON(userCSS: isDark ? themedCSSDark : themedCSSLight)
    }

    private func optionsJSON(userCSS: String) -> String {
        let options: [String: Any] = [
            "width": Double(contentSize.width.rounded(.down)),
            "height": Double(contentSize.height.rounded(.down)),
            "gap": gap,
            "spread": spread,
            "gutter": gutter,
            "fixedLayout": false,
            "keysEnabled": false,
            "userCSS": userCSS,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: options, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
