import AppKit
import OSLog
import WebKit

enum SpineNavigationDisposition: Equatable {
    case allowExpectedLoad
    case routeThroughReader
}

/// 自分で発行した spine ロードだけを一度 allow し、文書が発行した遷移は
/// reader の状態更新経路へ戻すための期待値管理
struct SpineNavigationGate {
    private var expectedPaths: [String] = []

    mutating func expect(_ path: String) {
        expectedPaths.append(path)
    }

    mutating func cancelExpectation(for path: String) {
        guard let index = expectedPaths.lastIndex(of: path) else { return }
        expectedPaths.remove(at: index)
    }

    mutating func disposition(for path: String,
                              navigationType: WKNavigationType)
        -> SpineNavigationDisposition {
        guard navigationType == .other,
              let index = expectedPaths.firstIndex(of: path) else {
            return .routeThroughReader
        }
        expectedPaths.remove(at: index)
        return .allowExpectedLoad
    }
}

/// cooViewer-oxr.47: WebContent 終了の再試行回数とバックオフを spine ごとに
/// 決定し、短時間のクラッシュループを有限にする。
struct WebContentReloadLimiter {
    enum Decision: Equatable {
        case reload(after: Duration)
        case suppress(reportFailure: Bool)
    }

    private struct Entry {
        var terminations: [Date] = []
        var didReportFailure = false
    }

    private var entries: [Int: Entry] = [:]
    private let window: TimeInterval
    private let delays: [Duration]

    init(window: TimeInterval = 60,
         delays: [Duration] = [.zero, .milliseconds(250), .seconds(1)]) {
        self.window = window
        self.delays = delays
    }

    mutating func register(spineIndex: Int, at now: Date = Date()) -> Decision {
        var entry = entries[spineIndex] ?? Entry()
        entry.terminations.removeAll {
            now.timeIntervalSince($0) >= window || now < $0
        }
        if entry.terminations.isEmpty {
            entry.didReportFailure = false
        }
        entry.terminations.append(now)

        let attempt = entry.terminations.count
        guard attempt <= delays.count else {
            let shouldReport = !entry.didReportFailure
            entry.didReportFailure = true
            entries[spineIndex] = entry
            return .suppress(reportFailure: shouldReport)
        }
        entries[spineIndex] = entry
        return .reload(after: delays[attempt - 1])
    }

    mutating func reset() {
        entries.removeAll()
    }
}

/// An EPUB reader view (WKWebView-based).
/// Reflowable content is drawn via `ReaderScripts` pagination; fixed-layout
/// content is aspect-fitted into its ICB (pageZoom + frame adjustment).
/// Margins are realized natively (inset placement of the webView + layer
/// background), which keeps the CSS multicol coordinate math simple.
@MainActor
public final class EPUBReaderView: NSView {
    private static let logger = Logger(
        subsystem: "org.cocoadialog.Washi", category: "EPUBReaderView")

    public private(set) var publication: EPUBPublication?
    public weak var delegate: (any EPUBReaderViewDelegate)?

    /// The current normalized text selection, or `nil` when the selection is
    /// empty or collapsed.
    public private(set) var currentSelection: EPUBTextSelection?

    /// Print page labels declared by the publication's page list, in document
    /// order.
    public var printPageLabels: [String] {
        flattenedPrintPageList.map(\.title)
    }

    /// The last print page marker at or before the settled reading position.
    public private(set) var currentPrintPage: String?

    public var settings = EPUBReaderSettings() {
        didSet {
            guard oldValue != settings else { return }
            let layoutChanged = layoutKey(for: oldValue) != layoutKey(for: settings)
            applyTheme()
            updateAccessibilityMetadata()
            if oldValue.announcesPageChanges && !settings.announcesPageChanges {
                accessibilityAnnouncementTask?.cancel()
                accessibilityAnnouncementTask = nil
            }
            if oldValue.forwardsKeyEventsNatively
                != settings.forwardsKeyEventsNatively {
                updateNativeKeyMonitor()
            }
            if oldValue.handlesKeyboardNavigation
                != settings.handlesKeyboardNavigation {
                // cooViewer-oxr.24: setup 後の切替も現在の文書へ即時反映する。
                evaluate("__washi.setKeysEnabled(\(settings.handlesKeyboardNavigation));")
            }
            if oldValue.defersTapsForDoubleClick
                != settings.defersTapsForDoubleClick {
                // cooViewer-oxr.27: ページ割りを伴わない入力設定も現在文書へ即時反映する。
                updateTapDeferral()
            }
            if oldValue.allowsScriptedContent != settings.allowsScriptedContent {
                // JS 許可はビュー構成ごと作り直す(WKWebViewConfiguration は不変)
                reloadCurrentPublication()
            } else if layoutChanged {
                // cooViewer-oxr.24: 個別フィールド列挙ではなく census と同じ
                // 導出キーを正とし、userCSS を含む変更漏れを防ぐ。
                needsLayout = true
                schedulePagination(preserveProgression: true)
            } else {
                // 配色・めくり演出・柱の表示などはページ割りを保ったまま反映
                applyThemeCSSOnly()
                updateFurniture()
            }
        }
    }

    private var webView: WKWebView?
    private var schemeHandler: EPUBSchemeHandler?
    private var messageProxy: MessageProxy?

    private struct PrintPageMarker: Equatable {
        let label: String
        let page: Int
    }
    private var printPageMarkers: [PrintPageMarker] = []

    /// cooViewer-oxr.37: テストは VoiceOver プロセスへ依存せず、確定した
    /// アナウンス文字列をこの seam で捕捉する。
    var accessibilityAnnouncementHandler: ((String) -> Void)?
    var accessibilityAnnouncementDelay: Duration = .milliseconds(150)
    var accessibilityPreferredLanguageOverride: String?
    var accessibilityIncreaseContrastOverride: Bool? {
        didSet { accessibilityDisplayOptionsDidChange() }
    }
    var accessibilityDifferentiateWithoutColorOverride: Bool? {
        didSet { accessibilityDisplayOptionsDidChange() }
    }
    private var accessibilityAnnouncementTask: Task<Void, Never>?
    private struct SettledPageIdentity: Equatable {
        let spineIndex: Int
        let page: Int
        let pageCount: Int
    }
    private var lastAnnouncedPage: SettledPageIdentity?

    /// ノンブル(各ページの下部中央に素のページ番号。Apple Books 風)。
    /// 見開き時は左右 1 つずつ、単ページ時は先頭だけ使う
    private let pageNumberLabels = [NSTextField(labelWithString: ""),
                                    NSTextField(labelWithString: "")]
    /// 現在ページが「画像 1 枚だけのページ」(表紙等)か。ノンブルを隠す
    private var isImagePage = false
    /// Run-time number of pages per screen (1 = single page / 2 = spread).
    /// Single-image pages report 1 even in spread mode; use
    /// ``plannedPagesPerScreen`` or ``toggleColumnMode()`` for a spread toggle.
    public private(set) var pagesPerScreen = 1

    /// Whether this WebKit supports the column-axis feature required for
    /// vertical two-page spreads. Unsupported engines fall back to one page.
    public private(set) var columnAxisSupported = true
    /// JS が実測した先頭読書スロット。OPF の綴じ方向と本文 CSS が食い違う本でも、
    /// 可視ページとネイティブのノンブルを同じ側へ置く(cooViewer-oxr.58)。
    private var firstPageOnRight = false

    /// Current position
    public private(set) var currentSpineIndex = 0
    public private(set) var pageInItem = 0
    public private(set) var pageCountInItem = 1
    private var isFixedLayoutItem = false

    /// Whether a previously recorded navigation position is available.
    public private(set) var canGoBack = false
    /// cooViewer-oxr.31: ページめくりとは分離したジャンプ履歴を有限に保つ。
    private var navigationHistory: [EPUBLocator] = []
    private static let navigationHistoryLimit = 50

    /// 読み込み完了時に適用する表示位置
    private enum PendingTarget {
        case start
        case end
        case progression(Double)
        case fragment(String)
        case textRange(utf16Offset: Int, utf16Length: Int, fallbackProgression: Double)
    }
    private var pendingTarget: PendingTarget = .start
    private struct PendingTextRangeRequest {
        let id: UUID
        let continuation: CheckedContinuation<EPUBTextRangeLanding?, Never>
    }
    private var pendingTextRangeRequest: PendingTextRangeRequest?
    private var textRangeTask: Task<Void, Never>?
    private var isSettingUp = false
    /// spine 項目の読み込み中(旧文書から届く境界イベントを捨てて
    /// 章の飛び越しを防ぐ)
    private var isLoadingSpineItem = false
    /// spine 読み込みの世代。loadSpineItem のたびに進める。
    /// runSetup は「開始時と各 await 後」に世代一致を確認し、高速なページ
    /// 送りで古いセットアップが新しい文書の状態(pendingTarget・
    /// isLoadingSpineItem・復元位置)を消費・破壊しないようにする
    private var spineLoadGeneration = 0
    /// 現在有効なナビゲーション(didFinish/didFail の遅延配達を、後続の
    /// loadSpineItem 後に古い文書ぶんとして無視するための同一性チェック)
    private var currentNavigation: WKNavigation?
    /// loadSpineItem 自身の .other と文書内遷移の .other を区別する
    private var spineNavigationGate = SpineNavigationGate()
    /// ネイティブキー横取りのローカルモニタ(forwardsKeyEventsNatively)
    private var keyEventMonitor: Any?
    /// メディアオーバーレイ(SMIL)再生エンジン(再生時に生成)
    var mediaOverlayController: MediaOverlayController?
    /// めくりアニメーションのオーバーレイ(spine 切替時に掃除)
    var turnOverlays: [NSView] = []
    /// 直前のめくり時刻(高速連打時はアニメーションを省略して即めくり)
    private var lastTurnDate = Date.distantPast
    /// セットアップ実行中に届いた再ページ割り要求(捨てずに後追い実行する)
    private var pendingRepaginate = false
    private var repaginateWork: Task<Void, Never>?
    private var lastLaidOutSize: CGSize = .zero
    /// cooViewer-oxr.54: 不可視中に畳んだレイアウトを、再表示時に一度だけ行う。
    private var pendingVisibleLayout = false
    /// 復元先(復元完了まで currentLocator の答えとして使う。復元前の保存で
    /// 位置が (0,0) に潰れるのを防ぐ)
    private var pendingRestoreLocator: EPUBLocator?
    /// FXL の viewport キャッシュ(layoutFixedItem がリサイズ毎に XHTML を
    /// 再パースしないため)
    private var fxlViewportCache: [Int: CGSize] = [:]
    /// cooViewer-oxr.50: device-* viewport は寸法でなく種別だけをキャッシュし、
    /// 実寸は毎回現在の表示領域から取る。
    private var fxlDeviceSizedViewportItems: Set<Int> = []

    /// WebContent 終了の再読み込みは同一 spine の短時間ループを有限にする。
    private var webContentReloadLimiter = WebContentReloadLimiter()
    private var pendingWebContentReloadDelay: Duration?
    private var webContentReloadTask: Task<Void, Never>?
    private(set) var webContentReloadRequestCount = 0
    private(set) var webContentReloadAttemptCount = 0
    var hasPendingWebContentReload: Bool {
        webContentReloadTask != nil || pendingWebContentReloadDelay != nil
    }

    static let washiWorld = WKContentWorld.world(name: "washi")  // census と共用

    /// 外部ネットワークを遮断するコンテンツルール(コンパイルは初回のみ)
    private static let contentRuleList: Task<WKContentRuleList?, Never> = Task { @MainActor in
        let json = """
        [
          {"trigger": {"url-filter": "https?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "wss?://.*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^washi-epub://.*"},
           "action": {"type": "ignore-previous-rules"}}
        ]
        """
        return try? await WKContentRuleListStore.default()?
            .compileContentRuleList(forIdentifier: "washi-network-lockdown",
                                    encodedContentRuleList: json)
    }

    // MARK: - ライフサイクル

    /// Accepts keyboard focus (the landing point for the host's key-binding
    /// forwarding and for `makeFirstResponder` on mode switches).
    public override var acceptsFirstResponder: Bool { true }

    /// Routes a key received by the container through the same keyboard
    /// settings contract used by its web view.
    public override func keyDown(with event: NSEvent) {
        // cooViewer-oxr.80: コンテナが responder の場合もキーを取りこぼさない。
        guard !settings.handlesKeyboardNavigation else {
            if let webView {
                webView.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
            return
        }
        let modifiers = event.modifierFlags
        let (key, code) = Self.webKeyIdentity(for: event)
        delegate?.readerView(self, didReceiveKey: EPUBKeyEvent(
            key: key,
            code: code,
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control),
            command: modifiers.contains(.command)))
    }

