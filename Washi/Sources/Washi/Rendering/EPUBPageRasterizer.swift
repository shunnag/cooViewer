import AppKit
import WebKit

/// 固定レイアウトページのオフスクリーンラスタライザ。
/// WKWebView はウインドウ外では描画が止まるため、画面外に置いた
/// borderless ウインドウ(表示はしない)に載せてスナップショットを撮る
/// (macOS で実績のある唯一の方法)。読み込みは 1 ページずつ直列化する。
///
/// 注意: 「1 枚画像だけのページ」は EPUBPublication.fixedLayoutInfo の
/// simpleImagePath から画像を直接デコードする方が速く高品質。本クラスは
/// 複雑な FXL ページ(テキスト・SVG 合成)のフォールバック
@MainActor
public final class EPUBPageRasterizer {
    private let publication: EPUBPublication
    private let schemeHandler: EPUBSchemeHandler
    private var window: NSWindow?
    private var webView: WKWebView?
    /// 直列化: 直前の要求が終わるまで次を待たせる
    private var lastJob: Task<Void, Never>?

    /// An error raised while rasterizing a fixed-layout page.
    public enum RasterizeError: Error, Sendable, Equatable, LocalizedError {
        /// The page's document could not be loaded (or the rasterizer was
        /// invalidated before it loaded).
        case loadFailed
        /// The offscreen web view produced no snapshot image.
        case snapshotFailed

        public var errorDescription: String? {
            switch self {
            case .loadFailed: return "The page could not be loaded for rendering."
            case .snapshotFailed: return "The page could not be captured as an image."
            }
        }
    }

    public init(publication: EPUBPublication) {
        self.publication = publication
        self.schemeHandler = EPUBSchemeHandler(publication: publication)
    }

    /// invalidate 後は新規レンダーを受け付けない
    private var isInvalidated = false

    /// オフスクリーンリソース(不可視 NSWindow + WebContent プロセス)を
    /// 明示的に畳む。使い終えたら呼ぶ(以後の renderPage は loadFailed)
    public func invalidate() {
        isInvalidated = true
        lastJob?.cancel()
        webView?.navigationDelegate = nil
        webView = nil
        window?.orderOut(nil)
        window = nil
    }

    /// spine 項目を描画して返す。maxPixelSize は長辺の上限(nil で等倍 2x)。
    /// 共有 WKWebView を使うため FIFO で完全直列化する: 描画本体をチェーン
    /// された Task の**中**で実行する(外に出すと直列化にならず、並行呼び出しが
    /// 相互のナビゲーションを潰して NavigationWaiter が永久に待つ)
    public func renderPage(atSpineIndex index: Int,
                           maxPixelSize: Int? = nil) async throws -> CGImage {
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        let previous = lastJob
        // 優先度は明示的に userInitiated へ(低優先度の呼び出し元 — 例:
        // .utility のサムネイル先読み — の QoS を継ぐと、WebKit への JS 実行が
        // 応答しないことがある。EPUBScreenThumbnailRenderer で実測した逆転)
        let job = Task(priority: .userInitiated) { () throws -> CGImage in
            _ = await previous?.value  // 先行ジョブの完了を待つ(失敗しても続行)
            return try await self.performRender(atSpineIndex: index,
                                                maxPixelSize: maxPixelSize)
        }
        // 次のジョブが待つのは「描画本体まで含めた完了」
        lastJob = Task(priority: .userInitiated) { _ = try? await job.value }
        return try await job.value
    }

    private func performRender(atSpineIndex index: Int,
                               maxPixelSize: Int?) async throws -> CGImage {
        // FIFO 待ちの間に invalidate された場合、ここでオフスクリーンを
        // 作り直さない(畳んだはずのウインドウ/プロセスを復活させない)
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        guard publication.readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        let info = try publication.fixedLayoutInfo(forSpineIndex: index)
        let viewport = info.viewportSize ?? CGSize(width: 1200, height: 1600)

        // 目標ピクセルに合わせて pageZoom で拡縮(backing scale 込み)
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let longSide = max(viewport.width, viewport.height)
        let targetLongSidePixels = maxPixelSize.map(CGFloat.init)
            ?? longSide * 2  // 既定は 2x(Retina 実寸)
        let zoom = max(0.05, min(4, targetLongSidePixels / (longSide * backingScale)))
        let frameSize = NSSize(width: viewport.width * zoom,
                               height: viewport.height * zoom)

        let webView = prepareWebView(size: frameSize)
        webView.pageZoom = zoom

        let entry = publication.readingOrder[index]
        guard let url = schemeHandler.url(forContainerPath: entry.containerPath) else {
            throw EPUBError.resourceNotFound(entry.containerPath)
        }
        try await loadAndWait(webView: webView, url: url)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: frameSize)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil,
                                          hints: nil) else {
            throw RasterizeError.snapshotFailed
        }
        return cgImage
    }

    private func prepareWebView(size: NSSize) -> WKWebView {
        if window == nil {
            // 画面外・非表示・クリックされないウインドウ(orderFront はしない。
            // ウインドウに載っていること自体が描画のブロック解除条件)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            self.window = window
        }
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.setURLSchemeHandler(schemeHandler,
                                              forURLScheme: EPUBSchemeHandler.scheme)
            let webView = WKWebView(frame: NSRect(origin: .zero, size: size),
                                    configuration: configuration)
            window?.contentView = webView
            self.webView = webView
        }
        window?.setContentSize(size)
        webView?.frame = NSRect(origin: .zero, size: size)
        return webView!
    }

    private func loadAndWait(webView: WKWebView, url: URL) async throws {
        let delegate = NavigationWaiter()
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: url))
        // オフスクリーンの WebContent プロセスはジェットサム候補のため、
        // 落ちた/固まったときに永久待ちしないようタイムアウト付きで待つ
        try await delegate.wait(timeout: .seconds(30))
        // didFinish 直後はフォント・画像のデコードが残っていることがある。
        // readyState + フォント読了 + 1 フレームを待ってから撮る
        _ = try? await webView.callAsyncJavaScript(
            """
            await document.fonts.ready;
            await new Promise(resolve => requestAnimationFrame(resolve));
            return true;
            """,
            arguments: [:], in: nil, contentWorld: .defaultClient)
        withExtendedLifetime(delegate) {}
    }
}

/// didFinish / didFail を async で待つための一時デリゲート。
/// WebContent プロセスの死亡・タイムアウトでも必ず 1 回だけ resume する
/// (ラスタライザと全文ページ census で共用)
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    enum WaitError: Error {
        case timeout
        case contentProcessTerminated
    }

    func wait(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(throwing: WaitError.timeout)
            }
        }
    }

    private func resume(throwing error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async
        -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // オフスクリーンの計測/ラスタライズはコンテナ内(washi-epub)以外へ
        // 遷移しない。meta refresh 等による外部接続を本番ビューと同様に遮断する
        // (本番の decidePolicyFor と同じ方針。本の中身は信頼しない)
        let allowed = navigationAction.request.url?.scheme?.lowercased()
            == EPUBSchemeHandler.scheme
        return (allowed ? .allow : .cancel, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: any Error) {
        resume(throwing: error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        resume(throwing: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resume(throwing: WaitError.contentProcessTerminated)
    }
}
