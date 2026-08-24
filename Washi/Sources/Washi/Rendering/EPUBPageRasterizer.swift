import AppKit
import WebKit

/// Offscreen rasterizer for fixed-layout pages.
/// A WKWebView stops rendering while it is outside a window, so we place it in
/// an offscreen borderless window (never shown) and take a snapshot from there
/// (the only approach proven to work on macOS). Loads are serialized one page
/// at a time.
///
/// Note: for a "single image only" page, decoding the image directly from
/// EPUBPublication.fixedLayoutInfo's simpleImagePath is faster and higher
/// quality. This class is the fallback for complex FXL pages that composite
/// text and SVG.
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

    /// Explicitly tears down the offscreen resources (the invisible NSWindow and
    /// the WebContent process). Call it once you are done (any later renderPage
    /// then fails with loadFailed).
    public func invalidate() {
        isInvalidated = true
        lastJob?.cancel()
        webView?.navigationDelegate = nil
        webView = nil
        window?.orderOut(nil)
        window = nil
    }

    /// Renders and returns a spine item. maxPixelSize caps the long edge (nil = 2x
    /// native size). Because a single shared WKWebView is used, calls are fully
    /// serialized FIFO: the render body runs **inside** the chained Task (moving
    /// it outside breaks serialization, so concurrent calls clobber each other's
    /// navigations and NavigationWaiter waits forever).
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
