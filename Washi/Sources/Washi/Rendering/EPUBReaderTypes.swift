import AppKit
import Foundation
// EPUBLocator は解析層(WashiCore)へ移動した(EPUBPublication.resolve が使い、
// 表示層に依存しない値型のため)。@_exported 再輸出で import Washi からも見える

/// The exact landing position of a text range in a reflowable spine item.
public struct EPUBTextRangeLanding: Sendable {
    /// Zero-based page containing the beginning of the range.
    public let pageInItem: Int
    /// The normalized extracted-text slice the range represents (what the
    /// caller asked for), not the raw DOM text of the range.
    public let text: String
    /// Range fragments converted into the reader view's coordinate system.
    public let rects: [CGRect]
}

/// Content insets (a custom type because NSEdgeInsets is neither Equatable
/// nor Sendable).
public struct EPUBReaderInsets: Sendable, Equatable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0,
                bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = EPUBReaderInsets()
}

/// Color theme. system follows the view's effective appearance (light/dark).
public enum EPUBReaderTheme: Int, Sendable {
    case system = 0
    case light = 1
    case dark = 2
}

/// Built-in styles for the page-turn effect.
public enum EPUBPageTurnStyle: Sendable, Equatable {
    case none
    /// Cross-fade.
    case fade
    /// The old page slides out in the physical direction (away from the
    /// binding).
    case slide
}

/// Policy for two-page (spread) display. auto switches automatically based on
/// window width (the same idea as Apple Books' 1/2-page decision).
public enum EPUBColumnMode: Int, Sendable {
    case auto = 0
    case single = 1
    case double = 2
}

/// A device-independent sRGB color used by reader settings.
public struct EPUBRGBAColor: Sendable, Equatable, Codable {
    /// Red component in the closed range `0...1`.
    public var r: Double
    /// Green component in the closed range `0...1`.
    public var g: Double
    /// Blue component in the closed range `0...1`.
    public var b: Double
    /// Alpha component in the closed range `0...1`.
    public var a: Double

    /// Creates an sRGB color. Components are clamped to `0...1`.
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
        self.a = Self.clamp(a)
    }

    /// Creates an sRGB color from a Core Graphics color.
    public init(cgColor: CGColor) {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let converted = colorSpace.flatMap {
            cgColor.converted(to: $0, intent: .defaultIntent, options: nil)
        } ?? cgColor
        let components = converted.components ?? []
        if components.count >= 4 {
            self.init(r: Double(components[0]), g: Double(components[1]),
                      b: Double(components[2]), a: Double(components[3]))
        } else if components.count >= 2 {
            self.init(r: Double(components[0]), g: Double(components[0]),
                      b: Double(components[0]), a: Double(components[1]))
        } else {
            self.init(r: 0, g: 0, b: 0, a: 1)
        }
    }

    /// A CSS `rgba()` representation of this color.
    public var cssString: String {
        "rgba(\(r * 255), \(g * 255), \(b * 255), \(a))"
    }

    private static func clamp(_ component: Double) -> Double {
        guard component.isFinite else { return 0 }
        return min(1, max(0, component))
    }
}

/// Controls which contextual actions WebKit passes to the reader delegate.
///
/// The policy filters WebKit's menu before
/// ``EPUBReaderViewDelegate/readerView(_:willShowContextMenu:at:)`` is called.
/// When a delegate is installed, it is called exactly once for every context-menu
/// event, including when filtering leaves no items and when the policy is
/// ``suppressed``. A delegate return value of `nil` or an empty menu suppresses
/// presentation. A non-empty returned menu is presented even under ``suppressed``.
public enum EPUBContextMenuPolicy: Sendable, Equatable {
    /// Uses WebKit's complete system menu.
    case system
    /// Removes every WebKit-provided item before delegate customization.
    case suppressed
    /// Keeps only menu items whose identifier raw values are allowed.
    case allowing(identifiers: Set<String>)

    /// A reading-oriented menu containing lookup, translation, copy, web
    /// search, and speech actions when those actions are available.
    public static let readingDefault: EPUBContextMenuPolicy = .allowing(
        identifiers: [
            "WKMenuItemIdentifierLookUp",
            "WKMenuItemIdentifierTranslate",
            "WKMenuItemIdentifierCopy",
            "WKMenuItemIdentifierSearchWeb",
            "WKMenuItemIdentifierSpeechMenu",
        ])
}

