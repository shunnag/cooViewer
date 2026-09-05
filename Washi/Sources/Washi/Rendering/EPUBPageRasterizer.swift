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
    private let allowsScriptedContent: Bool
    private var window: NSWindow?
    private var webView: WKWebView?
    private var pendingNavigationWaiter: NavigationWaiter?
    /// cooViewer-oxr.68: 所有するサムネイルレンダラのアイドル診断用。
    var hasLiveWebView: Bool { webView != nil }
    /// 直列化: 直前の要求が終わるまで次を待たせる
    private var lastJob: Task<Void, Never>?
    private var renderJobs: [UUID: Task<CGImage, any Error>] = [:]

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

    /// Creates a rasterizer with author scripts disabled.
    public init(publication: EPUBPublication) {
        self.publication = publication
        self.allowsScriptedContent = false
        self.schemeHandler = EPUBSchemeHandler(
            publication: publication, allowsScripts: false)
    }

    /// Creates a rasterizer and chooses whether author scripts may run in the
    /// offscreen page.
    public init(publication: EPUBPublication, allowsScriptedContent: Bool) {
        self.publication = publication
        self.allowsScriptedContent = allowsScriptedContent
        self.schemeHandler = EPUBSchemeHandler(
            publication: publication, allowsScripts: allowsScriptedContent)
    }

    /// invalidate 後は新規レンダーを受け付けない
    private var isInvalidated = false

    /// Explicitly tears down the offscreen resources (the invisible NSWindow and
    /// the WebContent process). Call it once you are done (any later renderPage
    /// then fails with loadFailed).
    public func invalidate() {
        isInvalidated = true
        lastJob?.cancel()
        for job in renderJobs.values { job.cancel() }
        renderJobs.removeAll()
        // cooViewer-oxr.53: delegate を外す前に現在の待機を解決し、
        // 30 秒タイムアウトを待たず FIFO を終了させる。
        pendingNavigationWaiter?.cancel()
        pendingNavigationWaiter = nil
        webView?.stopLoading()
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
        try await enqueueRender(
            atSpineIndex: index, maxPixelSize: maxPixelSize,
            deviceViewportSize: nil)
    }

    /// Renders a page whose viewport may use `device-width` or
    /// `device-height`, using `deviceViewportSize` as that device viewport.
    /// For ordinary numeric viewports the publication's declared dimensions
    /// remain authoritative.
    public func renderPage(
        atSpineIndex index: Int,
        deviceViewportSize: CGSize,
        maxPixelSize: Int? = nil
    ) async throws -> CGImage {
        try await enqueueRender(
            atSpineIndex: index, maxPixelSize: maxPixelSize,
            deviceViewportSize: deviceViewportSize)
    }

    private func enqueueRender(
        atSpineIndex index: Int, maxPixelSize: Int?,
        deviceViewportSize: CGSize?
    ) async throws -> CGImage {
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        let previous = lastJob
        // 優先度は明示的に userInitiated へ(低優先度の呼び出し元 — 例:
        // .utility のサムネイル先読み — の QoS を継ぐと、WebKit への JS 実行が
        // 応答しないことがある。EPUBScreenThumbnailRenderer で実測した逆転)
        let job = Task(priority: .userInitiated) { () throws -> CGImage in
            guard await waitForOffscreenPredecessor(previous) else {
                throw CancellationError()
            }
            return try await self.performRender(atSpineIndex: index,
                                                maxPixelSize: maxPixelSize,
                                                deviceViewportSize: deviceViewportSize)
        }
        let jobID = UUID()
        renderJobs[jobID] = job
        defer { renderJobs[jobID] = nil }
        // cooViewer-oxr.53: キャンセルされた待機ジョブが先行ジョブより先に
        // 終了しても、次の要求が先行描画を追い越さない FIFO barrier を残す。
        lastJob = Task(priority: .userInitiated) {
            _ = await previous?.value
            _ = try? await job.value
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            // cooViewer-oxr.53: 非構造化 FIFO ジョブへ呼び出し元の
            // キャンセルを明示的に伝播する。
            job.cancel()
        }
    }

    private func performRender(atSpineIndex index: Int,
                               maxPixelSize: Int?,
                               deviceViewportSize: CGSize?) async throws -> CGImage {
        // FIFO 待ちの間に invalidate された場合、ここでオフスクリーンを
        // 作り直さない(畳んだはずのウインドウ/プロセスを復活させない)
        try Task.checkCancellation()
        guard !isInvalidated else { throw RasterizeError.loadFailed }
        guard publication.readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        let info = try publication.fixedLayoutInfo(forSpineIndex: index)
        // cooViewer-oxr.50: device-* viewport は固定の 3:4 fallback ではなく、
        // 呼び出し元が要求した描画先の縦横比を ICB として使う。
        let rawViewport = info.viewportIsDeviceSized
            ? (deviceViewportSize ?? CGSize(width: 1200, height: 1600))
            : (info.viewportSize ?? CGSize(width: 1200, height: 1600))
        // 悪意ある FXL は viewport(または SVG viewBox)に巨大値を宣言でき、
        // zoom 下限(0.05)ではフレームを十分に縮められず、巨大なオフスクリーン
        // スナップショット確保でプロセスが落ちる。実在の FXL ページ寸法を
        // 十分に覆う上限へ寸法自体をクランプする(NaN/0/負値も弾く)
        let maxDimension: CGFloat = 5000
        func sane(_ v: CGFloat, fallback: CGFloat) -> CGFloat {
            v.isFinite && v >= 1 ? min(v, maxDimension) : fallback
        }
        let viewport = CGSize(width: sane(rawViewport.width, fallback: 1200),
                              height: sane(rawViewport.height, fallback: 1600))

        // 目標ピクセルに合わせて pageZoom で拡縮(backing scale 込み)
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let longSide = max(viewport.width, viewport.height)
        let targetLongSidePixels = maxPixelSize.map { max(1, CGFloat($0)) }
            ?? longSide * 2  // 既定は 2x(Retina 実寸)
        let zoom = max(0.05, min(4, targetLongSidePixels / (longSide * backingScale)))
        let frameSize = NSSize(width: viewport.width * zoom,
                               height: viewport.height * zoom)

        let webView = prepareWebView(size: frameSize)
        webView.pageZoom = zoom

        let entry = publication.readingOrder[index]
        guard let url = schemeHandler.url(
            forContainerPath: entry.resolvedContainerPath) else {
            throw EPUBError.resourceNotFound(entry.resolvedContainerPath)
        }
        try await loadAndWait(webView: webView, url: url)
        try Task.checkCancellation()

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: frameSize)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        try Task.checkCancellation()
        guard !isInvalidated else { throw RasterizeError.loadFailed }
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
            let configuration = EPUBOffscreenWebViewConfiguration.make(
                allowsScriptedContent: allowsScriptedContent)
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
        pendingNavigationWaiter = delegate
        webView.navigationDelegate = delegate
        webView.load(URLRequest(url: url))
        // オフスクリーンの WebContent プロセスはジェットサム候補のため、
        // 落ちた/固まったときに永久待ちしないようタイムアウト付きで待つ
        do {
            try await delegate.wait(timeout: .seconds(30))
        } catch {
            if pendingNavigationWaiter === delegate {
                pendingNavigationWaiter = nil
            }
            webView.navigationDelegate = nil
            if error is CancellationError || Task.isCancelled {
                webView.stopLoading()
            }
            throw error
        }
        if pendingNavigationWaiter === delegate {
            pendingNavigationWaiter = nil
        }
        webView.navigationDelegate = nil
        // didFinish 直後はフォント・画像のデコードが残っていることがある。
        // cooViewer-oxr.2: 一度も表示しないウインドウでは rAF が発火しないため
        // 待ってはいけない。フォントと画像デコードを有界に待ち、描画の確定は
        // takeSnapshot(afterScreenUpdates: true)に任せる
        await waitForPostLoadReadiness(webView: webView)
        try Task.checkCancellation()
        withExtendedLifetime(delegate) {}
    }

    private func waitForPostLoadReadiness(webView: WKWebView) async {
        let race = PostLoadReadinessRace()
        // 優先度は renderPage と同じ userInitiated を明示する。低 QoS の
        // WebKit JS 呼び出しが応答しない問題をここで再導入しない
        let scriptTask = Task(priority: .userInitiated) { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                """
                const work = (async () => {
                    await document.fonts.ready;
                    await Promise.all([...document.images].map(
                        image => image.decode().catch(() => {})));
                    return true;
                })();
                return await Promise.race([
                    work,
                    new Promise(resolve => setTimeout(() => resolve(false), 1500))
                ]);
                """,
                arguments: [:], in: nil, contentWorld: .defaultClient)
            race.finish()
        }
        // cooViewer-oxr.2: JS 側のタイマごと WebKit が応答しない場合も、
        // FIFO の後続ジョブを塞がないよう Swift 側で待機を打ち切る
        let timeoutTask = Task(priority: .userInitiated) { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            race.finish()
        }
        await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            scriptTask.cancel()
            timeoutTask.cancel()
            Task { @MainActor in race.finish() }
        }
        scriptTask.cancel()
        timeoutTask.cancel()
    }
}