    private static func webKeyIdentity(for event: NSEvent) -> (String, String) {
        switch event.keyCode {
        case 123: return ("ArrowLeft", "ArrowLeft")
        case 124: return ("ArrowRight", "ArrowRight")
        case 125: return ("ArrowDown", "ArrowDown")
        case 126: return ("ArrowUp", "ArrowUp")
        case 116: return ("PageUp", "PageUp")
        case 121: return ("PageDown", "PageDown")
        case 115: return ("Home", "Home")
        case 119: return ("End", "End")
        case 49: return (" ", "Space")
        default:
            let value = event.charactersIgnoringModifiers ?? event.characters ?? ""
            return (value, value)
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        for label in pageNumberLabels {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.isHidden = true
            // cooViewer-oxr.37: ノンブルは独立要素にせず reader の value とする。
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibilityMetadata()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        // ファイルドロップはホスト(delegate)に委ねる(「別の本を開く」等)
        registerForDraggedTypes([.fileURL])
        // ピンチ=フォント倍率(リフローの自然な拡大。認識器なら WKWebView 上の
        // ジェスチャも確実に届く)
        addGestureRecognizer(NSMagnificationGestureRecognizer(
            target: self, action: #selector(handleMagnification(_:))))
        applyTheme()
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        // cooViewer-oxr.37: 表示配慮は配色だけを差し替え、census/再ページ割りを
        // 起動しない。テスト override の didSet も同じ経路へ入る。
        applyTheme()
        applyThemeCSSOnly()
        updateAccessibilityMetadata()
    }

    // MARK: - ピンチ(フォント倍率)

    /// Allowed range for the font scale.
    public static let fontScaleRange: ClosedRange<Double> = 0.5...3.0

    /// ピンチ開始時の倍率(確定は指を離したとき)
    private var pinchBaseFontScale: Double?

    /// ピンチ中は WKWebView.magnification で視覚追従だけ行い(再ページ割り
    /// なしで滑らか)、終了時に fontScale へ確定して進行率を保ったまま
    /// 再ページ割りする(テキストは再流し込みされるのでシャープなまま)
    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        guard settings.pinchAdjustsFontScale,
              !isFixedLayoutItem, let webView, publication != nil else { return }
        let base = pinchBaseFontScale ?? settings.fontScale
        // 確定可能な範囲に対応する視覚倍率へクランプ
        let target = min(Self.fontScaleRange.upperBound,
                         max(Self.fontScaleRange.lowerBound,
                             base * (1 + gesture.magnification)))
        let previewFactor = target / base
        switch gesture.state {
        case .began:
            pinchBaseFontScale = settings.fontScale
        case .changed:
            webView.setMagnification(previewFactor,
                                     centeredAt: gesture.location(in: webView))
        case .ended, .cancelled, .failed:
            webView.magnification = 1
            pinchBaseFontScale = nil
            guard abs(target - settings.fontScale) > 0.01 else { return }
            var updated = settings
            updated.fontScale = target
            settings = updated  // didSet → 進行率を保った再ページ割り
            delegate?.readerView(self, didChangeFontScale: target)
        default:
            break
        }
    }

    /// Steps the font scale up or down (for key bindings and menus).
    public func adjustFontScale(by delta: Double) {
        let target = min(Self.fontScaleRange.upperBound,
                         max(Self.fontScaleRange.lowerBound,
                             settings.fontScale + delta))
        guard abs(target - settings.fontScale) > 0.001 else { return }
        var updated = settings
        updated.fontScale = target
        settings = updated
        delegate?.readerView(self, didChangeFontScale: target)
    }

    // MARK: - ドラッグ&ドロップ(ホストへの委譲)

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dispatchDroppedURL(from: sender.draggingPasteboard)
    }

    func dispatchDroppedURL(from pasteboard: NSPasteboard) -> Bool {
        guard let url = NSURL(from: pasteboard) as URL? else {
            return false
        }
        return dispatchDroppedURL(url)
    }

    /// cooViewer-oxr.84: URL pasteboard 型に紛れたネットワーク URL は、
    /// ファイルを開く delegate 契約へ渡さない。
    func dispatchDroppedURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return delegate?.readerView(self, didReceiveDroppedFileURL: url) ?? false
    }

    // MARK: - テーマ(ライト/ダーク)

    /// 実効ダークか(theme=system はビューの実効外観に追従)
    private var isDarkEffective: Bool {
        switch settings.theme {
        case .light: return false
        case .dark: return true
        case .system:
            return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    private var shouldIncreaseContrast: Bool {
        accessibilityIncreaseContrastOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private var shouldDifferentiateWithoutColor: Bool {
        accessibilityDifferentiateWithoutColorOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
        applyThemeCSSOnly()
    }

    /// ネイティブ側(余白の背景・柱・ノンブルの色)へテーマを反映する
    private func applyTheme() {
        let colors = settings.effectiveColors(
            isDark: isDarkEffective, increaseContrast: shouldIncreaseContrast)
        layer?.backgroundColor = Self.parseCSSColor(colors.background)
            ?? NSColor.textBackgroundColor.cgColor
        // ノンブルは紙の本らしく控えめなグレー
        let furnitureColor = isDarkEffective
            ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        for label in pageNumberLabels {
            label.textColor = furnitureColor
        }
    }

    /// ページ側(Web コンテンツ)へ配色 CSS だけを差し替える(再ページ割りなし)
    private func applyThemeCSSOnly() {
        guard webView != nil else { return }
        let css = settings.composedUserCSS(
            isDark: isDarkEffective,
            increaseContrast: shouldIncreaseContrast,
            differentiateWithoutColor: shouldDifferentiateWithoutColor)
        callWashiAsync("return __washi.setUserCSS(css);",
                       arguments: ["css": css])
    }

    /// cooViewer-oxr.27: opt-in 時だけシステムのダブルクリック間隔を JS へ渡す。
    private func updateTapDeferral() {
        let enabled = settings.defersTapsForDoubleClick
        let interval = NSEvent.doubleClickInterval
        let milliseconds = 1_000 * (interval > 0 ? interval : 0.5)
        evaluate("__washi.setTapDeferral(\(enabled), \(milliseconds));")
    }

    /// cooViewer-oxr.35: 一般的な CSS 色表記を解釈し、ネイティブ余白と
    /// ページ CSS が同じ解決済み色を共有できるようにする。
    static func parseCSSColor(_ css: String) -> CGColor? {
        let value = css.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("#") {
            let source = String(value.dropFirst())
            let expanded: String
            switch source.count {
            case 3, 4:
                expanded = source.map { "\($0)\($0)" }.joined()
            case 6, 8:
                expanded = source
            default:
                return nil
            }
            guard let encoded = UInt64(expanded, radix: 16) else { return nil }
            let hasAlpha = expanded.count == 8
            let redShift = hasAlpha ? 24 : 16
            let greenShift = hasAlpha ? 16 : 8
            let blueShift = hasAlpha ? 8 : 0
            let alpha = hasAlpha ? Double(encoded & 0xFF) / 255 : 1
            return cssColor(red: Double((encoded >> redShift) & 0xFF) / 255,
                            green: Double((encoded >> greenShift) & 0xFF) / 255,
                            blue: Double((encoded >> blueShift) & 0xFF) / 255,
                            alpha: alpha)
        }

        if let named = cssNamedColors[value] {
            return cssColor(red: Double(named.0) / 255,
                            green: Double(named.1) / 255,
                            blue: Double(named.2) / 255,
                            alpha: named.3)
        }

        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else {
            return nil
        }
        let function = String(value[..<open])
        let content = value[value.index(after: open)..<value.index(before: value.endIndex)]
        let components = content
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        if function == "rgb" || function == "rgba" {
            guard components.count == 3 || components.count == 4,
                  let red = cssRGBComponent(components[0]),
                  let green = cssRGBComponent(components[1]),
                  let blue = cssRGBComponent(components[2]),
                  let alpha = components.count == 4
                    ? cssAlphaComponent(components[3]) : 1
            else { return nil }
            return cssColor(red: red, green: green, blue: blue, alpha: alpha)
        }

        if function == "hsl" || function == "hsla" {
            guard components.count == 3 || components.count == 4,
                  let hue = cssHue(components[0]),
                  let saturation = cssPercentage(components[1]),
                  let lightness = cssPercentage(components[2]),
                  let alpha = components.count == 4
                    ? cssAlphaComponent(components[3]) : 1
            else { return nil }
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            let sector = hue / 60
            let x = chroma * (1 - abs(sector.truncatingRemainder(
                dividingBy: 2) - 1))
            let (r1, g1, b1): (Double, Double, Double)
            switch sector {
            case 0..<1: (r1, g1, b1) = (chroma, x, 0)
            case 1..<2: (r1, g1, b1) = (x, chroma, 0)
            case 2..<3: (r1, g1, b1) = (0, chroma, x)
            case 3..<4: (r1, g1, b1) = (0, x, chroma)
            case 4..<5: (r1, g1, b1) = (x, 0, chroma)
            default: (r1, g1, b1) = (chroma, 0, x)
            }
            let match = lightness - chroma / 2
            return cssColor(red: r1 + match, green: g1 + match,
                            blue: b1 + match, alpha: alpha)
        }
        return nil
    }

    private static func cssColor(red: Double, green: Double, blue: Double,
                                 alpha: Double) -> CGColor {
        CGColor(srgbRed: CGFloat(min(1, max(0, red))),
                green: CGFloat(min(1, max(0, green))),
                blue: CGFloat(min(1, max(0, blue))),
                alpha: CGFloat(min(1, max(0, alpha))))
    }

    private static func cssRGBComponent(_ value: String) -> Double? {
        if value.hasSuffix("%") {
            return cssPercentage(value)
        }
        guard let number = Double(value), number.isFinite else { return nil }
        return min(255, max(0, number)) / 255
    }

    private static func cssAlphaComponent(_ value: String) -> Double? {
        if value.hasSuffix("%") { return cssPercentage(value) }
        guard let number = Double(value), number.isFinite else { return nil }
        return min(1, max(0, number))
    }

    private static func cssPercentage(_ value: String) -> Double? {
        guard value.hasSuffix("%"),
              let number = Double(value.dropLast()), number.isFinite else {
            return nil
        }
        return min(100, max(0, number)) / 100
    }

    private static func cssHue(_ value: String) -> Double? {
        let degrees: Double?
        if value.hasSuffix("turn") {
            degrees = Double(value.dropLast(4)).map { $0 * 360 }
        } else if value.hasSuffix("grad") {
            degrees = Double(value.dropLast(4)).map { $0 * 0.9 }
        } else if value.hasSuffix("rad") {
            degrees = Double(value.dropLast(3)).map { $0 * 180 / .pi }
        } else if value.hasSuffix("deg") {
            degrees = Double(value.dropLast(3))
        } else {
            degrees = Double(value)
        }
        guard let degrees, degrees.isFinite else { return nil }
        let normalized = degrees.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    private static let cssNamedColors: [String: (UInt8, UInt8, UInt8, Double)] = [
        "aqua": (0, 255, 255, 1), "black": (0, 0, 0, 1),
        "blue": (0, 0, 255, 1), "fuchsia": (255, 0, 255, 1),
        "gray": (128, 128, 128, 1), "grey": (128, 128, 128, 1),
        "green": (0, 128, 0, 1), "lime": (0, 255, 0, 1),
        "maroon": (128, 0, 0, 1), "navy": (0, 0, 128, 1),
        "olive": (128, 128, 0, 1), "purple": (128, 0, 128, 1),
        "red": (255, 0, 0, 1), "silver": (192, 192, 192, 1),
        "teal": (0, 128, 128, 1), "white": (255, 255, 255, 1),
        "yellow": (255, 255, 0, 1), "transparent": (0, 0, 0, 0),
        "ivory": (255, 255, 240, 1), "beige": (245, 245, 220, 1),
        "linen": (250, 240, 230, 1), "wheat": (245, 222, 179, 1),
        "cornsilk": (255, 248, 220, 1), "floralwhite": (255, 250, 240, 1),
        "oldlace": (253, 245, 230, 1), "antiquewhite": (250, 235, 215, 1),
        "papayawhip": (255, 239, 213, 1), "seashell": (255, 245, 238, 1),
        "snow": (255, 250, 250, 1), "whitesmoke": (245, 245, 245, 1),
        "ghostwhite": (248, 248, 255, 1), "mintcream": (245, 255, 250, 1),
        "honeydew": (240, 255, 240, 1), "azure": (240, 255, 255, 1),
        "aliceblue": (240, 248, 255, 1), "lavender": (230, 230, 250, 1),
    ]

    // MARK: - 本の読み込み

    /// Opens a book. Pass a locator to resume from the previous position.
    /// Host-added overlay subviews keep their z-order across web view rebuilds.
    public func load(publication: EPUBPublication, at locator: EPUBLocator? = nil) {
        cancelPendingTextRangeRequest()
        setCurrentSelection(nil)
        printPageMarkers.removeAll()
        setCurrentPrintPage(nil)
        accessibilityAnnouncementTask?.cancel()
        accessibilityAnnouncementTask = nil
        lastAnnouncedPage = nil
        // 別の本を開くのでメディアオーバーレイ再生は止める(本に紐づく)
        mediaOverlayController?.stop()
        mediaOverlayController = nil
        self.publication = publication
        updateAccessibilityMetadata()
        // cooViewer-oxr.31: 公開 load は新しい本を開く境界。内部再読込は
        // この経路を通らないため、設定変更や WebContent 復旧では履歴を保つ。
        clearNavigationHistory()
        webContentReloadTask?.cancel()
        webContentReloadTask = nil
        pendingWebContentReloadDelay = nil
        webContentReloadLimiter.reset()
        webContentReloadRequestCount = 0
        webContentReloadAttemptCount = 0
        columnAxisSupported = true
        fxlViewportCache.removeAll()
        fxlDeviceSizedViewportItems.removeAll()
        // 旧本あての再ページ割り予約を破棄(新 webView に古い設定同期由来の
        // repaginate が発火しないように)
        repaginateWork?.cancel()
        pendingRepaginate = false
        // census は本に紐づく(scheme handler ごと作り直す)
        censusTask?.cancel()
        censusTask = nil
        censusEngine?.invalidate()  // 旧本のオフスクリーンを確実に畳む
        censusEngine = nil
        censusCache.removeAll()
        censusFailures.clear()
        censusKey = nil
        thumbnailRenderer?.invalidate()  // サムネイルレンダラも本に紐づく
        thumbnailRenderer = nil
        if pageCensus != nil {
            pageCensus = nil
            delegate?.readerViewDidUpdatePageCensus(self)
        }
        // 保存位置は idref で突き合わせる(改版で spine が並べ替わった本でも
        // 別の章を無言で開かない。該当 idref が消えた本は先頭から)
        let resolved = locator.flatMap { publication.resolve($0) }
        let index = resolved.map {
            max(0, min($0.spineIndex, publication.readingOrder.count - 1))
        } ?? 0
        let target: PendingTarget = resolved.map { .progression($0.progression) } ?? .start
        pendingRestoreLocator = resolved
        rebuildWebView(for: publication)
        loadSpineItem(at: index, target: target)
    }

    private func reloadCurrentPublication() {
        guard let publication else { return }
        let locator = currentLocator
        rebuildWebView(for: publication)
        loadSpineItem(at: locator.spineIndex, target: .progression(locator.progression))
    }

    private func rebuildWebView(for publication: EPUBPublication) {
        // cooViewer-t4e: ホストが追加したオーバーレイを再構築後の webView で
        // 覆わないよう、旧 webView が占めていた z 位置を保存する。
        let oldWebViewIndex = webView.flatMap { subviews.firstIndex(of: $0) }
        webView?.removeFromSuperview()
        messageProxy?.owner = nil
        spineNavigationGate = SpineNavigationGate()

        let handler = EPUBSchemeHandler(publication: publication,
                                        allowsScripts: settings.allowsScriptedContent)
        self.schemeHandler = handler

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            settings.allowsScriptedContent
        configuration.setURLSchemeHandler(handler, forURLScheme: EPUBSchemeHandler.scheme)

        let proxy = MessageProxy(owner: self)
        self.messageProxy = proxy
        let controller = configuration.userContentController
        controller.add(proxy, contentWorld: Self.washiWorld, name: "washi")
        EPUBScriptedContentHardening.install(
            in: controller,
            allowsScriptedContent: settings.allowsScriptedContent)
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.pageScript, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: Self.washiWorld))
        controller.addUserScript(WKUserScript(
            source: ReaderScripts.baseCSSInjector, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: Self.washiWorld))

        let webView = WashiWebView(frame: contentFrame,
                                   configuration: configuration)
        webView.contextMenuHandler = { [weak self] menu, event in
            self?.contextMenu(menu, for: event)
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = []
        webView.alphaValue = 0  // 初回セットアップ完了までチラつきを隠す
        // WKWebView 自身のドロップ処理を外し、コンテナ(自ビュー)の
        // ファイルドロップ委譲を生かす(本は読み取り専用なので失うものはない)
        webView.unregisterDraggedTypes()
        if let oldWebViewIndex, subviews.indices.contains(oldWebViewIndex) {
            addSubview(webView, positioned: .below,
                       relativeTo: subviews[oldWebViewIndex])
        } else {
            addSubview(webView)
        }
        // ノンブルは Web ビューより前面に
        for label in pageNumberLabels {
            addSubview(label, positioned: .above, relativeTo: webView)
        }
        self.webView = webView

        Task { [weak webView] in
            if let ruleList = await Self.contentRuleList.value {
                webView?.configuration.userContentController.add(ruleList)
            }
        }
    }

    /// リフロー時の webView 配置(設定の余白でインセット)。
    /// FXL は全面(余白なし)に配置してページ自体を版面として見せる
    /// 現在の表示モード(単ページ/見開き)に応じた実効余白。見開きは
    /// spreadInsets があればそちら、無ければ insets(EPUBScreenMetrics と同じ規則)
    private var activeInsets: EPUBReaderInsets {
        return isSpread ? (settings.spreadInsets ?? settings.insets)
                        : settings.insets
    }

    /// 見開き判定は現在 itemref の実効 rendition:spread を含む画面計画へ一本化する
    private var isSpread: Bool {
        EPUBScreenMetrics.plansSpread(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: effectiveSpread(forSpineIndex: currentSpineIndex))
    }

    /// The content page area inside the active native margins, expressed in
    /// reader-view coordinates.
    public var contentFrame: CGRect {
        if isFixedLayoutItem {
            return NSRect(origin: .zero, size: bounds.size)
        }
        let insets = activeInsets
        return NSRect(
            x: insets.left,
            y: insets.bottom,
            width: max(1, bounds.width - insets.left - insets.right),
            height: max(1, bounds.height - insets.top - insets.bottom))
    }

    /// cooViewer-oxr.35: native のノンブルは見た目だけの furniture なので、
    /// NSTextField に hit を奪わせず余白と同じ reader-view 入力経路へ通す。
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        if pageNumberLabels.contains(where: {
            target === $0 || target.isDescendant(of: $0)
        }) {
            return self
        }
        return target
    }

    /// ノンブルを各ページの下部中央に置く(Apple Books の版面に倣う。
    /// 見開き時は左右のページそれぞれの下、単ページ時は中央)。
    /// AppKit 座標系: 下原点
    private func layoutFurniture() {
        let insets = activeInsets
        let contentWidth = max(1, bounds.width - insets.left - insets.right)
        // ページスロットの中心 x(見開きはノドを挟んだ半幅 2 面)
        let centers: [CGFloat]
        if pagesPerScreen == 2 {
            let gutter = spreadGutter(forContentWidth: contentWidth)
            let pageWidth = (contentWidth - gutter) / 2
            centers = [insets.left + pageWidth / 2,
                       insets.left + contentWidth - pageWidth / 2]
        } else {
            centers = [insets.left + contentWidth / 2]
        }
        for (index, label) in pageNumberLabels.enumerated() {
            guard index < centers.count, !label.isHidden else { continue }
            label.sizeToFit()
            let size = label.frame.size
            label.frame = NSRect(
                x: centers[index] - size.width / 2,
                y: (insets.bottom - size.height) / 2,
                width: size.width, height: size.height)
        }
    }

    /// 各ページのノンブル(素の章内ページ番号。Apple Books 風)を更新する。
    /// FXL・画像ページ(表紙)では隠す。右綴じは右スロットが先のページ
    private func updateFurniture() {
        let visible = settings.showsPageFurniture && publication != nil
            && !isFixedLayoutItem && !isImagePage && !furnitureSuppressed
        guard visible else {
            for label in pageNumberLabels { label.isHidden = true }
            updateAccessibilityMetadata()
            return
        }
        // スロット順 = [左, 右]。表示ページ順は実際の CSS カラム方向で決まる。
        let slotNumbers = pageFurnitureSlotNumbers
        for (index, label) in pageNumberLabels.enumerated() {
            if let number = slotNumbers[index] {
                if settings.showsPrintPageInFurniture,
                   let currentPrintPage {
                    label.stringValue = "\(number) [p. \(currentPrintPage)]"
                } else {
                    label.stringValue = String(number)
                }
                label.isHidden = false
            } else {
                label.isHidden = true
            }
        }
        layoutFurniture()
        updateAccessibilityMetadata()
    }

    /// 可視カラムと共有するノンブル配置。internal は実 WK 回帰試験用。
    var pageFurnitureSlotNumbers: [Int?] {
        let first = pageInItem + 1
        let second = pageInItem + 2 <= pageCountInItem ? pageInItem + 2 : nil
        if pagesPerScreen == 2 {
            return firstPageOnRight ? [second, first] : [first, second]
        }
        return [first, nil]
    }

    // 見開き判定・ノド幅は EPUBScreenMetrics が単一の正(リーダー外の
    // 一覧展開と式を共有し、ページ割りの一致を保証する)

    private func spreadGutter(forContentWidth width: CGFloat) -> CGFloat {
        EPUBScreenMetrics.spreadGutter(forContentWidth: width)
    }

    /// 現在の表示条件の画面計画(census・サムネイルのオプションもここから)
    private var currentScreenMetrics: EPUBScreenMetrics {
        EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: effectiveSpread(forSpineIndex: currentSpineIndex))
    }

    /// cooViewer-oxr.24: ライブ再ページ割りの判定にも census と同じ導出値を使う。
    private func layoutKey(for settings: EPUBReaderSettings) -> String {
        EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: effectiveSpread(forSpineIndex: currentSpineIndex))
            .cacheKey
    }

    /// census のキーは表示中の項目で揺らさず、文書既定を基底にする。
    /// 実測時は EPUBPaginationCensus が各 itemref の override を適用する。
    private var censusScreenMetrics: EPUBScreenMetrics {
        EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: publication?.metadata.rendition.spread ?? .auto)
    }