extension EPUBContextMenuPolicy {
    /// cooViewer-oxr.35: WebKit が組み立てた menu を identifier だけで絞る。
    /// 許可済み submenu は中身を保ち、識別子のない wrapper は許可された子が
    /// 残る場合だけ保持する。
    @MainActor
    func filter(_ menu: NSMenu) -> Bool {
        switch self {
        case .system:
            return !menu.items.isEmpty
        case .suppressed:
            menu.removeAllItems()
            return false
        case .allowing(let identifiers):
            filter(menu, identifiers: identifiers)
            trimSeparators(in: menu)
            return !menu.items.isEmpty
        }
    }

    @MainActor
    private func filter(_ menu: NSMenu, identifiers: Set<String>) {
        for item in menu.items.reversed() {
            if item.isSeparatorItem { continue }
            if let identifier = item.identifier?.rawValue,
               identifiers.contains(identifier) {
                continue
            }
            if let submenu = item.submenu {
                filter(submenu, identifiers: identifiers)
                trimSeparators(in: submenu)
                if !submenu.items.isEmpty { continue }
            }
            menu.removeItem(item)
        }
    }

    @MainActor
    private func trimSeparators(in menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem {
                if previousWasSeparator { menu.removeItem(item) }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
        }
        if let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}

/// Reader display settings.
public struct EPUBReaderSettings: Sendable, Equatable {
    /// Base font-size multiplier applied to the book's computed root font size
    /// during pagination. The valid range is EPUBReaderView.fontScaleRange
    /// (0.5 to 3.0).
    public var fontScale: Double = 1.0
    /// Gap between pages in px (prevents glyphs from the adjacent page
    /// bleeding through; 0 still works).
    public var pageGap: Double = 24
    /// Content insets. The WKWebView itself is inset, keeping the multicol
    /// coordinate system simple. The margins are painted as the native
    /// background, and each page's folio (page number) sits in the bottom
    /// margin — mirroring Apple Books' page-layout design. Not applied to
    /// fixed-layout (FXL) pages (which display full-bleed).
    ///
    /// This is the base value, used for single-page display and as the default
    /// for spread display; set ``spreadInsets`` to give the spread (two-up)
    /// layout different margins.
    public var insets = EPUBReaderInsets(top: 56, left: 56, bottom: 52, right: 56)
    /// Content insets used in spread (two-up) display. When nil (the default),
    /// spread display uses ``insets``. Set it to give the two-page layout its
    /// own margins — e.g. wider outer margins on a large window. The center
    /// gutter between the two pages is added automatically on top of these.
    public var spreadInsets: EPUBReaderInsets?
    /// Spread-display policy (default: automatic, based on window width).
    public var columnMode: EPUBColumnMode = .auto
    /// Color theme (default: follows the system appearance).
    public var theme: EPUBReaderTheme = .system
    /// Whether to show the folio (page number) centered in each page's bottom
    /// margin.
    public var showsPageFurniture = true
    /// The page-turn effect (automatically skipped when "Reduce Motion" is on
    /// and during rapid repeated presses). The delegate's animatePageTurn can
    /// replace it with a host-specific effect (page curl, etc.).
    public var pageTurnStyle: EPUBPageTurnStyle = .slide
    /// Whether pinch gestures change the font multiplier (even when off,
    /// adjustFontScale(by:) and directly setting settings.fontScale still
    /// work).
    public var pinchAdjustsFontScale = true
    /// Default font used when the book does not specify a font-family (a CSS
    /// family name; nil = WebKit default). Injected at the html level without
    /// !important, so the book's own declarations (e.g. the EBPAJ / 電書協
    /// template) always win.
    public var defaultFontFamily: String?
    /// Approximate multiplier for line height. Washi applies the multiplier to
    /// a `1.6` fallback because CSS cannot recover every authored computed
    /// line-height as a reusable value.
    public var lineHeightScale: Double?
    /// Additional letter spacing in em. It is intentionally ignored in
    /// vertical writing, following Readium CSS guidance for CJK content.
    public var letterSpacingEm: Double?
    /// Paragraph block-end spacing in em.
    public var paragraphSpacingEm: Double?
    /// Font family that overrides authored fonts except in code-like elements.
    public var fontFamilyOverride: String?
    /// Whether ruby annotations and fallback parentheses are removed from
    /// layout. Default is false.
    public var hidesRuby = false
    /// Page background CSS color (nil = theme default).
    public var backgroundColorCSS: String?
    /// Typed page background color. When set, this takes precedence over
    /// ``backgroundColorCSS`` for both web content and native margins.
    public var backgroundColor: EPUBRGBAColor?
    /// Body text CSS color (nil = theme default).
    public var textColorCSS: String?
    /// Typed body text color. When set, this takes precedence over
    /// ``textColorCSS``.
    public var textColor: EPUBRGBAColor?
    /// When true, the reader forces its theme's text color onto the book's
    /// content, overriding the book's own color declarations (via `!important`),
    /// so pages stay legible against the themed background — the "prioritize
    /// readability" mode. When false (default), the book's own colors win and
    /// the theme only supplies a fallback (respect-the-book mode). Ignored when
    /// ``textColor`` or ``textColorCSS`` supplies an explicit host color.
    /// Trade-off: a book's intentional colors and light-background call-outs
    /// may lose contrast, so expose it as a user choice.
    public var forcesReadableColors = false
    /// Whether EPUB footnote and endnote asides are hidden from the paginated
    /// flow. Hosts can intercept a noteref and present ``EPUBNoteContent`` in
    /// a popover instead. Default is false.
    public var hidesFootnoteAsides = false
    /// Whether dark themes invert small inline images that look like glyphs.
    ///
    /// Washi recognizes common `gaiji`, `kigou`, and `glyph` classes, plus
    /// small inline images whose rendered size is close to the surrounding
    /// text. The heuristic intentionally excludes figures and single-image
    /// pages, but a small illustration can still be misclassified; set this
    /// to false when a publication needs its original image colors. Default
    /// is true.
    public var invertsGlyphImagesInDark = true
    /// Additional user CSS (injected last).
    public var userCSS: String?
    /// When true, default key actions (arrows, space, etc.) are handled within
    /// the view. When false, keys are forwarded to the delegate (giving the
    /// host's key bindings priority).
    public var handlesKeyboardNavigation = true
    /// When true, the view installs a native key monitor and forwards each
    /// `NSEvent` key-down to `readerView(_:didReceiveNativeKey:)` before the
    /// embedded `WKWebView` can consume it. Use this instead of the JS-based
    /// `didReceiveKey` path when the host has its own key bindings and needs
    /// reliable, in-order `NSEvent`s (the JS path silently drops keys whenever
    /// the web view holds first responder). Independent of
    /// `handlesKeyboardNavigation`. Default false.
    public var forwardsKeyEventsNatively = false
    /// Whether to allow scripted content (the book's JavaScript). Default
    /// false.
    public var allowsScriptedContent = false
    /// Context-menu policy. A non-system policy takes precedence over the
    /// legacy ``suppressesContextMenu`` switch when both are configured.
    public var contextMenuPolicy: EPUBContextMenuPolicy = .system
    /// When true, right-click (and control-click) does not open the web view's
    /// context menu, so the host can provide its own. Default false. This is
    /// treated as ``EPUBContextMenuPolicy/suppressed`` while
    /// ``contextMenuPolicy`` is ``EPUBContextMenuPolicy/system``.
    public var suppressesContextMenu = false
    /// Whether settled page changes are announced while VoiceOver is active.
    /// Default is true.
    public var announcesPageChanges = true
    /// Whether the current print page label is appended to native page
    /// furniture. Default is false.
    public var showsPrintPageInFurniture = false
    /// When true, a primary click is reported only after the system
    /// double-click interval so a double-click that selects a word never turns
    /// the page first; costs that much latency per tap.
    public var defersTapsForDoubleClick = false
    /// When true (default), a horizontal trackpad/wheel gesture turns one page.
    /// Set false when the host drives horizontal swipe page-turns itself (so the
    /// two do not both fire, and the host's "swipe turns pages" preference is
    /// honored). Vertical wheel scrolling through paginated content is
    /// unaffected either way.
    public var horizontalWheelTurnsPages = true
    /// Inverts the reading direction of horizontal trackpad/wheel page turns.
    /// By default a leftward gesture turns toward the left-hand page (physical
    /// mapping via the book's writing direction). The host sets this to align
    /// wheel turns with its own swipe-direction preference and, in a merged
    /// collection whose reading order differs from an individual volume, with
    /// the collection's direction. Default false.
    public var reversesHorizontalWheelTurn = false

