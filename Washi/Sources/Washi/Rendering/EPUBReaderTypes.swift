import AppKit
import Foundation
// EPUBLocator は解析層(WashiCore)へ移動した(EPUBPublication.resolve が使い、
// 表示層に依存しない値型のため)。@_exported 再輸出で import Washi からも見える

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

/// Reader display settings.
public struct EPUBReaderSettings: Sendable, Equatable {
    /// Base font-size multiplier (applied as an html font-size %). The valid
    /// range is EPUBReaderView.fontScaleRange (0.5 to 3.0).
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
    /// Whether to show the running head (book/chapter title) and folio (page
    /// number) in the margins.
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
    /// Page background CSS color (nil = theme default).
    public var backgroundColorCSS: String?
    /// Body text CSS color (nil = theme default).
    public var textColorCSS: String?
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
    /// When true, right-click (and control-click) does not open the web view's
    /// context menu, so the host can provide its own. Default false.
    public var suppressesContextMenu = false

    public init() {}

    /// テーマの実効配色(ライト = 紙白、ダーク = Apple Books 系の
    /// ほぼ黒 + 明灰文字)。明示指定(backgroundColorCSS 等)が最優先
    func effectiveColors(isDark: Bool) -> (background: String, text: String?) {
        let background = backgroundColorCSS ?? (isDark ? "#1a1a1c" : "#ffffff")
        let text = textColorCSS ?? (isDark ? "#d5d5d0" : nil)
        return (background, text)
    }

    /// フォントサイズ・既定フォントの CSS(ページ割りに影響する部分)
    private func fontCSS() -> String {
        var css = ""
        if fontScale != 1.0 {
            css += "html { font-size: \(Int((fontScale * 100).rounded()))% !important; }\n"
            // body が絶対値(medium・px 等)で font-size を固定する本
            // (ワープロ産に多い)にもルート倍率が波及するよう、body を
            // ルート相対へ正規化する。倍率 1.0(既定)では一切注入しないので
            // 本の設計どおり。!important なしの後置注入のため、より具体的な
            // セレクタの指定は本が勝つ。トレードオフ: body{font-size:62.5%}
            // 等の相対指定も 1rem に潰れる(主要リーダーと同じ割り切り。
            // 倍率を 1.0 に戻せば常に本の設計どおりに復帰する)
            css += "body { font-size: 1rem; }\n"
        }
        if let family = defaultFontFamily, !family.isEmpty {
            // !important なし + html レベル = 継承でしか効かないため、
            // 「本が指定しなかったときだけ」の既定フォントになる。
            // 値は CSS 文字列としてエスケープ(defaults 直書きの任意文字列で
            // 規則が壊れたり CSS が注入されたりしないように)
            let escaped = family
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            css += "html { font-family: \"\(escaped)\", serif; }\n"
        }
        return css
    }

    /// ページ割りに影響する CSS だけを組み立てる(census 用。
    /// 配色はページ数に影響しないため含めない — テーマ切替で census を
    /// 無駄に無効化しないためのキー安定化)
    func layoutAffectingCSS() -> String {
        fontCSS() + (userCSS ?? "")
    }

    /// 注入するユーザー CSS を組み立てる
    func composedUserCSS(isDark: Bool) -> String {
        var css = fontCSS()
        let colors = effectiveColors(isDark: isDark)
        css += ":root { color-scheme: \(isDark ? "dark" : "light"); }\n"
        css += "html { background-color: \(colors.background) !important; }\n"
        if let text = colors.text {
            // body への継承指定のみ(本文が色指定を持つ本はそちらが勝つ)。
            // リンクはダークで読める青へ
            css += "body { color: \(text); }\n"
            if isDark {
                css += "a { color: #7fb2ff; }\n"
            }
        }
        if let extra = userCSS {
            css += extra
        }
        return css
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
/// 3/4 = side). Right-clicks are not reported, as they are left to WebKit's
/// context menu.
public struct EPUBClickEvent: Sendable, Equatable {
    /// Normalized coordinates in 0..1.
    public let x: Double
    public let y: Double
    public let button: Int
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool

    /// Whether this is a left click with no modifier keys (the target of the
    /// default edge-tap page turn).
    public var isPlainPrimary: Bool {
        button == 0 && !shift && !option && !control && !command
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
}

public extension EPUBReaderViewDelegate {
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {}
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {}
    func readerView(_ view: EPUBReaderView,
                    shouldOpenExternalURL url: URL) -> Bool { true }
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {}
    func readerView(_ view: EPUBReaderView,
                    didReceiveNativeKey event: NSEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    didClick event: EPUBClickEvent) -> Bool { false }
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
}