    private func effectiveSpread(forSpineIndex index: Int) -> RenditionSpread {
        guard let publication,
              publication.readingOrder.indices.contains(index) else {
            return publication?.metadata.rendition.spread ?? .auto
        }
        // cooViewer-oxr.51: 見開き可否は現在項目の itemref override を使う。
        return publication.package.effectiveSpread(
            for: publication.readingOrder[index].itemRef)
    }

    private func loadSpineItem(at index: Int, target: PendingTarget,
                               preservingTurnCover: Bool = false) {
        let isTextRangeTarget: Bool
        if case .textRange = target {
            isTextRangeTarget = true
        } else {
            isTextRangeTarget = false
            cancelPendingTextRangeRequest()
        }
        guard let publication, let schemeHandler, let webView,
              publication.readingOrder.indices.contains(index) else {
            if isTextRangeTarget { cancelPendingTextRangeRequest() }
            return
        }
        // cooViewer-oxr.47: 旧 spine の WebContent 終了に対するバックオフを、
        // ユーザーが移動した新 spine へ遅配しない。
        webContentReloadTask?.cancel()
        webContentReloadTask = nil
        pendingWebContentReloadDelay = nil
        setCurrentSelection(nil)
        printPageMarkers.removeAll(keepingCapacity: true)
        accessibilityAnnouncementTask?.cancel()
        accessibilityAnnouncementTask = nil
        currentSpineIndex = index
        pendingTarget = target
        // cooViewer-oxr.23: pageChanged 前の保存にも、読み込み先の意図した
        // progression を返せるよう locator として保持する。
        pendingRestoreLocator = publication.locator(
            forSpineIndex: index, progression: progression(for: target))
        pageInItem = 0
        pageCountInItem = 1
        isImagePage = false
        // setup 応答までは OPF を暫定値にし、旧 item の CSS 方向を持ち越さない。
        firstPageOnRight = isRTL
        isLoadingSpineItem = true
        spineLoadGeneration += 1
        repaginateWork?.cancel()  // 旧文書あての再ページ割りを新文書へ流さない
        // 進行中のめくり演出は新しい章の表示を隠すので畳む。
        // spine 遷移演出の持ち越しカバー(旧ページ)だけは読み込み中も残す。
        // foldTurnCover 経由で各カバーの時間切れ回収タスクも確実に止める
        if !preservingTurnCover { clearPendingSpineTurn() }
        let survivor = pendingSpineTurn?.cover
        for overlay in turnOverlays where overlay !== survivor {
            foldTurnCover(overlay)
        }
        let entry = publication.readingOrder[index]
        isFixedLayoutItem =
            publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated
        // cooViewer-oxr.51: spine 遷移直後から現在 itemref の spread 用余白を
        // WebView の実寸へ反映し、didFinish/setup が旧項目の innerWidth で
        // ページ割りしないようにする。
        webView.frame = contentFrame
        updateFurniture()
        guard let url = schemeHandler.url(forReadingOrderItem: entry) else {
            if isTextRangeTarget { cancelPendingTextRangeRequest() }
            return
        }
        webView.alphaValue = 0
        spineNavigationGate.expect(entry.resolvedContainerPath)
        let navigation = webView.load(URLRequest(url: url))
        if navigation == nil {
            spineNavigationGate.cancelExpectation(for: entry.resolvedContainerPath)
        }
        currentNavigation = navigation
    }

    // MARK: - ナビゲーション API

    /// Whether the book's effective reading direction is right-to-left.
    public var isRTL: Bool {
        publication?.effectiveReadingDirection == .rtl
    }

    public var currentLocator: EPUBLocator {
        // cooViewer-oxr.23: 読み込み中は旧文書由来のページカウンタでなく、
        // load/go が最後に予約した target を現在位置として答える。
        if isLoadingSpineItem {
            let progression = progression(for: pendingTarget)
            return publication?.locator(
                forSpineIndex: currentSpineIndex, progression: progression)
                ?? EPUBLocator(spineIndex: currentSpineIndex,
                               progression: progression)
        }
        // 復元がまだ適用されていない間は復元先を答える(開いてすぐ閉じたときに
        // 保存済み位置を (0,0) で潰さない)
        if let pendingRestoreLocator { return pendingRestoreLocator }
        let progression = pageCountInItem <= 1
            ? 0 : Double(pageInItem) / Double(pageCountInItem - 1)
        // idref 併記(publication.resolve で改版追跡できる形)で返す
        return publication?.locator(forSpineIndex: currentSpineIndex,
                                    progression: progression)
            ?? EPUBLocator(spineIndex: currentSpineIndex,
                           progression: progression)
    }

    /// Advances in reading order (next page within the item → next spine item).
    /// The within-item decision for reflowable content is left to JS (turnInDoc):
    /// the native page counter is updated asynchronously, so relying on it would
    /// race under rapid key-repeat and skip whole chapters.
    public func goForward() { turnInDocAnimated(forward: true) }

    /// Goes back in reading order.
    public func goBackward() { turnInDocAnimated(forward: false) }

    /// 項目内めくり + 演出。
    /// 順序が命: **旧ページのカバーを先に被せてから**めくり、新ページの
    /// スナップショットを取ってから演出に入る(めくり直後の新ページが
    /// 一瞬見えてから演出が始まる「チラつき」を構造的に排除する)。
    /// ホスト(delegate)がページカール等の独自演出で置き換えられる。
    /// 「視差効果を減らす」時・高速連打時・端到達時は演出なし
    private func turnInDocAnimated(forward: Bool) {
        guard let webView else { return }
        let wantsAnimation = settings.pageTurnStyle != .none
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && Date().timeIntervalSince(lastTurnDate) > 0.3
            // spine 読込中は演出を張らない: 章境界の重い読込中に再度めくると、
            // 読込中 webView のスナップショットでゴミカバーを作り pendingSpineTurn を
            // 上書きして画面を固着させる。演出なしの fast-path に降格することで
            // FXL のキーリピートめくりは従来どおり動く
            && !isLoadingSpineItem
        lastTurnDate = Date()
        if isFixedLayoutItem {
            // FXL 項目は常に隣接 spine への移動。演出ありなら旧ページの
            // カバーを持ち越して spine 遷移演出(下の boundary 経路と同じ)
            if wantsAnimation {
                Task { [weak self] in
                    await self?.beginFXLSpineTurn(forward: forward,
                                                  webView: webView)
                }
            } else {
                advanceSpine(forward: forward)
            }
            return
        }
        guard wantsAnimation else {
            evaluate("__washi.turnInDoc(\(forward));")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.performAnimatedTurn(forward: forward, webView: webView)
        }
    }

    /// FXL 項目からの隣接 spine 移動をカバー持ち越しで演出する
    private func beginFXLSpineTurn(forward: Bool, webView: WKWebView) async {
        let fast = WKSnapshotConfiguration()
        fast.afterScreenUpdates = false
        guard let oldWeb = try? await webView.takeSnapshot(configuration: fast)
        else {
            advanceSpine(forward: forward)
            return
        }
        // FXL でもレターボックス(余白)込みの全面でめくる(リフローと同じ扱い)
        let oldPage = composeFullPage(webImage: oldWeb, in: webView.frame)
        let cover = NSImageView(image: oldPage)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = bounds
        addSubview(cover, positioned: .above, relativeTo: webView)
        turnOverlays.append(cover)
        updateFurnitureSuppression()
        // 既存の持ち越しカバー(前のめくりの旧ページ)を先に畳んでから上書きする。
        // 畳まないと旧カバーが所有権(pendingSpineTurn)を失って回収経路を全て
        // 失い、画面が旧ページで固着する
        clearPendingSpineTurn()
        pendingSpineTurn = PendingSpineTurn(
            oldPage: oldPage, cover: cover, forward: forward)
        scheduleSpineTurnTimeout(for: cover)
        advanceSpine(forward: forward)
    }

    /// spine 遷移(章間・表紙→本文)もめくり演出で見せるための持ち越し状態。
    /// 境界めくり(turnInDoc が boundary)から次項目の表示完了までカバーで
    /// 旧ページを見せ続け、完了時に項目内めくりと同じ演出で切り替える
    struct PendingSpineTurn {
        let oldPage: NSImage
        let cover: NSImageView
        let forward: Bool
    }
    var pendingSpineTurn: PendingSpineTurn?

    /// カバー同一性 → 時間切れ回収タスク。所有権を失った(上書きされた)カバーも
    /// membership で回収するため、pendingSpineTurn ではなくカバーごとに持つ。
    /// 演出中(runTurnEffect)や仕上げ時は明示 cancel してスライド途中で
    /// カバーを引き剥がさない
    var spineTurnTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// めくりカバー掲示中はライブのノンブルを隠す。番号はカバー(全面合成)に
    /// 焼き込み済みで、カバーはラベルより背面に入るため、隠さないと演出中に
    /// ライブ側の新番号と焼き込みの旧番号が二重に見える。章読み込み中に
    /// ラベルが一瞬「1」へ戻って見えていた従来のチラつきも同時に消える
    var furnitureSuppressed = false {
        didSet { if furnitureSuppressed != oldValue { updateFurniture() } }
    }

    /// turnOverlays を増減させた後に必ず呼ぶ(カバーの有無と抑制を同期)
    private func updateFurnitureSuppression() {
        furnitureSuppressed = !turnOverlays.isEmpty
    }

    /// カバー 1 枚を確実に回収する単一経路(旧: removeCover/timeout/clear に散っていた
    /// 除去を統合)。所有権(このカバーが現 pendingSpineTurn か)を判定して
    /// pending を壊さない。所有権を失って上書きされた孤児カバーもこれで畳める
    func foldTurnCover(_ cover: NSView) {
        let id = ObjectIdentifier(cover)
        spineTurnTimeouts[id]?.cancel()  // 時間切れ回収タスクを止める
        spineTurnTimeouts[id] = nil
        cover.removeFromSuperview()
        turnOverlays.removeAll { $0 === cover }
        if pendingSpineTurn?.cover === cover { pendingSpineTurn = nil }
        updateFurnitureSuppression()
    }