    public init() {}

    /// テーマの実効配色(ライト = 紙白、ダーク = Apple Books 系の
    /// ほぼ黒 + 明灰文字)。明示指定(backgroundColorCSS 等)が最優先
    func effectiveColors(
        isDark: Bool, increaseContrast: Bool = false
    ) -> (background: String, text: String?) {
        if increaseContrast {
            // cooViewer-oxr.37: システムのコントラスト増加時は著者・host の
            // 中間色より純黒/純白を優先し、背景と本文を同じ経路で決める。
            return isDark ? ("#000000", "#ffffff")
                          : ("#ffffff", "#000000")
        }
        let background = backgroundColor?.cssString
            ?? backgroundColorCSS ?? (isDark ? "#1a1a1c" : "#ffffff")
        let text: String?
        if let explicit = textColor?.cssString ?? textColorCSS {
            text = explicit
        } else if forcesReadableColors {
            // 読みやすさ優先: 本が色を指定していても、テーマ背景に対して確実に
            // 読める文字色を両モードで用意する(Apple Books のダーク相当)
            text = isDark ? "#ececec" : "#1a1a1a"
        } else {
            // 本の配色を尊重: ダークだけ継承用の明灰を用意(本が色指定を持つ
            // ページはそちらが勝つ=本来の見た目のまま)
            text = isDark ? "#d5d5d0" : nil
        }
        return (background, text)
    }

