import AppKit
import WebKit

/// 全 spine 項目のページ数を、本番表示と同一メトリクス(コンテンツ寸法・
/// フォント倍率・見開き・ギャップ)で実測する。リフローのページ数は
/// フォント設定・ウインドウ寸法で変わるため、「本全体で何ページ中の
/// 何ページ目か」を出すにはこの census が必要になる。
///
/// WKWebView はウインドウ外では描画が止まるため、ラスタライザと同じく
/// 画面外の不可視ウインドウに載せた専用 WKWebView で 1 項目ずつ順に
/// 読み込み、本番と同じ __washi.setup() を同じオプションで呼んで
/// pageCount を読み取る(計測式まで完全に一致させるため、推定式の
/// 二重実装はしない)。固定レイアウト項目は本番と同じく 1 ページ扱いで
/// 読み込みを省く。
///
/// 所有者(EPUBReaderView)は本が替わったらインスタンスごと作り直すこと
/// (scheme handler が本に紐づくため)。
@MainActor
final class EPUBPaginationCensus {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var schemeHandler: EPUBSchemeHandler?

    /// 各 spine 項目のページ数を実測する。
    /// 失敗(読み込みエラー・タイムアウト)またはキャンセル時は nil
    /// (部分結果は返さない — 古い合計でページ番号を出すより隠す方が良い)
    /// オフスクリーンリソース(不可視 NSWindow + WebContent プロセス)を
    /// 明示的に畳む。ホストが計測を使い終えたとき(ビューのウインドウ離脱・
    /// アトラスの破棄)に呼ぶ。以後 measure が呼ばれれば作り直される
    func invalidate() {
        webView?.navigationDelegate = nil
        webView = nil
        schemeHandler = nil
        window?.orderOut(nil)
        window = nil
    }

    func measure(publication: EPUBPublication, optionsJSON: String,
                 contentSize: NSSize) async -> [Int]? {
        prepareIfNeeded(publication: publication, contentSize: contentSize)
        guard let webView, let schemeHandler else { return nil }
        var counts: [Int] = []
        counts.reserveCapacity(publication.readingOrder.count)
        for entry in publication.readingOrder {
            if Task.isCancelled { return nil }
            if publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated {
                counts.append(1)  // FXL は本番(setup の fxl 分岐)と同じ 1 ページ
                continue
            }
            guard let url = schemeHandler.url(forContainerPath: entry.containerPath)
            else {
                counts.append(1)
                continue
            }
            let waiter = NavigationWaiter()
            webView.navigationDelegate = waiter
            webView.load(URLRequest(url: url))
            do {
                try await waiter.wait(timeout: .seconds(15))
            } catch {
                return nil
            }
            withExtendedLifetime(waiter) {}
            if Task.isCancelled { return nil }
            // 本番の runSetup と同タイミング(didFinish 直後)で測ることで、
            // フォント・画像の遅延読み込みによる誤差の出方まで揃える
            let result = try? await webView.callAsyncJavaScript(
                "return __washi.setup(\(optionsJSON));",
                arguments: [:], in: nil, contentWorld: EPUBReaderView.washiWorld)
            guard let dict = result as? [String: Any],
                  let count = dict["pageCount"] as? Int else { return nil }
            counts.append(max(1, count))
        }
        return counts
    }

    private func prepareIfNeeded(publication: EPUBPublication, contentSize: NSSize) {
        if window == nil {
            // 画面外・非表示・クリック不可(orderFront はしない。ウインドウに
            // 載っていること自体が WebKit の描画ブロック解除条件)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000),
                                    size: contentSize),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            self.window = window
        }
        if webView == nil {
            let handler = EPUBSchemeHandler(publication: publication,
                                            allowsScripts: false)
            schemeHandler = handler
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // 本の JS は不要(washi ワールドのページ割りスクリプトは
            // allowsContentJavaScript と無関係に動く)
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.setURLSchemeHandler(handler,
                                              forURLScheme: EPUBSchemeHandler.scheme)
            // メッセージハンドラは登録しない: setup() は post しない。
            // wheel/click 等の post 経路は不可視ウインドウでは発火しない
            let controller = configuration.userContentController
            controller.addUserScript(WKUserScript(
                source: ReaderScripts.pageScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: EPUBReaderView.washiWorld))
            controller.addUserScript(WKUserScript(
                source: ReaderScripts.baseCSSInjector, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: EPUBReaderView.washiWorld))
            let webView = WKWebView(frame: NSRect(origin: .zero, size: contentSize),
                                    configuration: configuration)
            window?.contentView = webView
            self.webView = webView
        }
        // 本番のリフロー時 contentFrame と同寸に保つ(innerWidth/Height 一致が
        // ページ割り一致の前提)
        window?.setContentSize(contentSize)
        webView?.frame = NSRect(origin: .zero, size: contentSize)
    }
}
