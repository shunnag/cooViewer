import Foundation
import WebKit

/// 設計書 §2.4・§7.3: 実 WebKit を起動せず、予熱の条件と解放を検証する境界。
@MainActor
protocol EPUBWebKitWarmupResource: AnyObject {
    func start()
    func stop()
}

/// 設計書 §5・§7.3: EPUB 利用歴のあるセッションだけ、アイドル時に一度予熱する。
/// 未使用の WebView を保持し続けず、応答しない読み込みや JS も期限で切り離す。
@MainActor
final class EPUBWebKitPrewarmer {
    private let power: any PowerStateProviding
    private let pressure: any MemoryPressureProviding
    private let makeResource: @MainActor () -> any EPUBWebKitWarmupResource
    private let releaseAfter: Duration
    private var resource: (any EPUBWebKitWarmupResource)?
    private var didBegin = false
    private(set) var releaseTask: Task<Void, Never>?

    init(power: any PowerStateProviding = PowerStateMonitor.shared,
         pressure: any MemoryPressureProviding = MemoryPressureMonitor.shared,
         releaseAfter: Duration = .seconds(2),
         makeResource: @escaping @MainActor () -> any EPUBWebKitWarmupResource = {
             WebKitWarmupResource()
         }) {
        self.power = power
        self.pressure = pressure
        self.releaseAfter = releaseAfter
        self.makeResource = makeResource
    }

    func beginIfUseful(recentPaths: [String], isIdle: Bool) {
        guard !didBegin, isIdle, !Task.isCancelled,
              !power.shouldConserveEnergy, pressure.memoryPressureLevel == .normal,
              recentPaths.contains(where: { ($0 as NSString).pathExtension.lowercased() == "epub" })
        else { return }
        didBegin = true
        let resource = makeResource()
        self.resource = resource
        resource.start()
        // 設計書 §7.3: 解放は WebKit の完了通知に依存させず、無応答でも保持を終える。
        releaseTask = Task { @MainActor [weak self, releaseAfter] in
            guard (try? await Task.sleep(for: releaseAfter)) != nil else { return }
            self?.cancel()
        }
    }

    func cancel() {
        releaseTask?.cancel()
        releaseTask = nil
        resource?.stop()
        resource = nil
    }
}

/// 設計書 §2.4: 利用者の本・通信・永続ストアを使わない固定文書だけを読み込む。
@MainActor
private final class WebKitWarmupResource: NSObject, EPUBWebKitWarmupResource, WKNavigationDelegate {
    private var webView: WKWebView?
    private var scriptTask: Task<Void, Never>?

    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view
        view.navigationDelegate = self
        view.loadHTMLString("""
            <!doctype html><html><head>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'">
            </head><body></body></html>
            """, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, scriptTask == nil else { return }
        // 設計書 §2.4: 最初の JS は明示的な userInitiated で発行する。
        // 無応答の async 継続で WebView を保持しないよう、完了ハンドラ形式を使う。
        scriptTask = Task(priority: .userInitiated) { @MainActor [weak webView] in
            guard !Task.isCancelled, let webView else { return }
            WebKitWarmupResource.evaluateProbe(in: webView)
        }
    }

    private static func evaluateProbe(in webView: WKWebView) {
        webView.evaluateJavaScript("1", completionHandler: { _, _ in })
    }

    func stop() {
        scriptTask?.cancel()
        scriptTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }
}