    /// CSS-string escaping shared by the default and overriding font settings.
    private func escapedFontFamily(_ family: String) -> String {
        let stripped = family.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                && $0 != "\u{2028}" && $0 != "\u{2029}"
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// fontScale を CSS で上書きせず census/layout key だけへ反映する印。
    /// 実倍率は cooViewer-oxr.60 / cooViewer-oxr.76 の runtime 計測で適用する。
    private func fontScaleKeyCSS() -> String {
        guard fontScale != 1.0 else { return "" }
        return "/* washi-font-scale: \(fontScale) */\n"
    }

    /// cooViewer-oxr.32: namespace 宣言は同じ stylesheet の全規則より前に置く。
    /// aside の非表示は本文量を変えるため、注入 CSS と census key で共用する。
    private func footnoteVisibilityCSS() -> String {
        guard hidesFootnoteAsides else { return "" }
        return """
        @namespace epub url(http://www.idpf.org/2007/ops);
        aside[epub|type~="footnote"], aside[epub|type~="endnote"], aside[epub|type~="rearnote"], aside[role="doc-footnote"], aside[role="doc-endnote"] { display: none !important; }

        """
    }

    /// 著者 stylesheet より前へ挿入する既定フォント CSS。
    /// 最初の cascade layer + :where の詳細度 0 で、cooViewer-oxr.77 の
    /// 「本が常に勝つ」を layered stylesheet に対しても守る。
    func defaultFontCSS() -> String {
        var css = ""
        if let family = defaultFontFamily, !family.isEmpty {
            // !important なし + :where(html) = 継承でしか効かないため、
            // 「本が指定しなかったときだけ」の既定フォントになる。
            // 値は CSS 文字列としてエスケープ(defaults 直書きの任意文字列で
            // 規則が壊れたり CSS が注入されたりしないように)。改行・制御文字は
            // CSS 文字列トークンを終端させ後続を新規規則として注入できてしまう
            // ため、エスケープ前に除去する(U+2028/2029 は controlCharacters に
            // 含まれないので明示除去。CJK フォント名を通すため allowlist は使わない)
            let escaped = escapedFontFamily(family)
            css += "@layer washi-reader-default { :where(html) { font-family: \"\(escaped)\", serif; } }\n"
        }
        return css
    }

    /// cooViewer-oxr.33: 文字組み設定はすべて本文量または字送りを変えるため、
    /// live CSS と census key が同じ文字列を共有する。
    private func typographyCSS() -> String {
        var css = ""
        if let scale = lineHeightScale, scale.isFinite, scale > 0 {
            css += "html { --washi-line-height-scale: \(scale); }\n"
            css += "body * { line-height: calc(var(--washi-line-height-base, 1.6) * var(--washi-line-height-scale)) !important; }\n"
        }
        if let spacing = letterSpacingEm, spacing.isFinite {
            // cooViewer-oxr.33: 縦組みでは字間・単語間を強制しない。
            css += "html:not(.washi-vertical) body, html:not(.washi-vertical) body * { letter-spacing: \(spacing)em !important; }\n"
        }
        if let spacing = paragraphSpacingEm, spacing.isFinite {
            css += "p { margin-block-end: \(spacing)em !important; }\n"
        }
        if let family = fontFamilyOverride, !family.isEmpty {
            let escaped = escapedFontFamily(family)
            css += "body, body *:not(code):not(pre):not(kbd):not(samp) { font-family: \"\(escaped)\", serif !important; }\n"
        }
        if hidesRuby {
            css += "rt, rp { display: none !important; }\n"
        }
        return css
    }

    /// ページ割りに影響する CSS だけを組み立てる(census 用。
    /// 配色はページ数に影響しないため含めない — テーマ切替で census を
    /// 無駄に無効化しないためのキー安定化)
    func layoutAffectingCSS() -> String {
        footnoteVisibilityCSS() + fontScaleKeyCSS() + typographyCSS()
            + (userCSS ?? "")
    }

    /// 注入するユーザー CSS を組み立てる
    func composedUserCSS(
        isDark: Bool, increaseContrast: Bool = false,
        differentiateWithoutColor: Bool = false
    ) -> String {
        var css = footnoteVisibilityCSS() + fontScaleKeyCSS() + typographyCSS()
        let colors = effectiveColors(
            isDark: isDark, increaseContrast: increaseContrast)
        css += ":root { color-scheme: \(isDark ? "dark" : "light"); }\n"
        css += "html { background-color: \(colors.background) !important; }\n"
        // cooViewer-oxr.4: ダークでは本の body の白背景でテーマの地色を覆わない。
        // 本の配色を尊重するライトでは、クリーム色など本来の body 背景を保つ。
        // 読みやすさ優先では両テーマで子孫の不透明背景も除くが、画像等の背景は保つ。
        let readable = increaseContrast
            || (forcesReadableColors && textColor == nil && textColorCSS == nil)
        if readable {
            css += "body, body *:not(img):not(svg):not(image):not(video):not(canvas) { background-color: transparent !important; }\n"
            if isDark {
                // cooViewer-oxr.4: 透明化規則の :not による詳細度も上回る必要がある。
                css += "body :is(pre, code):not(img):not(svg):not(image):not(video):not(canvas) { background-color: #242426 !important; }\n"
            }
        } else if isDark {
            css += "body { background-color: transparent !important; }\n"
        }
        if let text = colors.text {
            if readable {
                // 読みやすさ優先: 本の色指定(class・要素セレクタ等)より強く
                // 上書きして必ず読める色に(!important で継承の壁を越える)。
                // cooViewer-oxr.4: リンクの span/ruby とコードの子孫も除外し、
                // リンクの継承色・コード固有の配色を保つ。
                css += "body, body *:not(a):not(a *):not(pre):not(code):not(pre *):not(code *) { color: \(text) !important; }\n"
                css += "a { color: \(isDark ? "#7fb2ff" : "#1a56db") !important; }\n"
            } else {
                // 本の配色を尊重: body への継承指定のみ(本文が色指定を持つ本は
                // そちらが勝つ)。リンクはダークで読める青へ
                css += "body { color: \(text); }\n"
                if isDark {
                    css += "a { color: #7fb2ff; }\n"
                }
            }
        }
        if isDark {
            // cooViewer-oxr.78: 写真や挿絵を反転せず、JS が字形と判定した
            // 小さなインライン画像だけを対象にする。filter は配色だけを変え、
            // 版面寸法には影響しない。
            if invertsGlyphImagesInDark {
                css += "img.washi-glyph { filter: invert(1) !important; }\n"
            }
            // cooViewer-oxr.78: fill 未指定の最外 SVG だけを currentColor へ
            // 揃え、子孫へ継承させる。子要素へ直接指定すると祖先の fill="none"
            // や明示色を上書きするため、入れ子 SVG も祖先色をそのまま継承する。
            let strength = readable ? " !important" : ""
            css += ":where(svg:not(svg *):not([fill]):not([style*=\"fill\" i])) { fill: currentColor\(strength); }\n"
            css += ":where(svg:is([stroke=\"black\" i], [stroke=\"#000\" i], [stroke=\"#000000\" i]), svg :is([stroke=\"black\" i], [stroke=\"#000\" i], [stroke=\"#000000\" i])) { stroke: currentColor\(strength); }\n"
        }
        if differentiateWithoutColor {
            // cooViewer-oxr.37: 色だけに依存せずリンクを識別できるようにする。
            css += "a { text-decoration: underline !important; }\n"
        }
        if let extra = userCSS {
            css += extra
        }
        return css
    }
}

/// A text selection in the normalized UTF-16 text map of one spine item.
public struct EPUBTextSelection: Sendable, Equatable {
    /// Reading-order spine index containing the selection.
    public let spineIndex: Int
    /// Selected normalized text.
    public let text: String
    /// Selected range in normalized UTF-16 code units.
    public let utf16Range: Range<Int>
    /// Selection fragments in reader-view coordinates.
    public let rects: [CGRect]