/// WebKit の応答と Swift 側タイムアウトのうち先に終わった方だけを採用する。
/// 非構造化 Task を使い、応答しない WebKit 子タスクの終了を待たずに戻す
@MainActor
private final class PostLoadReadinessRace {
    private var isFinished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isFinished else { return }
        await withCheckedContinuation { continuation in
            if isFinished {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        continuation?.resume()
        continuation = nil
    }
}

/// didFinish / didFail を async で待つための一時デリゲート。
/// WebContent プロセスの死亡・タイムアウトでも必ず 1 回だけ resume する
/// (ラスタライザと全文ページ census で共用)
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?
    /// continuation を設置する前にキャンセルが着弾したときのフラグ(直列
    /// MainActor 上で install が先に走るので通常は不要だが、多重防御)
    private var cancelledBeforeInstall = false

    enum WaitError: Error {
        case timeout
        case contentProcessTerminated
    }

    /// 待機。キャンセルに即応する(タスクを cancel すると 15/30 秒のタイムアウト
    /// 満了を待たず CancellationError で抜ける — census の invalidate 直後に
    /// オフスクリーンが最大 15 秒生き残る/次の census が FIFO で連鎖待ちに
    /// なるのを防ぐ)。タイマは解決時に必ず回収する
    func wait(timeout: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledBeforeInstall {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resume(throwing: WaitError.timeout)
                }
            }
        } onCancel: {
            // onCancel は @Sendable・非分離 → MainActor へホップして解決する
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    /// cooViewer-oxr.53: 所有者の invalidate から、continuation の設置前後を
    /// 問わず待機を即座にキャンセルする。
    func cancel() {
        cancelledBeforeInstall = true
        resume(throwing: CancellationError())
    }

    private func resume(throwing error: (any Error)? = nil) {
        timeoutTask?.cancel()  // タイムアウトタイマを回収(15/30 秒生き残らせない)
        timeoutTask = nil
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
