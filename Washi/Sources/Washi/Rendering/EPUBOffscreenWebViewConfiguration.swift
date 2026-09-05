import WebKit

/// cooViewer-oxr.88: オフスクリーン描画に使う WebView の共通構成。
@MainActor
enum EPUBOffscreenWebViewConfiguration {
    static func make(allowsScriptedContent: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript =
            allowsScriptedContent
        EPUBScriptedContentHardening.install(
            in: configuration.userContentController,
            allowsScriptedContent: allowsScriptedContent)
        // cooViewer-oxr.88: 不可視の census / thumbnail / rasterizer では、
        // 本文の autoplay が音声・動画を勝手に再生しないよう全媒体を止める。
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        return configuration
    }
}

/// cooViewer-oxr.53/62: FIFO の先行 Task 完了待ちを、呼び出し元の
/// キャンセルで直ちに打ち切るための競合状態。
@MainActor
private final class EPUBOffscreenJobJoinRace {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func finish(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// cooViewer-oxr.53/62: 非構造化 FIFO の先行ジョブを待つ間にも、現在の
/// ジョブのキャンセルへ即応する。
@MainActor
func waitForOffscreenPredecessor(_ predecessor: Task<Void, Never>?) async
    -> Bool {
    guard let predecessor else { return !Task.isCancelled }
    let race = EPUBOffscreenJobJoinRace()
    let observer = Task { @MainActor in
        await predecessor.value
        race.finish(true)
    }
    let completed = await withTaskCancellationHandler {
        await race.wait()
    } onCancel: {
        observer.cancel()
        Task { @MainActor in race.finish(false) }
    }
    observer.cancel()
    return completed && !Task.isCancelled
}