    public init(spineIndex: Int, text: String, utf16Range: Range<Int>,
                rects: [CGRect]) {
        self.spineIndex = spineIndex
        self.text = text
        self.utf16Range = utf16Range
        self.rects = rects
    }
}

/// A key event forwarded to the host (when handlesKeyboardNavigation is
/// false).
public struct EPUBKeyEvent: Sendable, Equatable {
    public let key: String
    public let code: String
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool
}

/// Details of a click on the page surface (forwarded to the delegate).
/// button uses NSEvent-style numbering (0 = left, 1 = right, 2 = middle,
/// 3/4 = side). Right-clicks are not sent through the regular `didClick`
/// callback; they are represented by the event passed to the context-menu
/// delegate callback instead.
public struct EPUBClickEvent: Sendable, Equatable {
    /// Normalized coordinates in 0..1.
    public let x: Double
    public let y: Double
    /// Click location in the coordinate system of the reader view.
    public let locationInView: CGPoint
    public let button: Int
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool

    public init(x: Double, y: Double, locationInView: CGPoint,
                button: Int, shift: Bool, option: Bool,
                control: Bool, command: Bool) {
        self.x = x
        self.y = y
        self.locationInView = locationInView
        self.button = button
        self.shift = shift
        self.option = option
        self.control = control
        self.command = command
    }

