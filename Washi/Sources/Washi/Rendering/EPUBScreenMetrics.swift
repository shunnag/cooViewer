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
    /// Version of the pagination algorithm encoded in cache and census keys.
    /// A change invalidates persisted measurements made by older engines.
    public static let paginationVersion = 3

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
    private let viewportSize: CGSize
    private let insets: EPUBReaderInsets
    private let spreadInsets: EPUBReaderInsets?
    private let columnMode: EPUBColumnMode
    private let allowsScriptedContent: Bool
    private let fontScale: Double
    private let defaultFontCSS: String

    public init(viewportSize: CGSize, settings: EPUBReaderSettings) {
        self.init(viewportSize: viewportSize, settings: settings,
                  renditionSpread: .auto)
    }

    /// Creates screen metrics while honoring an effective `rendition:spread`
    /// preference (publication-wide or item-specific).
    public init(viewportSize: CGSize, settings: EPUBReaderSettings,
                renditionSpread: RenditionSpread) {
        self.init(
            viewportSize: viewportSize, settings: settings,
            renditionSpread: renditionSpread,
            layoutCSS: settings.layoutAffectingCSS(),
            themedCSSLight: settings.composedUserCSS(isDark: false),
            themedCSSDark: settings.composedUserCSS(isDark: true),
            fontScale: settings.fontScale,
            defaultFontCSS: settings.defaultFontCSS())
    }

    private init(viewportSize: CGSize, settings: EPUBReaderSettings,
                 renditionSpread: RenditionSpread, layoutCSS: String,
                 themedCSSLight: String, themedCSSDark: String,
                 fontScale: Double, defaultFontCSS: String) {
        // 見開き判定は基準余白(insets)の内容幅で行う。モード別余白
        // (spreadInsets)を入れても見開き/単ページの切替閾値が揺れないように
        let base = settings.insets
        let usesSpread = Self.plansSpread(
            viewportSize: viewportSize, settings: settings,
            renditionSpread: renditionSpread)
        // 実際の内容寸法は、そのモードの余白で算出(見開きは spreadInsets が
        // あればそちら、無ければ insets)
        let active = usesSpread ? (settings.spreadInsets ?? base) : base
        let size = CGSize(
            width: max(1, viewportSize.width - active.left - active.right),
            height: max(1, viewportSize.height - active.top - active.bottom))
        contentSize = size
        spread = usesSpread
        gutter = Double(Self.spreadGutter(forContentWidth: size.width))
        gap = settings.pageGap
        pagesPerScreen = spread ? 2 : 1
        self.layoutCSS = layoutCSS
        self.themedCSSLight = themedCSSLight
        self.themedCSSDark = themedCSSDark
        self.viewportSize = viewportSize
        insets = settings.insets
        spreadInsets = settings.spreadInsets
        columnMode = settings.columnMode
        allowsScriptedContent = settings.allowsScriptedContent
        self.fontScale = fontScale
        self.defaultFontCSS = defaultFontCSS
    }

    /// 基準余白後の内容幅と viewport の向きから見開きを計画する
    static func plansSpread(viewportSize: CGSize, settings: EPUBReaderSettings,
                            renditionSpread: RenditionSpread) -> Bool {
        let base = settings.insets
        let contentWidth = max(1, viewportSize.width - base.left - base.right)
        return usesSpread(
            contentWidth: contentWidth, columnMode: settings.columnMode,
            renditionSpread: renditionSpread,
            isLandscapeViewport: viewportSize.width > viewportSize.height)
    }

    /// この内容幅で見開きにするか。明示 columnMode を最優先し、auto の
    /// ときだけ著者の rendition:spread と viewport の向きを採用する
    static func usesSpread(contentWidth: CGFloat,
                           columnMode: EPUBColumnMode,
                           renditionSpread: RenditionSpread,
                           isLandscapeViewport: Bool) -> Bool {
        switch columnMode {
        case .single: false
        case .double: true
        case .auto:
            switch renditionSpread {
            case .none: false
            case .both: true
            case .landscape: isLandscapeViewport && contentWidth >= 700
            case .auto: contentWidth >= 700
            }
        }
    }

    /// Returns equivalent metrics with an effective `rendition:spread`
    /// preference applied.
    public func applyingRenditionSpread(
        _ renditionSpread: RenditionSpread
    ) -> EPUBScreenMetrics {
        var settings = EPUBReaderSettings()
        settings.insets = insets
        settings.spreadInsets = spreadInsets
        settings.columnMode = columnMode
        settings.pageGap = gap
        settings.allowsScriptedContent = allowsScriptedContent
        return EPUBScreenMetrics(
            viewportSize: viewportSize, settings: settings,
            renditionSpread: renditionSpread, layoutCSS: layoutCSS,
            themedCSSLight: themedCSSLight, themedCSSDark: themedCSSDark,
            fontScale: fontScale, defaultFontCSS: defaultFontCSS)
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
            // cooViewer-oxr.25: ページ割り規則が変わったリリースでは、旧 census
            // を一度だけ無効化して同じ寸法でも再計測する。
            "engine": Self.paginationVersion,
            "width": Double(contentSize.width.rounded(.down)),
            "height": Double(contentSize.height.rounded(.down)),
            "gap": gap,
            "spread": spread,
            "gutter": gutter,
            "fixedLayout": false,
            "keysEnabled": false,
            // cooViewer-oxr.60 / cooViewer-oxr.76 / cooViewer-oxr.77:
            // runtime 計測値と著者 CSS より前の既定フォントを全描画経路で共有する。
            "fontScale": fontScale,
            "defaultFontCSS": defaultFontCSS,
            // cooViewer-oxr.75: 著者スクリプトの有無で DOM・ページ数が変わるため、
            // オフスクリーン構成と census キーの両方へ含める。
            "allowsScriptedContent": allowsScriptedContent,
            "userCSS": userCSS,
            // cooViewer-oxr.51: census はこの不透明な文脈から項目ごとの
            // spread と実効余白を再計算する。JS は未知キーを安全に無視する。
            "_washiMetrics": [
                "viewportWidth": Double(viewportSize.width),
                "viewportHeight": Double(viewportSize.height),
                "singleTop": insets.top,
                "singleLeft": insets.left,
                "singleBottom": insets.bottom,
                "singleRight": insets.right,
                "spreadTop": (spreadInsets ?? insets).top,
                "spreadLeft": (spreadInsets ?? insets).left,
                "spreadBottom": (spreadInsets ?? insets).bottom,
                "spreadRight": (spreadInsets ?? insets).right,
                "columnMode": columnMode.rawValue,
            ],
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: options, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// cooViewer-oxr.25: 永続化された census キーが現在のページ割り
    /// エンジン用かを検証する。
    static func usesCurrentPaginationVersion(_ metricsKey: String) -> Bool {
        struct VersionEnvelope: Decodable { let engine: Int }
        guard let data = metricsKey.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                VersionEnvelope.self, from: data)
        else { return false }
        return envelope.engine == paginationVersion
    }

    /// cooViewer-oxr.75: setup JSON から著者スクリプト許可を復元する。
    static func allowsScriptedContent(in optionsJSON: String) -> Bool {
        guard let data = optionsJSON.data(using: .utf8),
              let options = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return false }
        return options["allowsScriptedContent"] as? Bool ?? false
    }

    /// cooViewer-oxr.51: atlas/reader が共有する基底 JSON から、特定
    /// itemref の spread を反映した setup と WebView 寸法を導出する。
    static func setupPlan(
        optionsJSON: String,
        applying renditionSpread: RenditionSpread
    ) -> (optionsJSON: String, contentSize: CGSize) {
        guard let data = optionsJSON.data(using: .utf8),
              var options = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return (optionsJSON, .zero) }

        func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue
        }
        let fallbackSize = CGSize(
            width: number(options["width"]) ?? 0,
            height: number(options["height"]) ?? 0)
        guard let context = options["_washiMetrics"] as? [String: Any],
              let viewportWidth = number(context["viewportWidth"]),
              let viewportHeight = number(context["viewportHeight"]),
              let singleTop = number(context["singleTop"]),
              let singleLeft = number(context["singleLeft"]),
              let singleBottom = number(context["singleBottom"]),
              let singleRight = number(context["singleRight"]),
              let spreadTop = number(context["spreadTop"]),
              let spreadLeft = number(context["spreadLeft"]),
              let spreadBottom = number(context["spreadBottom"]),
              let spreadRight = number(context["spreadRight"]),
              let rawColumnMode = number(context["columnMode"]),
              let columnMode = EPUBColumnMode(rawValue: Int(rawColumnMode))
        else { return (optionsJSON, fallbackSize) }

        let baseContentWidth = max(1, viewportWidth - singleLeft - singleRight)
        let usesSpread = usesSpread(
            contentWidth: baseContentWidth,
            columnMode: columnMode,
            renditionSpread: renditionSpread,
            isLandscapeViewport: viewportWidth > viewportHeight)
        let horizontalInsets = usesSpread
            ? spreadLeft + spreadRight : singleLeft + singleRight
        let verticalInsets = usesSpread
            ? spreadTop + spreadBottom : singleTop + singleBottom
        let size = CGSize(width: max(1, viewportWidth - horizontalInsets),
                          height: max(1, viewportHeight - verticalInsets))
        options["width"] = Double(size.width.rounded(.down))
        options["height"] = Double(size.height.rounded(.down))
        options["spread"] = usesSpread
        options["gutter"] = Double(spreadGutter(forContentWidth: size.width))
        guard let derived = try? JSONSerialization.data(
            withJSONObject: options, options: [.sortedKeys])
        else { return (optionsJSON, fallbackSize) }
        return (String(data: derived, encoding: .utf8) ?? optionsJSON, size)
    }
}