    private func clearPendingSpineTurn() {
        guard let pending = pendingSpineTurn else { return }
        foldTurnCover(pending.cover)  // pending の nil 化・overlay 除去・timeout 停止を一括
    }

    /// テスト用: カバーを本番と同じ手順で turnOverlays に載せる(任意で pending 化)。
    /// 実 WKWebView 無しでカバーのライフサイクル(孤児回収・所有権)を検証するため
    func installTurnCover(_ cover: NSImageView, pending: Bool, forward: Bool = true) {
        addSubview(cover)
        turnOverlays.append(cover)
        updateFurnitureSuppression()
        if pending {
            pendingSpineTurn = PendingSpineTurn(
                oldPage: cover.image ?? NSImage(), cover: cover, forward: forward)
        }
    }

    /// 読み込みが来ないままカバーが残る事態(端で何も起きない・失敗、または
    /// 別のめくりに pendingSpineTurn を上書きされて所有権を失ったカバー)の安全弁。
    /// pendingSpineTurn 一致ではなく turnOverlays の membership で回収する
    func scheduleSpineTurnTimeout(for cover: NSImageView,
                                  after duration: Duration = .seconds(2)) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled,
                  self.turnOverlays.contains(cover) else { return }
            self.foldTurnCover(cover)  // 所有権を問わず、まだ残っていれば畳む
        }
        spineTurnTimeouts[ObjectIdentifier(cover)] = task
    }

    private func performAnimatedTurn(forward: Bool, webView: WKWebView) async {
        // 1. 旧ページを撮り、カバーとして被せる(以後ユーザーには旧ページが
        //    見え続け、下でめくりが起きても分からない)
        let fast = WKSnapshotConfiguration()
        fast.afterScreenUpdates = false
        guard let oldWeb = try? await webView.takeSnapshot(configuration: fast)
        else {
            evaluate("__washi.turnInDoc(\(forward));")
            return
        }
        // 余白・ノンブル込みの全面(紙のページ全体)でめくる。本文領域だけを
        // 動かすと余白が静止して実際の本と違って見えるため、以降のカバーと
        // 演出はすべてビュー全面を対象にする
        let oldPage = composeFullPage(webImage: oldWeb, in: webView.frame)
        let cover = NSImageView(image: oldPage)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = bounds
        addSubview(cover, positioned: .above, relativeTo: webView)
        turnOverlays.append(cover)
        updateFurnitureSuppression()

        // 2. カバーの下でめくる。境界なら次項目の表示完了までカバーを持ち越す
        //    (boundary 通知 → advanceSpine → runSetup 完了時に演出)。
        //    JS 呼び出しの**前に**登録する: boundary メッセージが戻り値より
        //    先に届いても loadSpineItem がカバーを保持できるように。
        //    代入前に旧 pending を畳む: 畳まないと前のめくりのカバーが所有権を
        //    失って回収経路を全て失い、画面が旧ページで固着する
        clearPendingSpineTurn()
        pendingSpineTurn = PendingSpineTurn(
            oldPage: oldPage, cover: cover, forward: forward)
        let result = try? await webView.callAsyncJavaScript(
            "return __washi.turnInDoc(\(forward));",
            arguments: [:], in: nil, contentWorld: Self.washiWorld)
        switch result as? String {
        case "turned":
            // await 中に別のめくり(B)が入って自分の pending を上書きしていたら、
            // B の境界持ち越しを壊さないよう自分が現 pending のときだけ nil にする
            if pendingSpineTurn?.cover === cover { pendingSpineTurn = nil }
        case "boundary":
            // カバーの後始末は advanceSpine / didReachBookEdge /
            // runSetup(表示完了)側、または所有権喪失時は timeout(foldTurnCover)が引き取る
            scheduleSpineTurnTimeout(for: cover)
            return
        default:
            // 'ignored'(setup 前)・nil(評価失敗): 何も起きないので畳む
            foldTurnCover(cover)
            return
        }

        // 3. 新ページを描画完了込みで撮り、演出でカバーを取り除く
        let after = WKSnapshotConfiguration()
        after.afterScreenUpdates = true
        // showPage は turnInDoc の返答前に pageChanged を post するため、
        // ここに来た時点でノンブルは新ページの値に更新済み(合成に正しく載る)
        let newPage = (try? await webView.takeSnapshot(configuration: after))
            .map { composeFullPage(webImage: $0, in: webView.frame) }
        runTurnEffect(oldPage: oldPage, newPage: newPage,
                      cover: cover, forward: forward)
    }

    /// めくり演出の本体(項目内・spine 遷移で共通)。
    /// ホスト独自演出(ページカール等)があれば委譲し、なければ内蔵の
    /// スライド/フェードでカバー(旧ページ)を取り除く
    private func runTurnEffect(oldPage: NSImage, newPage: NSImage?,
                               cover: NSImageView, forward: Bool) {
        // 演出に入る前に、このカバーの時間切れ回収タスクを止める(membership 判定の
        // タイムアウトがスライド/フェード中に発火してカバーを途中で引き剥がさない)
        let coverID = ObjectIdentifier(cover)
        spineTurnTimeouts[coverID]?.cancel()
        spineTurnTimeouts[coverID] = nil
        func removeCover() { foldTurnCover(cover) }
        let removeCoverAfterAnimation: @Sendable () -> Void = {
            [weak self, weak cover] in
            Task { @MainActor [weak self, weak cover] in
                guard let self, let cover else { return }
                self.foldTurnCover(cover)
            }
        }
        // カバー・スナップショットとも全面合成なので演出矩形もビュー全面
        let frame = bounds
        if let newPage,
           delegate?.readerView(self, animatePageTurnFrom: oldPage, to: newPage,
                                forward: forward, in: frame) == true {
            removeCover()  // ホストのオーバーレイが被さっている
            return
        }
        switch settings.pageTurnStyle {
        case .slide:
            // 物理方向: 進む=旧ページが綴じの反対側へ抜ける
            // (右綴じで進む=右へ、左綴じで進む=左へ)
            let direction: CGFloat = (forward ? 1 : -1) * (isRTL ? 1 : -1)
            let target = cover.frame.offsetBy(dx: direction * frame.width, dy: 0)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                cover.animator().frame = target
            }, completionHandler: removeCoverAfterAnimation)
        case .fade:
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                cover.animator().alphaValue = 0
            }, completionHandler: removeCoverAfterAnimation)
        case .none:
            removeCover()
        }
    }

    /// Page turn by physical direction (in a right-to-left book, "left" = forward).
    public func turnPageLeft() { isRTL ? goForward() : goBackward() }
    public func turnPageRight() { isRTL ? goBackward() : goForward() }

    public func go(to locator: EPUBLocator) {
        navigate(to: locator, recordsHistory: true)
    }

    /// Navigates to the most recently recorded jump origin. Does nothing when
    /// no navigation history is available.
    public func goBack() {
        guard let locator = navigationHistory.popLast() else { return }
        // cooViewer-oxr.31: 戻る移動そのものは新しい履歴として積まない。
        navigate(to: locator, recordsHistory: false)
        updateCanGoBack()
    }

    private func navigate(to locator: EPUBLocator, recordsHistory: Bool) {
        cancelPendingTextRangeRequest()
        guard let publication,
              // cooViewer-oxr.72: idref があれば index より優先して改版追跡する。
              let resolved = publication.resolve(locator) else { return }
        let target = PendingTarget.progression(resolved.progression)
        if recordsHistory { recordCurrentLocatorInHistory() }
        if resolved.spineIndex == currentSpineIndex {
            applyOrQueueTarget(target)
        } else {
            loadSpineItem(at: resolved.spineIndex, target: target)
        }
    }

    /// Navigates to an exact UTF-16 text range in a reflowable spine item.
    ///
    /// The returned rectangles are expressed in this reader view's coordinate
    /// system. Returns `nil` when the locator or range cannot be resolved, so
    /// callers can fall back to progression-based navigation.
    ///
    /// - Parameters:
    ///   - locator: The spine item containing the extracted-text range.
    ///   - textRange: The offset and length in UTF-16 code units of that item's
    ///     extracted plain text.
    /// - Returns: The exact DOM landing, or `nil` if exact positioning fails.
    public func go(
        to locator: EPUBLocator,
        textRange: (utf16Offset: Int, utf16Length: Int)
    ) async -> EPUBTextRangeLanding? {
        guard let publication,
              let locator = publication.resolve(locator),
              textRange.utf16Offset >= 0, textRange.utf16Length > 0,
              textRange.utf16Offset <= Int.max - textRange.utf16Length,
              publication.package.effectiveLayout(
                for: publication.readingOrder[locator.spineIndex].itemRef)
                != .prePaginated
        else { return nil }

        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancelPendingTextRangeRequest()
                pendingTextRangeRequest = PendingTextRangeRequest(
                    id: requestID, continuation: continuation)
                let target = PendingTarget.textRange(
                    utf16Offset: textRange.utf16Offset,
                    utf16Length: textRange.utf16Length,
                    fallbackProgression: locator.progression)
                recordCurrentLocatorInHistory()
                if locator.spineIndex == currentSpineIndex {
                    applyOrQueueTarget(target)
                } else {
                    loadSpineItem(at: locator.spineIndex, target: target)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingTextRangeRequest(id: requestID)
            }
        }
    }

    /// Navigates to a table-of-contents item.
    public func go(to navItem: EPUBNavItem) {
        guard let publication,
              let index = publication.spineIndex(forNavItem: navItem) else { return }
        let fragment = navItem.href.flatMap(Self.fragment(of:))
        let target: PendingTarget = fragment.map { .fragment($0) } ?? .start
        recordCurrentLocatorInHistory()
        if index == currentSpineIndex {
            applyOrQueueTarget(target)
        } else {
            loadSpineItem(at: index, target: target)
        }
    }

    /// Follows a resolved internal link using the reader's default navigation.
    ///
    /// This method bypasses the delegate's internal-link policy callback and
    /// records the current locator in navigation history before moving. Use it
    /// after intercepting a link when the host later decides to navigate.
    public func follow(_ link: EPUBInternalLink) {
        goToContainerPath(link.containerPath, fragment: link.fragment)
    }

    /// Navigates to a print page label declared by the publication's page
    /// list. Returns false when no resolvable matching label exists.
    @discardableResult
    public func go(toPrintPage label: String) -> Bool {
        guard let publication,
              let item = flattenedPrintPageList.first(where: {
                  $0.title == label && publication.spineIndex(forNavItem: $0) != nil
              }) else { return false }
        // cooViewer-oxr.38: TOC と同じ go(navItem:) を通し、oxr.31 の
        // 履歴記録・fragment 解決・spine 切替を二重実装しない。
        go(to: item)
        return true
    }

    private var flattenedPrintPageList: [EPUBNavItem] {
        func flatten(_ items: [EPUBNavItem]) -> [EPUBNavItem] {
            items.flatMap { [$0] + flatten($0.children) }
        }
        return flatten(publication?.navigation.pageList ?? [])
    }

    public func goToBookStart() { loadSpineItem(at: 0, target: .start) }

    public func goToBookEnd() {
        guard let publication else { return }
        loadSpineItem(at: publication.readingOrder.count - 1, target: .end)
    }

    private func advanceSpine(forward: Bool) {
        guard let publication else { return }
        let next = currentSpineIndex + (forward ? 1 : -1)
        guard publication.readingOrder.indices.contains(next) else {
            // 巻頭/巻末超え: ホストの反応(ループ・隣の本・何もしない)は
            // めくり演出ではないので、持ち越しカバーを先に畳む
            clearPendingSpineTurn()
            delegate?.readerView(self, didReachBookEdge: forward)
            return
        }
        loadSpineItem(at: next, target: forward ? .start : .end,
                      preservingTurnCover: true)
    }

    private func applyTarget(_ target: PendingTarget) {
        switch target {
        case .start:
            cancelPendingTextRangeRequest()
            evaluate("__washi.showPage(0);")
        case .end:
            cancelPendingTextRangeRequest()
            evaluate("__washi.showLastPage();")
        case .progression(let progression):
            cancelPendingTextRangeRequest()
            // cooViewer-oxr.73: 呼び出し境界でも有限な 0...1 に丸め、
            // 旧保存形式や外部からの異常値を JavaScript へ渡さない。
            let safeProgression = Self.clampedProgression(progression)
            evaluate("__washi.showProgression(\(safeProgression));")
        case .fragment(let fragment):
            cancelPendingTextRangeRequest()
            // 断片 id は EPUB 由来(信頼できない)。文字列連結でなく引数渡しで
            // WebKit に完全エスケープさせる(手動 \\・' では改行・行区切りを取りこぼす)
            callWashiAsync("return __washi.showFragment(id);",
                           arguments: ["id": fragment])
        case .textRange(let utf16Offset, let utf16Length, let fallbackProgression):
            // 要求が既に消えている(先行キャンセル・失敗)のに spine 読込後のターゲット
            // として消費された場合、何も適用しないと新章がページ 0 のまま
            // pageChanged も出ない(cooViewer-7cn)。locator の進行率へ落として
            // 通常のページ表示と didMoveTo を保証する
            guard let requestID = pendingTextRangeRequest?.id else {
                let safeProgression = Self.clampedProgression(fallbackProgression)
                evaluate("__washi.showProgression(\(safeProgression));")
                return
            }
            textRangeTask?.cancel()
            textRangeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let landing = await self.locateTextRange(
                    utf16Offset: utf16Offset, utf16Length: utf16Length)
                guard !Task.isCancelled else { return }
                self.finishTextRangeRequest(id: requestID, landing: landing)
            }
        }
    }

    /// cooViewer-oxr.19: spine 読み込み中の同一項目ナビゲーションは旧 DOM へ
    /// 適用せず、進行中の setup が最後の target を一度だけ消費する。
    private func applyOrQueueTarget(_ target: PendingTarget) {
        guard isLoadingSpineItem else {
            applyTarget(target)
            return
        }
        if case .textRange = target {
            // 継続は setup 後の exact landing が完了させる。
        } else {
            cancelPendingTextRangeRequest()
        }
        pendingTarget = target
        pendingRestoreLocator = publication?.locator(
            forSpineIndex: currentSpineIndex,
            progression: progression(for: target))
    }

    private func progression(for target: PendingTarget) -> Double {
        switch target {
        case .end:
            return 1
        case .progression(let progression):
            return Self.clampedProgression(progression)
        case .textRange(_, _, let fallbackProgression):
            return Self.clampedProgression(fallbackProgression)
        case .start, .fragment:
            return 0
        }
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, in: nil, in: Self.washiWorld)
    }

    /// washi ワールドで JS を評価する(メディアオーバーレイ拡張から使う)
    func evaluateWashi(_ script: String) { evaluate(script) }

    /// washi ワールドで JS を引数付きで呼ぶ(値は WebKit が完全にエスケープ
    /// するので、EPUB 由来の断片 id・クラス名を文字列連結で埋め込まない)。
    /// 表示中の webView への呼び出しなので QoS 逆転(オフスクリーン初回)には
    /// 該当しない
    func callWashiAsync(_ body: String, arguments: [String: Any]) {
        guard let webView else { return }
        Task { @MainActor in
            _ = await callWashiAsync(body, arguments: arguments, in: webView)
        }
    }

    private func callWashiAsync(
        _ body: String, arguments: [String: Any], in webView: WKWebView
    ) async -> Any? {
        try? await webView.callAsyncJavaScript(
            body, arguments: arguments, in: nil, contentWorld: Self.washiWorld)
    }

    private func locateTextRange(
        utf16Offset: Int, utf16Length: Int
    ) async -> EPUBTextRangeLanding? {
        guard let webView else { return nil }
        let result = await callWashiAsync(
            "return __washi.locateAndShow(o, l);",
            arguments: ["o": utf16Offset, "l": utf16Length], in: webView)
        guard webView === self.webView,
              let dictionary = result as? [String: Any],
              dictionary["found"] as? Bool == true,
              let page = dictionary["page"] as? Int,
              let text = dictionary["text"] as? String,
              let rawRects = dictionary["rects"] as? [[String: Any]]
        else { return nil }

        let rects = rawRects.compactMap {
            readerViewRect(from: $0, in: webView)
        }
        // 空矩形は「特定できなかった」扱い(JS 側も null を返すが多重防御。cooViewer-cvt)
        guard rects.count == rawRects.count, !rects.isEmpty else { return nil }
        return EPUBTextRangeLanding(pageInItem: page, text: text, rects: rects)
    }

    /// Clears the current DOM selection and immediately publishes a nil
    /// selection state.
    public func clearSelection() {
        setCurrentSelection(nil)
        callWashiAsync("return __washi.clearSelection();", arguments: [:])
    }

    /// Returns the visible fragments for a normalized UTF-16 text range in
    /// the currently loaded spine item. Other spine items return an empty
    /// array and are not loaded as a side effect.
    public func rects(
        forTextRange range: Range<Int>, inSpineIndex index: Int
    ) async -> [CGRect] {
        guard index == currentSpineIndex, !isLoadingSpineItem,
              !isFixedLayoutItem, range.lowerBound >= 0, !range.isEmpty,
              let webView else { return [] }
        let result = await callWashiAsync(
            "return __washi.rectsForTextRange(o, l);",
            arguments: ["o": range.lowerBound, "l": range.count], in: webView)
        guard webView === self.webView,
              let rawRects = result as? [[String: Any]] else { return [] }
        return rawRects.compactMap { readerViewRect(from: $0, in: webView) }
    }

    /// cooViewer-oxr.34: 同値通知を畳み、clearSelection の即時 nil と JS の
    /// selectionchange 遅配が delegate へ二重に届かないようにする。
    private func setCurrentSelection(_ selection: EPUBTextSelection?) {
        guard selection != currentSelection else { return }
        currentSelection = selection
        delegate?.readerView(self, selectionDidChange: selection)
    }

    /// cooViewer-oxr.32: DOMRect(左上原点)を現在 WKWebView の実座標系へ直し、
    /// AppKit に inset と reader-view 座標への変換を任せる。
    private func readerViewRect(
        from raw: [String: Any], in webView: WKWebView
    ) -> CGRect? {
        guard let x = Self.number(raw["x"]),
              let y = Self.number(raw["y"]),
              let width = Self.number(raw["w"]),
              let height = Self.number(raw["h"]),
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0
        else { return nil }
        let localY = webView.isFlipped
            ? CGFloat(y)
            : webView.bounds.height - CGFloat(y) - CGFloat(height)
        let local = CGRect(x: CGFloat(x), y: localY,
                           width: CGFloat(width), height: CGFloat(height))
        return webView.convert(local, to: self)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }

    private func finishTextRangeRequest(
        id: UUID, landing: EPUBTextRangeLanding?
    ) {
        guard pendingTextRangeRequest?.id == id else { return }
        let continuation = pendingTextRangeRequest?.continuation
        pendingTextRangeRequest = nil
        textRangeTask = nil
        continuation?.resume(returning: landing)
    }

    private func cancelPendingTextRangeRequest(id: UUID? = nil) {
        if let id, pendingTextRangeRequest?.id != id { return }
        textRangeTask?.cancel()
        textRangeTask = nil
        let continuation = pendingTextRangeRequest?.continuation
        pendingTextRangeRequest = nil
        continuation?.resume(returning: nil)
    }

    // MARK: - レイアウト

    public override func layout() {
        super.layout()
        layoutFurniture()
        guard let webView else { return }
        guard allowsVisibleRenderingWork else {
            // cooViewer-oxr.54: 非表示中は WebKit の再ページ割りと census を
            // 起動せず、最後の寸法を表示復帰時に一度だけ反映する。
            pendingVisibleLayout = true
            return
        }
        layoutVisibleContent(webView, forcePagination: false)
    }

    private var allowsVisibleRenderingWork: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    private func layoutVisibleContent(_ webView: WKWebView,
                                      forcePagination: Bool) {
        if isFixedLayoutItem {
            layoutFixedItem()
            // FXL 項目の表示中でもリサイズで census のメトリクスは変わる
            // (再ページ割りは不要だが、N/M とジャンプ写像は寸法依存)。
            // scheduleCensusIfNeeded はキーで重複排除するので毎回呼んで安全
            scheduleCensusIfNeeded()
        } else {
            webView.frame = contentFrame
            if forcePagination || lastLaidOutSize != bounds.size {
                schedulePagination(preserveProgression: true)
            }
        }
        lastLaidOutSize = bounds.size
    }

    /// FXL: ICB へのアスペクトフィット。中央寄せは webView フレームで行う。
    /// viewport はキャッシュする(リサイズ毎の XHTML 再パースを避ける)
    private func layoutFixedItem() {
        guard let webView, let publication else { return }
        let available = contentFrame
        let viewport: CGSize
        if fxlDeviceSizedViewportItems.contains(currentSpineIndex) {
            viewport = available.size
        } else if let cached = fxlViewportCache[currentSpineIndex] {
            viewport = cached
        } else {
            let info = try? publication.fixedLayoutInfo(
                forSpineIndex: currentSpineIndex)
            if info?.viewportIsDeviceSized == true {
                fxlDeviceSizedViewportItems.insert(currentSpineIndex)
                viewport = available.size
            } else {
                viewport = info?.viewportSize ?? CGSize(width: 1200, height: 1600)
                fxlViewportCache[currentSpineIndex] = viewport
            }
        }
        guard viewport.width > 0, viewport.height > 0,
              available.width > 0, available.height > 0 else { return }
        let scale = min(available.width / viewport.width,
                        available.height / viewport.height)
        let size = NSSize(width: viewport.width * scale,
                          height: viewport.height * scale)
        webView.frame = NSRect(
            x: available.minX + (available.width - size.width) / 2,
            y: available.minY + (available.height - size.height) / 2,
            width: size.width, height: size.height)
        webView.pageZoom = scale
    }

    /// リサイズ・設定変更後の再ページ割り(連続リサイズをデバウンス)。
    /// セットアップ実行中に届いた要求は捨てずに完了後へ繰り越す(捨てると
    /// lastLaidOutSize が先に更新され、以後そのサイズでは再ページ割りされない)
    private func schedulePagination(preserveProgression: Bool) {
        guard webView != nil, publication != nil else { return }
        guard allowsVisibleRenderingWork else {
            // cooViewer-oxr.54: 設定変更経路も不可視中は同じ延期状態へ畳む。
            pendingVisibleLayout = true
            return
        }
        // spine 読み込み中(didFinish 前)は再ページ割りを走らせない。
        // ここで走らせると、文書のロード完了前に repaginate が isLoadingSpineItem
        // や alpha を早期リセットして、旧文書の境界イベント受理や表示のちらつきを
        // 招く(世代トークンは同一世代なので防げない)。didFinish 後の
        // runSetup 完了時に defer が pendingRepaginate を拾って正しい順序で走る
        if isSettingUp || isLoadingSpineItem {
            pendingRepaginate = true
            return
        }
        repaginateWork?.cancel()
        let generation = spineLoadGeneration
        repaginateWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.runSetup(preserveProgression: preserveProgression,
                                 generation: generation)
        }
    }

    func setupOptionsJSON() -> String {
        let frame = contentFrame
        var options: [String: Any] = [
            "width": Double(frame.width.rounded(.down)),
            "height": Double(frame.height.rounded(.down)),
            "gap": settings.pageGap,
            "spread": isSpread,
            "gutter": Double(spreadGutter(forContentWidth: frame.width)),
            "fixedLayout": isFixedLayoutItem,
            "keysEnabled": settings.handlesKeyboardNavigation,
            // cooViewer-oxr.27: 既定は即時。明示 opt-in 時だけ click を保留する。
            "deferTaps": settings.defersTapsForDoubleClick,
            "fontScale": settings.fontScale,
            "defaultFontCSS": settings.defaultFontCSS(),
            "userCSS": settings.composedUserCSS(
                isDark: isDarkEffective,
                increaseContrast: shouldIncreaseContrast,
                differentiateWithoutColor: shouldDifferentiateWithoutColor),
        ]
        if settings.defersTapsForDoubleClick {
            let interval = NSEvent.doubleClickInterval
            options["doubleClickDelayMS"] = 1_000 * (interval > 0 ? interval : 0.5)
        }
        if isFixedLayoutItem { options["width"] = 0; options["height"] = 0 }
        let data = (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// JS へ復元先の適用を依頼した時点では実位置が未確定なので、locator は
    /// pageChanged が届くまで保持する
    func applyPendingTargetAfterSetup() {
        applyTarget(pendingTarget)
    }

    /// didFinish 後(または再ページ割り時)のセットアップ実行。
    /// generation が現在の spine 読み込み世代と食い違ったら何もしない
    /// (guard は JS await の後にも必要 — await 中に別の spine へ
    /// 移っていたら、その文書の状態を消費・破壊してはならない)
    private func runSetup(preserveProgression: Bool, generation: Int) async {
        guard let webView, generation == spineLoadGeneration else { return }
        isSettingUp = true
        defer {
            isSettingUp = false
            // 実行中に届いた再ページ割り(リサイズ・設定変更)を後追いする
            if pendingRepaginate {
                pendingRepaginate = false
                schedulePagination(preserveProgression: true)
            }
        }
        let call = preserveProgression
            ? "return __washi.repaginate(\(setupOptionsJSON()));"
            : "return __washi.setup(\(setupOptionsJSON()));"
        do {
            let result = try await webView.callAsyncJavaScript(
                call, arguments: [:], in: nil, contentWorld: Self.washiWorld)
            guard !Task.isCancelled,
                  generation == spineLoadGeneration,
                  webView === self.webView else { return }
            if let dict = result as? [String: Any] {
                applySetupResult(dict)
            }
            if !preserveProgression {
                // cooViewer-oxr.23: 新文書の target が発行する pageChanged は
                // 受けつつ、それ以前の旧文書通知だけを loading gate で捨てる。
                isLoadingSpineItem = false
                applyPendingTargetAfterSetup()
            }
            isLoadingSpineItem = false
            pendingTarget = .start
            updateFurniture()
            scheduleCensusIfNeeded()  // メトリクス変化(フォント・寸法)に追従
            webView.alphaValue = 1  // 持ち越しカバーがあればその下で戻る
            if let pending = pendingSpineTurn {
                // spine 遷移演出の仕上げ: 新ページの描画完了を待って撮り、
                // 項目内めくりと同じ演出でカバー(旧ページ)を取り除く
                pendingSpineTurn = nil
                // このカバーの時間切れ回収タスクを **snapshot の await より前** に
                // 止める。runTurnEffect 冒頭でも止めるが、下の takeSnapshot 待ちの
                // 間に membership タイムアウトが発火するとカバーを途中で引き剥がし、
                // superview を失ったビューを演出することになる
                let coverID = ObjectIdentifier(pending.cover)
                spineTurnTimeouts[coverID]?.cancel()
                spineTurnTimeouts[coverID] = nil
                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = true
                // ノンブルは runSetup の updateFurniture(前進)または
                // .end 適用時の pageChanged(後退。snapshot 待ちの間に届く)で
                // 新項目の値になっている
                let newPage = (try? await webView.takeSnapshot(
                    configuration: config))
                    .map { self.composeFullPage(webImage: $0, in: webView.frame) }
                guard generation == spineLoadGeneration else { return }
                runTurnEffect(oldPage: pending.oldPage, newPage: newPage,
                              cover: pending.cover, forward: pending.forward)
            }
        } catch {
            guard !Task.isCancelled else { return }
            // 古い文書の JS 失敗で新しい文書の読み込み状態を壊さない
            guard generation == spineLoadGeneration else { return }
            cancelPendingTextRangeRequest()
            isLoadingSpineItem = false
            clearPendingSpineTurn()
            webView.alphaValue = 1
            delegate?.readerView(self, didFailWith: error)
        }
    }

    /// cooViewer-oxr.48: JS の機能検出結果を公開状態へ写し、縦見開きの
    /// 単ページ縮退を診断可能にする。
    func applySetupResult(_ result: [String: Any]) {
        if let count = result["pageCount"] as? Int {
            pageCountInItem = max(1, count)
        }
        isImagePage = result["imagePage"] as? Bool ?? false
        pagesPerScreen = max(1, result["pagesPerScreen"] as? Int ?? 1)
        if let measured = result["firstPageOnRight"] as? Bool {
            firstPageOnRight = measured
        }
        if let markers = result["printPageMarkers"] as? [[String: Any]] {
            // cooViewer-oxr.38: JS の文書順を保ち、壊れた値だけを捨てる。
            printPageMarkers = markers.compactMap { marker in
                guard let label = marker["label"] as? String, !label.isEmpty,
                      let page = marker["page"] as? Int, page >= 0 else {
                    return nil
                }
                return PrintPageMarker(label: label, page: page)
            }
        }
        guard let supported = result["supportsColumnAxis"] as? Bool else { return }
        let shouldLog = columnAxisSupported && !supported && isSpread
            && ["vrl", "vlr"].contains(result["mode"] as? String ?? "")
        columnAxisSupported = supported
        if shouldLog {
            Self.logger.warning(
                "Vertical spread fell back to one page because column-axis is unsupported")
        }
    }

    // MARK: - 全文ページ数の実測(census)

    /// Page count of each spine item at the current metrics (nil until the
    /// measurement completes). Re-measured whenever the font size, window
    /// dimensions, or spread mode change.
    public private(set) var pageCensus: [Int]?

    /// Total page count across the whole book (nil until the census completes).
    public var censusTotalPages: Int? { pageCensus?.reduce(0, +) }

    /// Exports the completed whole-book census so a host can persist it and
    /// re-inject it on a later open, skipping the offscreen re-measure (the
    /// N/M page label and page bar then appear immediately). Nil until the
    /// census for the current metrics has completed.
    public func exportCensus() -> EPUBCensusRecord? {
        guard let counts = pageCensus, let key = pageCensusMetricsKey else {
            return nil
        }
        return EPUBCensusRecord(
            metricsKey: key, counts: counts,
            releaseIdentifier: publication?.metadata.releaseIdentifier)
    }

    /// Seeds a previously exported census. It is accepted only if it matches
    /// the current book — same spine item count and same release identifier.
    /// The release identifier uses the modified timestamp when present, then
    /// falls back to the package identifier; it is nil only when the package
    /// has no unique identifier. When its metrics key also matches the current
    /// display metrics, it takes effect immediately; otherwise it is cached and
    /// used the moment the display settles to those metrics. Returns whether it
    /// was accepted.
    @discardableResult
    public func importCensus(_ record: EPUBCensusRecord) -> Bool {
        guard let publication,
              EPUBScreenMetrics.usesCurrentPaginationVersion(record.metricsKey),
              record.counts.count == publication.readingOrder.count,
              record.releaseIdentifier == publication.metadata.releaseIdentifier
        else { return false }
        censusCache[record.metricsKey] = record.counts
        if record.metricsKey == censusOptionsJSON() {
            censusKey = record.metricsKey
            pageCensus = record.counts
            delegate?.readerViewDidUpdatePageCensus(self)
        }
        return true
    }

    /// The metrics key of the completed census (for the host to validate a
    /// match when reusing the census in its own cache). Returns a value only
    /// once the measurement has completed — `censusKey` alone cannot be trusted,
    /// because it is updated ahead of time when the measurement begins.
    public var pageCensusMetricsKey: String? {
        pageCensus != nil ? censusKey : nil
    }

    private var censusEngine: EPUBPaginationCensus?
    private var censusTask: Task<Void, Never>?
    /// 計測時のメトリクスキー(census 用オプション JSON。sortedKeys で決定的)
    private var censusKey: String?
    /// メトリクスキー → 実測結果(フォントを行き来したときの再計測を省く)
    private var censusCache: [String: [Int]] = [:]

    /// Whole-book offset of a spine item's first page (0-based).
    public func censusPageOffset(forSpineIndex index: Int) -> Int? {
        guard let pageCensus, index >= 0, index <= pageCensus.count else { return nil }
        return pageCensus.prefix(index).reduce(0, +)
    }

    /// Whole-book page-number range of the currently displayed pages (1-based;
    /// two pages in a spread). Clamped at boundaries where the measured page
    /// count and the actually displayed count may diverge.
    public var currentGlobalPageRange: ClosedRange<Int>? {
        guard let counts = pageCensus,
              counts.indices.contains(currentSpineIndex),
              let offset = censusPageOffset(forSpineIndex: currentSpineIndex)
        else { return nil }
        let itemPages = counts[currentSpineIndex]
        let first = offset + min(pageInItem, max(0, itemPages - 1)) + 1
        let last = offset + min(pageInItem + pagesPerScreen, itemPages)
        return first...max(first, last)
    }

    /// Whole-book page number (0-based) → position. Nil until the census completes.
    public func censusLocator(forGlobalPage page: Int) -> EPUBLocator? {
        guard let counts = pageCensus, !counts.isEmpty else { return nil }
        var remaining = max(0, page)
        for (index, count) in counts.enumerated() {
            if remaining < count {
                let progression = count <= 1
                    ? 0 : Double(remaining) / Double(count - 1)
                return publication?.locator(forSpineIndex: index,
                                            progression: progression)
                    ?? EPUBLocator(spineIndex: index, progression: progression)
            }
            remaining -= count
        }
        return publication?.locator(forSpineIndex: counts.count - 1, progression: 1)
            ?? EPUBLocator(spineIndex: counts.count - 1, progression: 1)
    }

    /// Position → whole-book page number (0-based). Nil until the census
    /// completes or when the locator does not address a measured spine item.
    public func censusGlobalPage(for locator: EPUBLocator) -> Int? {
        guard let locator = publication?.resolve(locator),
              let counts = pageCensus,
              counts.indices.contains(locator.spineIndex) else { return nil }
        let count = counts[locator.spineIndex]
        guard count > 0 else { return nil }
        let offset = counts.prefix(locator.spineIndex).reduce(0, +)
        // censusLocator(forGlobalPage:) と同じ 0 始まり・項目内 (count - 1)
        // 分割へ戻す。rounded() により両方向の量子化を対称にする
        // cooViewer-oxr.73: Double → Int の範囲外変換は SIGTRAP になるため、
        // locator 自身の不変条件だけに依存せず変換直前にも防御する。
        let safeProgression = Self.clampedProgression(locator.progression)
        let inItem = Int((safeProgression * Double(count - 1)).rounded())
        return offset + min(max(0, inItem), count - 1)
    }

    private static func clampedProgression(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(1, max(0, value))
    }

    // MARK: - 画面サムネイル(ホストの一覧 UI 用)

    /// Number of pages laid out on one screen at the current metrics (1 = single
    /// page / 2 = spread). Used to divide the thumbnail list into screens (a
    /// single-image item resolves to 1 at run time, but this is the planned
    /// value for "what a reflowable text item would be").
    public var plannedPagesPerScreen: Int {
        currentScreenMetrics.pagesPerScreen
    }

    /// Toggles between planned single-page and two-page layout. Unlike
    /// ``pagesPerScreen``, this remains correct while a single-image page is
    /// displayed.
    public func toggleColumnMode() {
        var updated = settings
        // cooViewer-oxr.20: 表紙の実測値(常に 1)でなく画面計画を反転する。
        updated.columnMode = plannedPagesPerScreen == 2 ? .single : .double
        settings = updated
    }

    private var thumbnailRenderer: EPUBScreenThumbnailRenderer?

    /// Thumbnail of a given screen (the same pagination as the live view and the
    /// census; rendered offscreen, colored to match the current theme). `width`
    /// is the output width in pt. Nil on failure.
    public func screenThumbnail(spineIndex: Int, pageInItem: Int,
                                width: CGFloat) async -> CGImage? {
        guard let publication else { return nil }
        let renderer = thumbnailRenderer
            ?? EPUBScreenThumbnailRenderer(publication: publication)
        thumbnailRenderer = renderer
        let itemMetrics = EPUBScreenMetrics(
            viewportSize: bounds.size, settings: settings,
            renditionSpread: effectiveSpread(forSpineIndex: spineIndex))
        return await renderer.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            optionsJSON: itemMetrics.themedOptionsJSON(isDark: isDarkEffective),
            contentSize: itemMetrics.contentSize, snapshotWidth: width)
    }

    /// リフロー時のコンテンツ寸法(現在項目が FXL でも「リフロー項目なら
    /// こうなる」寸法。census のメトリクスは現在項目に依存させない)
    private func reflowContentSize() -> NSSize {
        censusScreenMetrics.contentSize
    }

    /// census 用のセットアップオプション(= リフロー項目の setup と同値。
    /// メトリクスの同一性キーとしても使う)
    private func censusOptionsJSON() -> String {
        censusScreenMetrics.censusOptionsJSON
    }

    /// メトリクスごとの実測失敗台帳(2-strike + TTL)。上限を超えたキーは
    /// 再スケジュールしない(壊れた spine を持つ本で runSetup のたびに 15 秒
    /// タイムアウトを繰り返さないため)が、TTL 経過で赦して再挑戦させる
    /// (一時要因で欠けたページ数がセッション中ずっと出ないのを防ぐ)
    private var censusFailures = CensusFailureLedger()

    /// Stops the background census (for when the host leaves the EPUB view; it
    /// is naturally rescheduled by the next runSetup / layout).
    public func cancelPageCensus() {
        censusTask?.cancel()
        censusTask = nil
    }

    /// When detached from a window (close, view removal), stops the offscreen
    /// measurement and tears down the invisible window and WebContent process.
    /// A safeguard so that even a host unaware of the explicit cancelPageCensus
    /// does not leak. If shown again, the next runSetup / layout naturally
    /// resumes the census.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateNativeKeyMonitor()
        guard window == nil else {
            resumeDeferredVisibleWork()
            return
        }
        pendingVisibleLayout = webView != nil
        cancelPageCensus()
        censusEngine?.invalidate()
        censusEngine = nil
        thumbnailRenderer?.invalidate()
        thumbnailRenderer = nil
    }

    public override func viewDidHide() {
        super.viewDidHide()
        guard webView != nil else { return }
        // cooViewer-oxr.54: 進行中の計測も隠れたビューのために継続しない。
        pendingVisibleLayout = true
        repaginateWork?.cancel()
        repaginateWork = nil
        pendingRepaginate = false
        cancelPageCensus()
        // cooViewer-oxr.54: cancel 済み measure の離脱前に再表示されても同じ
        // WKWebView へ新旧 census を並走させないよう、エンジンごと交換する。
        censusEngine?.invalidate()
        censusEngine = nil
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        resumeDeferredVisibleWork()
    }

    private func resumeDeferredVisibleWork() {
        guard allowsVisibleRenderingWork else { return }
        resumePendingWebContentReloadIfNeeded()
        guard pendingVisibleLayout else {
            scheduleCensusIfNeeded()
            return
        }
        pendingVisibleLayout = false
        guard let webView else { return }
        layoutFurniture()
        layoutVisibleContent(webView, forcePagination: true)
    }

    /// cooViewer-oxr.54: 回帰テストが非表示中の延期状態を同期的に確認する。
    var hasDeferredVisibleLayout: Bool { pendingVisibleLayout }

    var isPageCensusScheduled: Bool { censusTask != nil }

    var isRepaginationScheduled: Bool { repaginateWork != nil }

    // MARK: - ネイティブキー横取り(forwardsKeyEventsNatively)

    /// ウインドウ在席と設定に応じてローカルキーモニタを付け外しする。
    /// WKWebView がファーストレスポンダを握るとビューの keyDown は呼ばれず
    /// JS 経路のキーも取りこぼすため、ホストが確実に NSEvent を受け取れるよう
    /// ウインドウレベルの local monitor で横取りする(cooViewer が自前で
    /// やっていた対処をパッケージ側の任意機能として提供)
    private func updateNativeKeyMonitor() {
        let shouldMonitor = window != nil && settings.forwardsKeyEventsNatively
        if shouldMonitor, keyEventMonitor == nil {
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self, let window = self.window,
                      event.window === window, self.delegate != nil,
                      // 自分(またはその子 WebView)がこのウインドウで
                      // 表示中のときだけ横取りする
                      !self.isHidden, self.superview != nil else { return event }
                return self.delegate?.readerView(self, didReceiveNativeKey: event)
                    == true ? nil : event
            }
        } else if !shouldMonitor, let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    /// メトリクスが変わっていれば census を(デバウンス付きで)再実測する。
    /// runSetup 完了時と FXL 表示中のリサイズで呼ぶ — リサイズ・フォント倍率・
    /// 見開き切替に追従する
    func scheduleCensusIfNeeded() {
        guard let publication, !publication.readingOrder.isEmpty else { return }
        // ウインドウから外れている間・非表示中はオフスクリーン計測を始めない
        // (viewDidMoveToWindow で畳んだ直後に runSetup 由来の呼び出しが
        // 実測を復活させ、不可視ウインドウ/プロセスが生き返るのを防ぐ。
        // 再表示されれば layout/runSetup が改めて呼ぶ)
        guard allowsVisibleRenderingWork else {
            pendingVisibleLayout = true
            return
        }
        let key = censusOptionsJSON()
        // 実測に使う寸法はキーと同じ瞬間に採る(デバウンス起床時に採ると、
        // 窓の終盤のリサイズで「旧キーに新寸法の実測」が入りキャッシュが汚れる)
        let size = reflowContentSize()
        if censusKey == key {
            if pageCensus != nil { return }
            // 同一メトリクスで実測中なら継続させる(spine 遷移のたびに
            // runSetup から呼ばれるため、ここで中断すると大きい本で
            // いつまでも完走しない)。成功・失敗・非キャンセル離脱のすべてで
            // censusTask を nil に戻すので(下記 3 経路)、この分岐が再実測を
            // 塞ぐことはない。この不変条件は「censusTask の再代入は必ず先行
            // cancel を伴う」規律(下の Task 生成箇所)に依存する
            if let censusTask, !censusTask.isCancelled { return }
        }
        if let cached = censusCache[key] {
            censusKey = key
            pageCensus = cached
            // 旧キーの計測が走っていれば止める(完走させても無駄なうえ、
            // 同じキーへ戻ったときの並走の種になる)
            censusTask?.cancel()
            delegate?.readerViewDidUpdatePageCensus(self)
            return
        }
        if censusFailures.shouldSkip(key) {
            // cooViewer-oxr.21: 失敗台帳で再試行を省く場合も、別メトリクスの
            // 成功値を N/M・ページバーへ残してはならない。
            if censusKey != key {
                censusTask?.cancel()
                censusTask = nil
                censusKey = key
                pageCensus = nil
                delegate?.readerViewDidUpdatePageCensus(self)
            }
            return
        }
        // 古いメトリクスの番号を出し続けないよう、まず無効化を通知
        if pageCensus != nil {
            pageCensus = nil
            delegate?.readerViewDidUpdatePageCensus(self)
        }
        censusKey = key
        // 規律: censusTask の再代入は必ず先行 cancel を伴う(上のガードの
        // 不変条件がこれに依存する。この規律を崩すと居座り/取り違えが再発する)
        censusTask?.cancel()
        let previous = censusTask
        // オフスクリーン WebKit のジョブは明示 .userInitiated で起動する
        // (低 QoS 継承だと最初の JS 実行の返信が返らない。兄弟の census/
        // rasterizer/thumbnail レンダラと規約を揃える)
        censusTask = Task(priority: .userInitiated) { [weak self] in
            // リサイズ嵐・連続の設定変更を合流させる
            try? await Task.sleep(for: .milliseconds(300))
            // 旧計測の完全な離脱を待つ(FIFO 直列化)。同じ WKWebView 上で
            // 新旧の measure が並走すると、ナビゲーションイベントの取り違えで
            // 失敗や「1 項目ずれた実測値」のキャッシュ汚染が起きる
            // (EPUBPageRasterizer と同じ直列化方針)
            _ = await previous?.value
            // measure の await をまたいで self を強参照しない: ホストが
            // ビューを手放したら、全 spine 実測(壊れた本は 1 項目 15 秒
            // タイムアウト×N)を道連れにビューが生き残らないように。
            // キャンセルは素通し(新タスクを潰さない)、非キャンセルの離脱は
            // censusTask を自己退去する(完了済みタスクが居座って再実測を
            // 永久に塞ぐのを防ぐ。成功・失敗経路と対称にする)
            guard !Task.isCancelled else { return }
            guard let publication = self?.publication, self?.censusKey == key
            else { self?.censusTask = nil; return }
            let engine = self?.censusEngine ?? EPUBPaginationCensus()
            self?.censusEngine = engine
            let counts = await engine.measure(
                publication: publication, optionsJSON: key, contentSize: size)
            guard let self, !Task.isCancelled, self.censusKey == key else { return }
            guard let counts else {
                // 失敗完了は「実測中」ではない — タスクを解放して次の
                // runSetup での再実測を許す(回数はキーごとに上限あり + TTL)
                self.recordCensusFailure(forKey: key)
                self.censusTask = nil
                return
            }
            self.censusCache[key] = counts
            self.pageCensus = counts
            self.censusTask = nil  // 成功完了も自己退去(不変条件を対称に保つ)
            self.delegate?.readerViewDidUpdatePageCensus(self)
        }
    }

    /// cooViewer-oxr.21: 実測経路と決定的な回帰テストで失敗台帳を共有する。
    func recordCensusFailure(forKey key: String) {
        censusFailures.recordFailure(key)
    }

    // MARK: - スナップショット

    /// Returns a snapshot of the raw web content and its frame in the reader
    /// view's coordinate system. The live web view cannot be snapshotted above
    /// its own size; the result is at backing scale, so `scale` only ever
    /// reduces the width.
    public func contentSnapshot(scale: CGFloat) async throws
        -> (image: NSImage, frame: CGRect) {
        guard let webView else { throw EPUBError.malformed("本が開かれていない") }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        // cooViewer-hnt: snapshotWidth の単位は画素ではなく点。拡大要求は
        // WebKit にクランプされるため、live view の幅を上限にする。
        configuration.snapshotWidth = NSNumber(
            value: max(1, min(Double(webView.bounds.width),
                              Double(webView.bounds.width * scale))))
        let image = try await webView.takeSnapshot(configuration: configuration)
        return (image, webView.frame)
    }

    /// Returns an image compositing the whole view (margins + web content).
    /// WKWebView does not appear in layer-based drawing (cacheDisplay, etc.),
    /// so the result of takeSnapshot is composited over the background (for
    /// headless verification, thumbnails, and the page-turn effects).
    public func snapshot() async throws -> NSImage {
        guard let webView else { throw EPUBError.malformed("本が開かれていない") }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let webImage = try await webView.takeSnapshot(configuration: configuration)
        return composeFullPage(webImage: webImage, in: webView.frame)
    }

    /// 背景(余白)+本文+ノンブルを 1 枚に焼いた「紙のページ全体」の像。
    /// snapshot()(検証・サムネイル)とページめくり演出が共用する:
    /// webView のスナップショットには本文領域しか写らないため、めくりを
    /// 実際の本のように余白ごと動かすにはこの合成が要る。
    /// 演出側は cgImage(forProposedRect:) でビットマップを取り出すので、
    /// 描画ハンドラ形式(環境によっては 1x で取り出されて文字がぼける)では
    /// なく、backing scale のビットマップへ直接合成して解像度を固定する
    func composeFullPage(webImage: NSImage, in webFrame: NSRect) -> NSImage {
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(size.width * scale)),
            pixelsHigh: max(1, Int(size.height * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return webImage }
        rep.size = size
        let background = NSColor(cgColor: layer?.backgroundColor
            ?? NSColor.textBackgroundColor.cgColor) ?? .white
        let furniture = pageNumberLabels
            .filter { !$0.isHidden }
            .map { (text: $0.attributedStringValue, frame: $0.frame,
                    color: $0.textColor ?? .secondaryLabelColor,
                    font: $0.font ?? .systemFont(ofSize: 11)) }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            webImage.draw(in: webFrame)
            for item in furniture {
                // 柱・ノンブルも合成する(ページと一緒にめくれて見えるように)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: item.font, .foregroundColor: item.color,
                ]
                NSAttributedString(string: item.text.string,
                                   attributes: attributes).draw(in: item.frame)
            }
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - 印刷ページ / アクセシビリティ

    /// cooViewer-oxr.38: 現在 spine の最後の marker を優先し、章頭より前なら
    /// page-list 上で直前 spine を指す最後のラベルへフォールバックする。
    private func updateCurrentPrintPage() {
        let local = printPageMarkers.last {
            $0.page <= pageInItem
        }?.label
        let fallback = flattenedPrintPageList.last { item in
            guard let publication,
                  let index = publication.spineIndex(forNavItem: item) else {
                return false
            }
            return index < currentSpineIndex
        }?.title
        setCurrentPrintPage(local ?? fallback)
    }

    private func setCurrentPrintPage(_ label: String?) {
        guard label != currentPrintPage else { return }
        currentPrintPage = label
        updateAccessibilityMetadata()
        delegate?.readerView(self, didChangePrintPage: label)
    }

    private var localizedPageValue: String {
        let language = accessibilityPreferredLanguageOverride
            ?? Locale.preferredLanguages.first ?? "en"
        if language.lowercased().hasPrefix("ja") {
            return "ページ \(pageInItem + 1) / \(pageCountInItem)"
        }
        return "Page \(pageInItem + 1) of \(pageCountInItem)"
    }

    private func updateAccessibilityMetadata() {
        let title = publication?.metadata.mainTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let label = title.flatMap { $0.isEmpty ? nil : "EPUB reader — \($0)" }
            ?? "EPUB reader"
        setAccessibilityLabel(label)
        let value = settings.showsPrintPageInFurniture
            ? currentPrintPage.map { "\(localizedPageValue) [p. \($0)]" }
                ?? localizedPageValue
            : localizedPageValue
        setAccessibilityValue(value)
    }

    /// cooViewer-oxr.37: pageChanged の短い連続を最後の確定位置へ畳み、同じ
    /// spine/page/count の重複通知を読み上げない。
    private func scheduleAccessibilityPageAnnouncement() {
        accessibilityAnnouncementTask?.cancel()
        accessibilityAnnouncementTask = nil
        guard settings.announcesPageChanges else { return }
        let identity = SettledPageIdentity(
            spineIndex: currentSpineIndex, page: pageInItem,
            pageCount: pageCountInItem)
        guard identity != lastAnnouncedPage else { return }
        let message = localizedPageValue
        let delay = accessibilityAnnouncementDelay
        accessibilityAnnouncementTask = Task { @MainActor [weak self] in
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard let self, !Task.isCancelled,
                  !self.isLoadingSpineItem,
                  self.currentSpineIndex == identity.spineIndex,
                  self.pageInItem == identity.page,
                  self.pageCountInItem == identity.pageCount else { return }
            self.accessibilityAnnouncementTask = nil
            if let handler = self.accessibilityAnnouncementHandler {
                self.lastAnnouncedPage = identity
                handler(message)
                return
            }
            guard NSWorkspace.shared.isVoiceOverEnabled else { return }
            self.lastAnnouncedPage = identity
            NSAccessibility.post(
                element: self,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium,
                ])
        }
    }

    // MARK: - JS からのメッセージ

    func handleScriptMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return }
        switch type {
        case "pageChanged":
            // cooViewer-oxr.19/23: 旧文書から遅配された位置通知で、新しい
            // pending target / 復元位置とホストの保存位置を上書きしない。
            guard !isLoadingSpineItem else { break }
            pageInItem = dict["page"] as? Int ?? 0
            pageCountInItem = max(1, dict["pageCount"] as? Int ?? 1)
            pagesPerScreen = max(1, dict["pagesPerScreen"] as? Int ?? pagesPerScreen)
            pendingRestoreLocator = nil  // 実位置が確定した
            updateCurrentPrintPage()
            updateFurniture()
            delegate?.readerView(self, didMoveTo: currentLocator,
                                 pageInItem: pageInItem,
                                 pageCountInItem: pageCountInItem)
            scheduleAccessibilityPageAnnouncement()
        case "boundary":
            // spine 切替の読み込み中に旧文書から届く境界イベントは捨てる
            // (トラックパッド慣性やキーリピートでの章飛び越し防止)
            guard !isLoadingSpineItem else { break }
            let forward = dict["forward"] as? Bool ?? true
            advanceSpine(forward: forward)
        case "wheelTurn":
            // ホイール/トラックパッドの 1 ジェスチャ 1 ページ(JS でラッチ済み)。
            // native 経由にするのはスライド演出を共通で付けるため。
            // spine 読み込み中の残存慣性は boundary と同じく捨てる(FXL 項目が
            // 表示される前に advanceSpine で飛ばされるカスケードを防ぐ)。
            // 水平ジェスチャは物理方向(deltaX>0=右側のページ)として受け、
            // 綴じ方向への変換はタップと同じく turnPageLeft/Right が担う
            // (JS は表紙等の画像ページで本の writing-mode を知れない)。
            // 垂直ジェスチャは内部縦積みと一致するので下=読書順で次
            guard !isLoadingSpineItem else { break }
            let forward = dict["forward"] as? Bool ?? true
            if dict["horizontal"] as? Bool ?? false {
                // native 経路と同じくホスト設定でゲート・反転する
                guard settings.horizontalWheelTurnsPages else { break }
                let towardRight = forward != settings.reversesHorizontalWheelTurn
                towardRight ? turnPageRight() : turnPageLeft()
            } else {
                forward ? goForward() : goBackward()
            }
        case "link":
            handleLink(dict)
        case "tap":
            // DOM のボタン番号(0=左,1=中,2=右,3/4=サイド)→ NSEvent 流
            // (0=左,1=右,2=中,3/4=サイド)へ写像。右は JS 側で除外済み
            let domButton = dict["button"] as? Int ?? 0
            let button = domButton == 1 ? 2 : (domButton == 2 ? 1 : domButton)
            let normalizedX = dict["x"] as? Double ?? 0.5
            let normalizedY = dict["y"] as? Double ?? 0.5
            let location = webView.map {
                readerViewPoint(forNormalizedContentX: normalizedX,
                                y: normalizedY, in: $0)
            } ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let event = EPUBClickEvent(
                x: normalizedX,
                y: normalizedY,
                locationInView: location,
                button: button,
                shift: dict["shift"] as? Bool ?? false,
                option: dict["alt"] as? Bool ?? false,
                control: dict["ctrl"] as? Bool ?? false,
                command: dict["meta"] as? Bool ?? false)
            dispatchClick(event)
        case "selection":
            guard !isLoadingSpineItem else { break }
            guard let text = dict["text"] as? String, !text.isEmpty,
                  let start = dict["start"] as? Int,
                  let end = dict["end"] as? Int,
                  start >= 0, end > start,
                  let rawRects = dict["rects"] as? [[String: Any]],
                  let webView else {
                setCurrentSelection(nil)
                break
            }
            let rects = rawRects.compactMap {
                readerViewRect(from: $0, in: webView)
            }
            guard rects.count == rawRects.count else {
                setCurrentSelection(nil)
                break
            }
            setCurrentSelection(EPUBTextSelection(
                spineIndex: currentSpineIndex, text: text,
                utf16Range: start..<end, rects: rects))
        case "key":
            let event = EPUBKeyEvent(
                key: dict["key"] as? String ?? "",
                code: dict["code"] as? String ?? "",
                shift: dict["shift"] as? Bool ?? false,
                option: dict["alt"] as? Bool ?? false,
                control: dict["ctrl"] as? Bool ?? false,
                command: dict["meta"] as? Bool ?? false)
            delegate?.readerView(self, didReceiveKey: event)
        default:
            break
        }
    }

    /// cooViewer-oxr.35: DOM の左上原点正規化座標を WebView の AppKit 座標へ
    /// 直し、余白入力と同じ reader-view 座標へ統一する。
    func readerViewPoint(
        forNormalizedContentX x: Double, y: Double, in webView: WKWebView
    ) -> CGPoint {
        let localY = webView.isFlipped
            ? CGFloat(y) * webView.bounds.height
            : (1 - CGFloat(y)) * webView.bounds.height
        let local = CGPoint(x: CGFloat(x) * webView.bounds.width, y: localY)
        return webView.convert(local, to: self)
    }

    private var effectiveContextMenuPolicy: EPUBContextMenuPolicy {
        if settings.contextMenuPolicy == .system && settings.suppressesContextMenu {
            return .suppressed
        }
        return settings.contextMenuPolicy
    }

    /// cooViewer-oxr.35, cooViewer-oxr.93: policy を先に適用し、空になっても
    /// 1 イベントにつき 1 回 delegate の最終カスタマイズへ渡す。
    /// イベント位置は tap/余白 click と同じ座標系。
    func contextMenu(_ menu: NSMenu, for event: NSEvent) -> NSMenu? {
        _ = effectiveContextMenuPolicy.filter(menu)
        let location = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let click = EPUBClickEvent(
            x: Double(location.x / max(1, bounds.width)),
            y: Double(1 - location.y / max(1, bounds.height)),
            locationInView: location,
            button: event.buttonNumber,
            shift: flags.contains(.shift), option: flags.contains(.option),
            control: flags.contains(.control), command: flags.contains(.command))
        guard let delegate else { return menu }
        guard let resolved = delegate.readerView(
            self, willShowContextMenu: menu, at: click) else {
            menu.removeAllItems()
            return nil
        }
        return resolved
    }

    /// クリックの共通ディスパッチ(JS の tap 通知と余白のネイティブクリック)
    private func dispatchClick(_ event: EPUBClickEvent) {
        if delegate?.readerView(self, didClick: event) != true,
           event.isPlainPrimary {
            // 既定動作: 左右端のタップでページ送り(物理方向。
            // 右綴じなら左=進む — 紙の本のめくり方向と一致)
            if event.x < 0.4 {
                turnPageLeft()
            } else if event.x > 0.6 {
                turnPageRight()
            }
        }
    }

    // MARK: - 余白(WKWebView 外)のネイティブ入力

    // 版面余白(insets)は WKWebView の外側にあり JS の click/wheel 捕捉が
    // 届かない。画像本は view 全域でバインドが効くため、柱・ノンブル領域の
    // クリックとホイールも同じ入力系へ合流させる(WKWebView 内のイベントは
    // WKWebView 自身が消費するのでここへは来ない)

    private var marginPressTime: TimeInterval = 0
    private var marginPressLocation = NSPoint.zero

    public override func mouseDown(with event: NSEvent) {
        notePress(event)
        super.mouseDown(with: event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        notePress(event)
        super.otherMouseDown(with: event)
    }

    private func notePress(_ event: NSEvent) {
        marginPressTime = event.timestamp
        marginPressLocation = convert(event.locationInWindow, from: nil)
    }

    public override func mouseUp(with event: NSEvent) {
        if !dispatchMarginClick(event, button: 0) { super.mouseUp(with: event) }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if !dispatchMarginClick(event, button: event.buttonNumber) {
            super.otherMouseUp(with: event)
        }
    }

    private func dispatchMarginClick(_ event: NSEvent, button: Int) -> Bool {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              !(webView.map { $0.frame.contains(location) } ?? false)
        else { return false }
        // JS の click 抑制と同じ閾値(§5.9): 30pt 超のドラッグ・1 秒超の
        // 長押しの解放はクリックにしない(イベントは消費する)
        guard event.timestamp - marginPressTime <= 1.0,
              max(abs(location.x - marginPressLocation.x),
                  abs(location.y - marginPressLocation.y)) <= 30
        else { return true }
        let flags = event.modifierFlags
        // y は JS の tap と同じ「上端 0」の正規化(この view は非 flipped)
        dispatchClick(EPUBClickEvent(
            x: Double(location.x / max(1, bounds.width)),
            y: Double(1 - location.y / max(1, bounds.height)),
            locationInView: location,
            button: button,
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control),
            command: flags.contains(.command)))
        return true
    }

    private var marginWheelAccumulator: CGFloat = 0
    private var marginWheelLastTime: TimeInterval = 0
    private var marginWheelLatched = false
    private var marginWheelHorizontal = false

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location),
              !(webView.map { $0.frame.contains(location) } ?? false)
        else {
            super.scrollWheel(with: event)
            return
        }
        // JS 側と同じ「1 ジェスチャ = 1 ページ」量子化(250ms 静穏で解除・
        // 軸は最初のイベントで確定)。慣性はラッチが飲み込む
        if event.timestamp - marginWheelLastTime > 0.25 {
            marginWheelLatched = false
            marginWheelAccumulator = 0
            marginWheelHorizontal =
                abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        marginWheelLastTime = event.timestamp
        guard !marginWheelLatched else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 40
        marginWheelAccumulator += scale * (marginWheelHorizontal
            ? event.scrollingDeltaX : event.scrollingDeltaY)
        guard abs(marginWheelAccumulator) >= 50 else { return }
        let positive = marginWheelAccumulator > 0
        marginWheelAccumulator = 0
        marginWheelLatched = true
        // AppKit の scrollingDelta は DOM の wheel と符号が逆(正=文書の
        // 先頭方向へのスクロール)なので、JS の wheelTurn と対になる写像
        if marginWheelHorizontal {
            // 水平めくりはホスト設定でゲート・反転できる(ホストが自前の
            // スワイプめくりを持つ場合に二重発火を避け、綴じ方向をそろえる)
            guard settings.horizontalWheelTurnsPages else { return }
            let towardLeft = positive != settings.reversesHorizontalWheelTurn
            towardLeft ? turnPageLeft() : turnPageRight()
        } else {
            positive ? goBackward() : goForward()
        }
    }

    /// Extracts note content for an intercepted EPUB internal link.
    ///
    /// Notes in the displayed document include their inner HTML. Notes in a
    /// different reading-order document are parsed headlessly and return text
    /// only. Backlink anchors are removed in both cases.
    public func noteContent(for link: EPUBInternalLink) async -> EPUBNoteContent? {
        guard let publication, let fragment = link.fragment,
              !fragment.isEmpty,
              let sourceSpineIndex = publication.readingOrder.firstIndex(where: {
                  $0.resolvedContainerPath == link.containerPath
                      || $0.containerPath == link.containerPath
              })
        else { return nil }
        let source = publication.readingOrder[sourceSpineIndex]

        guard sourceSpineIndex == currentSpineIndex,
              !isLoadingSpineItem, let webView else {
            // cooViewer-oxr.32: 別 spine は UI actor を塞がず Core の XML 抽出で読む。
            let text = await Task.detached(priority: .userInitiated) {
                publication.noteText(
                    at: source.resolvedContainerPath, fragment: fragment)
            }.value
            return text.map {
                EPUBNoteContent(text: $0, html: nil,
                                sourceSpineIndex: sourceSpineIndex)
            }
        }

        // cooViewer-oxr.32: fragment は EPUB 由来なので JS 本文へ埋め込まず、
        // callAsyncJavaScript の引数として WebKit に渡す。
        let generation = spineLoadGeneration
        let result = await callWashiAsync(
            """
            function epubTypeOf(element) {
                return element.getAttributeNS(
                    'http://www.idpf.org/2007/ops', 'type')
                    || element.getAttribute('epub:type') || '';
            }
            function isNoteContainer(element) {
                const tag = (element.localName || '').toLowerCase();
                if (tag !== 'aside' && tag !== 'section') { return false; }
                const types = epubTypeOf(element).toLowerCase()
                    .split(/\\s+/).filter(Boolean);
                const role = (element.getAttribute('role') || '').toLowerCase();
                return types.includes('footnote') || types.includes('endnote')
                    || types.includes('rearnote')
                    || role === 'doc-footnote' || role === 'doc-endnote';
            }
            const target = document.getElementById(fragment);
            if (!target) { return { found: false, text: '', html: '' }; }
            let selected = target;
            const targetTag = (target.localName || '').toLowerCase();
            if (targetTag === 'li' || targetTag === 'p') {
                let ancestor = target.parentElement;
                while (ancestor) {
                    if (isNoteContainer(ancestor)) {
                        selected = ancestor;
                        break;
                    }
                    ancestor = ancestor.parentElement;
                }
            }
            const copy = selected.cloneNode(true);
            // cooViewer-oxr.32: 戻り先が不明な公開 link 値にも一貫して
            // 対応するため、注釈内の fragment-only anchor をすべて除く。
            for (const candidate of Array.from(copy.getElementsByTagName('*'))) {
                if ((candidate.localName || '').toLowerCase() !== 'a') { continue; }
                const href = candidate.getAttribute('href')
                    || candidate.getAttributeNS(
                        'http://www.w3.org/1999/xlink', 'href') || '';
                if (href.trim().startsWith('#')) { candidate.remove(); }
            }
            const html = copy.innerHTML;
            const staging = document.createElement('div');
            staging.style.cssText = 'position:fixed;left:-100000px;top:0;'
                + 'width:1000px;opacity:0;pointer-events:none;z-index:-2147483648;';
            staging.style.setProperty('display', 'block', 'important');
            copy.removeAttribute('hidden');
            copy.style.setProperty('display', 'block', 'important');
            staging.appendChild(copy);
            (document.body || document.documentElement).appendChild(staging);
            let text = '';
            try {
                text = typeof copy.innerText === 'string'
                    ? copy.innerText : (copy.textContent || '');
            }
            finally { staging.remove(); }
            return { found: true, text: text, html: html };
            """,
            arguments: ["fragment": fragment], in: webView)
        guard webView === self.webView,
              generation == spineLoadGeneration,
              currentSpineIndex == sourceSpineIndex,
              let dictionary = result as? [String: Any],
              dictionary["found"] as? Bool == true,
              let text = dictionary["text"] as? String,
              let html = dictionary["html"] as? String
        else { return nil }
        return EPUBNoteContent(text: text, html: html,
                               sourceSpineIndex: sourceSpineIndex)
    }

    /// href からフラグメントを取り出す。split は空要素を落とすため
    /// "#note1" のような同一文書内リンクで壊れないよう firstIndex で切る
    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let encoded = String(href[href.index(after: hash)...])
        guard !encoded.isEmpty else { return nil }
        // cooViewer-oxr.32: DOM id は URI fragment の percent decode 後の値で
        // 照合する。不正な escape は実在本を壊さないよう原文へ fallback する。
        return encoded.removingPercentEncoding ?? encoded
    }

    private func handleLink(_ message: [String: Any]) {
        guard let publication,
              publication.readingOrder.indices.contains(currentSpineIndex),
              let href = message["href"] as? String else { return }
        // 外部リンク(スキーム付き)
        if let url = URL(string: href), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            if delegate?.readerView(self, shouldOpenExternalURL: url) ?? true {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let currentPath = publication.readingOrder[currentSpineIndex]
            .resolvedContainerPath
        guard let path = ContainerPath.resolve(base: currentPath, href: href) else {
            return
        }
        let epubType = message["epubType"] as? String
        let role = message["role"] as? String
        let link = EPUBInternalLink(
            href: href,
            containerPath: path,
            fragment: Self.fragment(of: href),
            targetSpineIndex: publication.readingOrder.firstIndex {
                $0.resolvedContainerPath == path || $0.containerPath == path
            },
            epubType: epubType,
            role: role,
            isNoteReference: epubType?.lowercased().contains("noteref") == true
                || role?.caseInsensitiveCompare("doc-noteref") == .orderedSame,
            hasBacklink: message["backlink"] as? Bool ?? false,
            targetEpubType: message["targetEpubType"] as? String,
            anchorRect: (message["anchorRect"] as? [String: Any])
                .flatMap { raw in
                    guard let webView else { return nil }
                    return readerViewRect(from: raw, in: webView)
                })
        // cooViewer-oxr.32: delegate の拒否を履歴記録より先に確定し、既定経路は
        // goToContainerPath の一回だけにして二重記録を避ける。
        guard delegate?.readerView(self, shouldFollowInternalLink: link) ?? true
        else { return }
        goToContainerPath(path, fragment: link.fragment)
    }

    /// コンテナ内パスへの移動(リンクの共通経路)。必ず loadSpineItem を
    /// 経由して currentSpineIndex を保つ — WKWebView に直接遷移させると
    /// 柱・ページバー・読書位置の保存がすべて旧 spine 項目のまま狂う
    func goToContainerPath(_ path: String, fragment: String?,
                           recordsHistory: Bool = true) {
        guard let publication,
              publication.readingOrder.indices.contains(currentSpineIndex)
        else { return }
        let current = publication.readingOrder[currentSpineIndex]
        if path == current.containerPath || path == current.resolvedContainerPath {
            if recordsHistory { recordCurrentLocatorInHistory() }
            applyOrQueueTarget(fragment.map { .fragment($0) } ?? .start)
            return
        }
        guard let index = publication.readingOrder
            .firstIndex(where: {
                $0.containerPath == path || $0.resolvedContainerPath == path
            }) else { return }
        if recordsHistory { recordCurrentLocatorInHistory() }
        loadSpineItem(at: index, target: fragment.map { .fragment($0) } ?? .start)
    }

    /// cooViewer-oxr.31: 移動直前の locator を最大 50 件に丸め、利用可否が
    /// 変わったときだけ delegate へ通知する。
    private func recordCurrentLocatorInHistory() {
        if navigationHistory.count >= Self.navigationHistoryLimit {
            navigationHistory.removeFirst()
        }
        navigationHistory.append(currentLocator)
        updateCanGoBack()
    }

    private func clearNavigationHistory() {
        navigationHistory.removeAll(keepingCapacity: true)
        updateCanGoBack()
    }

    private func updateCanGoBack() {
        let updated = !navigationHistory.isEmpty
        guard updated != canGoBack else { return }
        canGoBack = updated
        delegate?.readerViewNavigationHistoryDidChange(self)
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension EPUBReaderView: WKNavigationDelegate, WKUIDelegate {
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url else {
            return (.cancel, preferences)
        }
        if url.scheme?.lowercased() == EPUBSchemeHandler.scheme {
            guard let path = schemeHandler?.containerPath(for: url) else {
                return (.cancel, preferences)
            }
            switch spineNavigationGate.disposition(
                for: path, navigationType: navigationAction.navigationType) {
            case .allowExpectedLoad:
                preferences.allowsContentJavaScript = settings.allowsScriptedContent
                return (.allow, preferences)
            case .routeThroughReader:
                // 文書が発行した遷移は種類を問わず直接通さず、spine・locator・
                // ページ割りを同時に更新する共通経路へ戻す
                goToContainerPath(
                    path, fragment: url.fragment(percentEncoded: false))
                return (.cancel, preferences)
            }
        }
        // JS のクリック捕捉をすり抜けたリンク(area 等)の安全網
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
           navigationAction.navigationType == .linkActivated {
            if delegate?.readerView(self, shouldOpenExternalURL: url) ?? true {
                NSWorkspace.shared.open(url)
            }
        }
        return (.cancel, preferences)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 別の spine へ移った後に届いた古い didFinish は無視する
        // (これを通すと古いセットアップが新文書の pendingTarget を消費する)
        guard navigation == nil || navigation === currentNavigation else { return }
        if isFixedLayoutItem {
            layoutFixedItem()
        }
        let generation = spineLoadGeneration
        Task { [weak self] in
            await self?.runSetup(preserveProgression: false,
                                 generation: generation)
        }
    }

    /// 連続ページ送りで前のナビゲーションが破棄されたときのキャンセル
    /// (NSURLErrorCancelled / WKError.frameLoadInterrupted)は正常系。
    /// 本物の失敗はコンテンツを見せたまま(alpha 復帰)通知する
    private func handleNavigationFailure(_ error: any Error) {
        let nsError = error as NSError
        let isCancellation =
            (nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled)
            // WebKitErrorFrameLoadInterruptedByPolicyChange(102): 別ナビゲーション
            // による中断(公開 enum に定数がないためドメイン+コードで判定)
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        guard !isCancellation else { return }
        cancelPendingTextRangeRequest()
        isLoadingSpineItem = false
        clearPendingSpineTurn()
        webView?.alphaValue = 1
        delegate?.readerView(self, didFailWith: error)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                        withError error: any Error) {
        // 別 spine へ移った後に届く古い失敗は無視(新文書の状態を壊さない)
        guard navigation == nil || navigation === currentNavigation else { return }
        handleNavigationFailure(error)
    }

    public func webView(_ webView: WKWebView,
                        didFailProvisionalNavigation navigation: WKNavigation!,
                        withError error: any Error) {
        guard navigation == nil || navigation === currentNavigation else { return }
        handleNavigationFailure(error)
    }

    /// Reopens at the current position if the web content process crashes,
    /// with bounded retry and backoff for repeated terminations.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // cooViewer-oxr.47: 再構築前の WebView から遅配された終了通知で、
        // 現在の再試行枠を消費したり新しい文書を再読込しない。
        guard webView === self.webView else { return }
        handleWebContentProcessTermination()
    }

    /// cooViewer-oxr.47: 時刻注入可能な本体を分け、60 秒窓を sleep なしで検証する。
    func handleWebContentProcessTermination(at now: Date = Date()) {
        switch webContentReloadLimiter.register(
            spineIndex: currentSpineIndex, at: now) {
        case .reload(let delay):
            webContentReloadRequestCount += 1
            scheduleWebContentReload(after: delay)
        case .suppress(let reportFailure):
            webContentReloadTask?.cancel()
            webContentReloadTask = nil
            pendingWebContentReloadDelay = nil
            if reportFailure {
                delegate?.readerView(
                    self,
                    didFailWith: EPUBError.malformed(
                        "web content process terminated repeatedly"))
            }
        }
    }

    private func scheduleWebContentReload(after delay: Duration) {
        webContentReloadTask?.cancel()
        webContentReloadTask = nil
        guard allowsVisibleRenderingWork else {
            // cooViewer-oxr.47: 不可視中は同じ再試行を保持し、表示復帰で消費する。
            pendingWebContentReloadDelay = delay
            return
        }
        pendingWebContentReloadDelay = nil
        guard delay != .zero else {
            performWebContentReload()
            return
        }
        webContentReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.webContentReloadTask = nil
            guard self.allowsVisibleRenderingWork else {
                self.pendingWebContentReloadDelay = .zero
                return
            }
            self.performWebContentReload()
        }
    }

    private func resumePendingWebContentReloadIfNeeded() {
        guard let delay = pendingWebContentReloadDelay,
              allowsVisibleRenderingWork else { return }
        scheduleWebContentReload(after: delay)
    }

    private func performWebContentReload() {
        guard publication != nil else { return }
        webContentReloadAttemptCount += 1
        reloadCurrentPublication()
    }

    /// Does not allow popups to open.
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}

/// userContentController が handler を強参照するため、weak 中継で循環を断つ
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: EPUBReaderView?

    init(owner: EPUBReaderView) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(message.body)
    }
}

/// cooViewer-oxr.35: WebKit の native menu を policy/delegate 経路へ渡す
/// WKWebView。返却 menu が別インスタンスなら表示対象へ項目を移す。
@MainActor
private final class WashiWebView: WKWebView {
    var contextMenuHandler: ((NSMenu, NSEvent) -> NSMenu?)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let resolved = contextMenuHandler.map { $0(menu, event) } ?? menu
        guard let resolved else {
            menu.removeAllItems()
            return
        }
        if resolved !== menu {
            menu.removeAllItems()
            for item in resolved.items {
                resolved.removeItem(item)
                menu.addItem(item)
            }
        }
        guard !menu.items.isEmpty else { return }
        super.willOpenMenu(menu, with: event)
    }
}
