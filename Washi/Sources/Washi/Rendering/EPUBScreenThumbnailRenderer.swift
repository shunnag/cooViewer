import AppKit
import WebKit

/// リフロー EPUB の「画面」(単ページ/見開きの 1 面)のサムネイルを、
/// 本番と同一メトリクスのページ割りで画面外に描くレンダラ。
/// census と同じオフスクリーンウインドウ方式で、共有 WKWebView を
/// FIFO 直列化して使う(EPUBPageRasterizer と同じチェーン方式 —
/// 並行呼び出しは相互のナビゲーションを潰すため直列が必須)。
/// 同じ spine 項目への連続要求は読み込みを再利用する(サムネイル一覧の
/// 要求順はほぼ逐次なので効く)。固定レイアウト項目は EPUBPageRasterizer
/// に委譲する。
@MainActor
final class EPUBScreenThumbnailRenderer {
    private let publication: EPUBPublication
    private var window: NSWindow?
    private var webView: WKWebView?
    private var schemeHandler: EPUBSchemeHandler?
    private lazy var fxlRasterizer = EPUBPageRasterizer(publication: publication)
    private var loadedSpineIndex: Int?
    private var loadedOptionsJSON: String?
    private var lastJob: Task<Void, Never>?
    /// invalidate 後は新規レンダーを受け付けない(再利用はしない前提)
    private var isInvalidated = false

    init(publication: EPUBPublication) {
        self.publication = publication
    }

    /// オフスクリーンリソースを明示的に畳み、以後の要求を無効化する。
    /// FIFO 待ちのジョブは順に nil を返して抜ける
    func invalidate() {
        isInvalidated = true
        lastJob?.cancel()
        webView?.navigationDelegate = nil
        webView = nil
        schemeHandler = nil
        window?.orderOut(nil)
        window = nil
        loadedSpineIndex = nil
        loadedOptionsJSON = nil
        fxlRasterizer.invalidate()
    }

    /// 指定画面のサムネイル。失敗時は nil(一覧側は空セルのまま先へ進める)
    func thumbnail(spineIndex: Int, pageInItem: Int, optionsJSON: String,
                   contentSize: NSSize, snapshotWidth: CGFloat) async -> CGImage? {
        guard !isInvalidated else { return nil }
        let previous = lastJob
        // 優先度は明示的に userInitiated へ引き上げる。呼び出し元はサムネイル
        // 先読み(.utility の detached タスク)で、その優先度のまま WebKit へ
        // JS 実行を発行すると応答が返らない(QoS 逆転で永久待ち。実測)。
        let job = Task(priority: .userInitiated) { () -> CGImage? in
            _ = await previous?.value  // 先行ジョブの完了を待つ(失敗しても続行)
            return await self.render(
                spineIndex: spineIndex, pageInItem: pageInItem,
                optionsJSON: optionsJSON, contentSize: contentSize,
                snapshotWidth: snapshotWidth)
        }
        lastJob = Task(priority: .userInitiated) { _ = await job.value }
        return await job.value
    }

