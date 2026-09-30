import AppKit
import Washi

/// 一冊のリフロー EPUB に属する状態。表示ビューと入力モニタはウインドウ側で
/// 再利用するが、このオブジェクトは提示のたびに作り直す。同じ publication を
/// 再び開いた場合も、非同期処理はセッションの参照同一性で失効を判定する。
@MainActor
final class EPUBReadingSession {
    let publication: EPUBPublication
    let url: URL
    let collectionContext: EPUBCollectionContext?
    private(set) var isActive = true
    /// 同じ publication の再提示でも、設定同期中の旧ビュー通知を採用しない。
    var isConfiguringView = false

    var contentLoaded = false
    var bookmarks: [(name: String, locator: EPUBLocator)]
    let flattenedToc: [(title: String, indent: Int, item: EPUBNavItem)]
    var pageLabelText: String?
    var saveDebounce: Task<Void, Never>?
    var saveSchedule = EPUBSaveSchedule()
    let search = EPUBSearchSession()
    var footnoteTask: Task<Void, Never>?
    var footnotePopover: NSPopover?
    var lastClickLocation: CGPoint?
    /// 空選択通知では消さず、⌘E が使う直近の非空本文を保持する。
    var latestSelectionText: String?
    var curlHosts: [NSView] = []

    init(publication: EPUBPublication, url: URL,
         collectionContext: EPUBCollectionContext? = nil,
         bookmarks: [(name: String, locator: EPUBLocator)] = []) {
        self.publication = publication
        self.url = url
        self.collectionContext = collectionContext
        self.bookmarks = bookmarks
        flattenedToc = Self.flattenToc(publication.navigation.toc)
    }

    private static func flattenToc(_ items: [EPUBNavItem], indent: Int = 0)
        -> [(title: String, indent: Int, item: EPUBNavItem)] {
        var result: [(String, Int, EPUBNavItem)] = []
        for item in items {
            if item.href != nil, !item.title.isEmpty {
                result.append((item.title, indent, item))
            }
            result.append(contentsOf: flattenToc(item.children, indent: indent + 1))
        }
        return result
    }

    /// 閉窓では読書内容を保持する。Dock から再表示したときも同じセッションを
    /// 使えるよう、一時的な処理と表示だけを取り消す。
    func cancelTransientWork() {
        saveDebounce?.cancel()
        saveDebounce = nil
        search.teardown()
        dismissFootnote()
        for host in curlHosts { host.removeFromSuperview() }
        curlHosts.removeAll()
    }

    /// 本の切替・EPUB 退出でのみ終了する。取消前に無効化し、取消中の callback
    /// も旧セッションの結果を採用できないようにする。
    func end() {
        isActive = false
        cancelTransientWork()
    }

    func dismissFootnote() {
        footnoteTask?.cancel()
        footnoteTask = nil
        footnotePopover?.performClose(nil)
        footnotePopover = nil
    }
}

/// 検索パネルを閉じても本は残るため、検索の寿命は読書セッションより短い。
/// 世代は同じ本の中の要求を区別し、別の本との区別は ReadingSession が担う。
@MainActor
final class EPUBSearchSession {
    var panel: NSPanel?
    var model: EPUBSearchModel?
    var queryEpoch = 0
    var task: Task<Void, Never>?
    var landingEpoch = 0
    var pendingLanding: Int?
    /// 着地待機中に利用者が別の位置へ動いたかを判定する通算移動回数。
    var moveCount = 0
    var landingTask: Task<Void, Never>?
    var lastLanding: EPUBTextRangeLanding?
    var highlightHost: EPUBSearchHighlightHostView?

    func clearHighlight() {
        landingEpoch &+= 1
        pendingLanding = nil
        landingTask?.cancel()
        landingTask = nil
        lastLanding = nil
        highlightHost?.removeFromSuperview()
        highlightHost = nil
    }

    func teardown(closePanel: Bool = true) {
        clearHighlight()
        queryEpoch &+= 1
        task?.cancel()
        task = nil
        model?.clearResults()
        model = nil
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.nextResponder = nil
        panel.parent?.removeChildWindow(panel)
        if closePanel {
            panel.orderOut(nil)
            panel.close()
        }
    }
}