    /// Whether this is a left click with no modifier keys (the target of the
    /// default edge-tap page turn).
    public var isPlainPrimary: Bool {
        button == 0 && !shift && !option && !control && !command
    }
}

/// A resolved link from one EPUB reading-order document to another location
/// in the same publication.
public struct EPUBInternalLink: Sendable, Equatable {
    /// The href exactly as declared by the publication.
    public let href: String
    /// The canonical container path resolved relative to the current document.
    public let containerPath: String
    /// The decoded fragment identifier, when present.
    public let fragment: String?
    /// The destination's index in the publication reading order, when present.
    public let targetSpineIndex: Int?
    /// The clicked anchor's `epub:type` value.
    public let epubType: String?
    /// The clicked anchor's ARIA role.
    public let role: String?
    /// Whether the anchor is an EPUB or ARIA note reference.
    public let isNoteReference: Bool
    /// Whether a same-document note target contains a link back to the anchor.
    public let hasBacklink: Bool
    /// The same-document target's `epub:type` value, when available.
    public let targetEpubType: String?
    /// The clicked anchor's bounds in the reader view's coordinate system.
    public let anchorRect: CGRect?

    public init(
        href: String,
        containerPath: String,
        fragment: String?,
        targetSpineIndex: Int?,
        epubType: String?,
        role: String?,
        isNoteReference: Bool,
        hasBacklink: Bool,
        targetEpubType: String?,
        anchorRect: CGRect?
    ) {
        self.href = href
        self.containerPath = containerPath
        self.fragment = fragment
        self.targetSpineIndex = targetSpineIndex
        self.epubType = epubType
        self.role = role
        self.isNoteReference = isNoteReference
        self.hasBacklink = hasBacklink
        self.targetEpubType = targetEpubType
        self.anchorRect = anchorRect
    }
}

/// Text and optional markup extracted from an EPUB note target.
public struct EPUBNoteContent: Sendable, Equatable {
    /// Human-readable note text with backlink anchors removed.
    public let text: String
    /// Inner HTML with backlink anchors removed for a note in the currently
    /// displayed document. Cross-document extraction is headless and returns
    /// nil here.
    public let html: String?
    /// Index of the document containing the note in the reading order.
    public let sourceSpineIndex: Int