    private func render(spineIndex: Int, pageInItem: Int, optionsJSON: String,
                        contentSize: NSSize,
                        snapshotWidth: CGFloat) async -> CGImage? {
        guard publication.readingOrder.indices.contains(spineIndex) else { return nil }
        let entry = publication.readingOrder[spineIndex]
        if publication.package.effectiveLayout(for: entry.itemRef) == .prePaginated {
            // FXL は viewport・spread 指定を解釈する専用ラスタライザで
            return try? await fxlRasterizer.renderPage(
                atSpineIndex: spineIndex, maxPixelSize: Int(snapshotWidth * 2))
        }
        guard !isInvalidated else { return nil }
        prepareIfNeeded(contentSize: contentSize)
        guard let webView, let schemeHandler else { return nil }
        if loadedSpineIndex != spineIndex || loadedOptionsJSON != optionsJSON {
            guard let url = schemeHandler.url(forContainerPath: entry.containerPath)
            else { return nil }
            loadedSpineIndex = nil  // 途中失敗時に半端な状態を再利用しない
            loadedOptionsJSON = nil
            window?.setContentSize(contentSize)
            webView.frame = NSRect(origin: .zero, size: contentSize)
            let waiter = NavigationWaiter()
            webView.navigationDelegate = waiter
            webView.load(URLRequest(url: url))
            do {
                try await waiter.wait(timeout: .seconds(15))
            } catch {
                return nil
            }
            withExtendedLifetime(waiter) {}
            // census と同じく didFinish 直後に測る(ページ数の一致が最優先。
            // 描画の確定は takeSnapshot(afterScreenUpdates: true)が担う)
            let result = try? await webView.callAsyncJavaScript(
                "return __washi.setup(\(optionsJSON));",
                arguments: [:], in: nil, contentWorld: EPUBReaderView.washiWorld)
            guard result != nil else { return nil }
            loadedSpineIndex = spineIndex
            loadedOptionsJSON = optionsJSON
        }
        // 指定画面へジャンプ(描画確定は afterScreenUpdates が担う)
        _ = try? await webView.callAsyncJavaScript(
            "__washi.showPage(\(pageInItem)); return true;",
            arguments: [:], in: nil, contentWorld: EPUBReaderView.washiWorld)
        // 画像を含むページ(表紙・挿絵)はデコード完了を待ってから撮る。
        // 新規 webview の初回スナップショットは img が未デコードのまま
        // 白紙に写ることがある(実測)。img.decode() は Promise ベースで
        // rAF/可視性に依存しないため、非表示ウインドウでも確実に完了する
        _ = try? await webView.callAsyncJavaScript(
            """
            await Promise.all(Array.from(document.images).map(
                image => image.decode().catch(() => {})));
            return true;
            """,
            arguments: [:], in: nil, contentWorld: EPUBReaderView.washiWorld)
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        configuration.snapshotWidth = NSNumber(value: Double(snapshotWidth))
        var snapshot = try? await webView.takeSnapshot(
            configuration: configuration)
        var cgImage = snapshot?.cgImage(forProposedRect: nil, context: nil,
                                        hints: nil)
        // 新規 webview の最初のナビゲーションが画像ページ(表紙等)だと、
        // DOM・デコード完了後でも画像レイヤの合成が間に合わず**無地**の
        // スナップショットになることがある(実測)。無地を検知したら
        // 少し待って撮り直す(本当に無地のページでも 2 回で諦めるだけ)
        var retries = 0
        while let current = cgImage, Self.looksBlank(current), retries < 2 {
            try? await Task.sleep(for: .milliseconds(150))
            snapshot = try? await webView.takeSnapshot(
                configuration: configuration)
            cgImage = snapshot?.cgImage(forProposedRect: nil, context: nil,
                                        hints: nil)
            retries += 1
        }
        return cgImage
    }

    /// ほぼ無地(1 色)のスナップショットか。16x16 へ縮小して各チャネルの
    /// 振れ幅を見る(初回描画の合成抜け検知用)
    private static func looksBlank(_ image: CGImage) -> Bool {
        let side = 16
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var minValue: [UInt8] = [255, 255, 255]
        var maxValue: [UInt8] = [0, 0, 0]
        for pixel in 0..<(side * side) {
            for channel in 0..<3 {
                let value = pixels[pixel * 4 + channel]
                minValue[channel] = min(minValue[channel], value)
                maxValue[channel] = max(maxValue[channel], value)
            }
        }
        return (0..<3).allSatisfy { maxValue[$0] - minValue[$0] < 8 }
    }

    private func prepareIfNeeded(contentSize: NSSize) {
        if window == nil {
            // 画面外・非表示・クリック不可(census/ラスタライザと同じ方式)
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
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.setURLSchemeHandler(handler,
                                              forURLScheme: EPUBSchemeHandler.scheme)
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
    }
}