    public init(text: String, html: String?, sourceSpineIndex: Int) {
        self.text = text
        self.html = html
        self.sourceSpineIndex = sourceSpineIndex
    }
}

/// Receiver of the reader view's event notifications.
@MainActor
public protocol EPUBReaderViewDelegate: AnyObject {
    /// The displayed position changed (page turn, chapter move, or restore).
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int)
    /// An attempt to move past the start/end of the book (forward = true is
    /// the end side).
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool)
    /// About to open an external link. Return true for the default action
    /// (open in the browser).
    func readerView(_ view: EPUBReaderView, shouldOpenExternalURL url: URL) -> Bool
    /// Asks whether a resolved internal EPUB link should use the reader's
    /// default navigation. Return false to show a note or handle it yourself.
    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool
    /// Key forwarding, used when handlesKeyboardNavigation is false.
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent)
    /// A native key-down event, delivered only when
    /// `EPUBReaderSettings.forwardsKeyEventsNatively` is true. Return true to
    /// consume the event (the web view never sees it); return false to let it
    /// propagate normally. Preferred over `didReceiveKey` for hosts with their
    /// own key bindings — it is a real `NSEvent`, in order, and reaches you even
    /// while the web view holds first responder.
    ///
    /// The monitor runs before the responder chain, so returning true also
    /// suppresses menu key equivalents (⌘C, ⌘W, …) for that event. Return true
    /// only for keys your host actually handles; return false for the rest.
    func readerView(_ view: EPUBReaderView,
                    didReceiveNativeKey event: NSEvent) -> Bool
    /// A click on the page surface (non-link: left/middle/side buttons, with
    /// modifier keys). Return true if handled; false for the default action
    /// (only the left/right edge-tap page turn on an unmodified left click).
    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool
    /// The normalized text selection changed.
    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?)
    /// Gives the host a final opportunity to customize a policy-filtered context
    /// menu. This method is called exactly once for every context-menu event,
    /// including when the filtered menu is empty and when the policy is
    /// ``EPUBContextMenuPolicy/suppressed``. Return `nil` or an empty menu to
    /// suppress presentation. A non-empty returned menu is presented even under
    /// ``EPUBContextMenuPolicy/suppressed``.
    func readerView(_ view: EPUBReaderView, willShowContextMenu menu: NSMenu,
                    at event: EPUBClickEvent?) -> NSMenu?
    /// A file drop (which the host can use to "open another book", etc.).
    /// Return false to reject the drop.
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool
    /// The font multiplier changed via pinch, etc. (for the host to persist).
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double)
    /// Replace the page-turn effect with a host-specific one (page curl,
    /// etc.). oldPage/newPage are snapshots of the page area (pageRect, in the
    /// view's coordinate system). Add the overlay to the view **synchronously
    /// within this method** and return true (Washi removes the old page's
    /// cover as soon as this returns). Return false to use the built-in
    /// pageTurnStyle (slide/fade).
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool
    /// A load failure or similar error.
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error)
    /// The whole-book page-count measurement (census) was updated (completed
    /// or invalidated). See view.pageCensus / censusTotalPages /
    /// currentGlobalPageRange.
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView)
    /// Media-overlay (SMIL) playback started or paused/stopped. Use it to keep
    /// a play/pause control in sync.
    func readerView(_ view: EPUBReaderView,
                    isPlayingMediaOverlayDidChange isPlaying: Bool)
    /// Media-overlay playback reached the end of the book (nothing more to play).
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView)
    /// Navigation-history availability changed. Read ``EPUBReaderView/canGoBack``
    /// to update a Back command or control.
    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView)
    /// The resolved print page label changed.
    func readerView(_ view: EPUBReaderView,
                    didChangePrintPage label: String?)
}

public extension EPUBReaderViewDelegate {
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {}
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {}
    func readerView(_ view: EPUBReaderView,
                    shouldOpenExternalURL url: URL) -> Bool { true }
    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool { true }
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {}
    func readerView(_ view: EPUBReaderView,
                    didReceiveNativeKey event: NSEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    didClick event: EPUBClickEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    selectionDidChange selection: EPUBTextSelection?) {}
    func readerView(_ view: EPUBReaderView, willShowContextMenu menu: NSMenu,
                    at event: EPUBClickEvent?) -> NSMenu? { menu }
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double) {}
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {}
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {}
    func readerView(_ view: EPUBReaderView,
                    isPlayingMediaOverlayDidChange isPlaying: Bool) {}
    func readerViewMediaOverlayDidFinish(_ view: EPUBReaderView) {}
    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {}
    func readerView(_ view: EPUBReaderView,
                    didChangePrintPage label: String?) {}
}
