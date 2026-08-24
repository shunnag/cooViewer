import Foundation
import WebKit

/// EPUB コンテナ内リソースを WKWebView へ供給するカスタムスキームハンドラ。
/// URL 形式: washi-epub://<インスタンス ID>/<コンテナ内パス(percent-encoded)>
///
/// 設計判断(調査済みの実運用知見に基づく):
/// - 応答はすべてメインスレッドで行う(WKURLSchemeTask の要件)。展開だけ
///   バックグラウンドで行い、応答前に「まだ生きているタスクか」を必ず確認する
///   (stop 後の応答は NSInternalInconsistencyException で落ちる)
/// - MIME はマニフェスト宣言を正として明示する(スキームハンドラ応答に
///   sniffing はない。XHTML は application/xhtml+xml でないと XML パースされない)
/// - CSP ヘッダで外部読み込み・スクリプトを多層防御する(本は信頼しない)
/// - audio/video は Range 要求が来るため 206 部分応答に対応する
@MainActor
public final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "washi-epub"

    let publication: EPUBPublication
    /// この Web ビューインスタンスのホスト名(本ごとに一意 = オリジン分離)
    let instanceID: String
    /// scripted コンテンツを許可するか(CSP の script-src に反映)
    let allowsScripts: Bool

    private var liveTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(publication: EPUBPublication, allowsScripts: Bool = false) {
        self.publication = publication
        self.instanceID = UUID().uuidString.lowercased()
        self.allowsScripts = allowsScripts
    }

    /// コンテナ内パス → この本の URL
    public func url(forContainerPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = instanceID
        components.path = "/" + path
        return components.url
    }

    /// URL → コンテナ内パス(自分の本でなければ nil)
    public func containerPath(for url: URL) -> String? {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host()?.lowercased() == instanceID else { return nil }
        let path = url.path(percentEncoded: false)
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    // MARK: - WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url,
              let path = containerPath(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let publication = self.publication
        liveTasks[id] = Task { [weak self] in
            // 展開・難読化解除はバックグラウンドで(メインを塞がない)
            let payload = await Task.detached(priority: .userInitiated) {
                () -> (data: Data, mediaType: String)? in
                try? publication.resource(at: path)
            }.value
            guard let self, self.liveTasks[id] != nil else { return }  // stop 済み
            self.liveTasks[id] = nil
            guard let payload else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            self.reply(to: urlSchemeTask, url: url,
                       data: payload.data, mediaType: payload.mediaType,
                       rangeHeader: rangeHeader)
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        liveTasks[id]?.cancel()
        liveTasks[id] = nil  // 以後この task へは決して応答しない
    }

    private func reply(to task: any WKURLSchemeTask, url: URL,
                       data: Data, mediaType: String, rangeHeader: String?) {
        let scriptSource = allowsScripts ? "'self' 'unsafe-inline'" : "'none'"
        var headers: [String: String] = [
            "Cache-Control": "no-store",
            "Content-Security-Policy":
                "default-src 'self'; img-src 'self' data:; media-src 'self' data:; "
                + "style-src 'self' 'unsafe-inline'; font-src 'self' data:; "
                + "script-src \(scriptSource); connect-src 'none'; frame-src 'none'",
        ]
        var contentType = mediaType
        if EPUBMediaType.isTextual(mediaType) {
            contentType += "; charset=utf-8"
        }
        headers["Content-Type"] = contentType

        // Range 要求(audio/video のシーク)には 206 で応える
        if let rangeHeader, rangeHeader.hasPrefix("bytes="),
           let range = Self.parseRange(rangeHeader, total: data.count) {
            let slice = data.subdata(in: range)
            headers["Content-Length"] = String(slice.count)
            headers["Accept-Ranges"] = "bytes"
            headers["Content-Range"] =
                "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            guard let response = HTTPURLResponse(
                url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                headerFields: headers) else {
                task.didFailWithError(URLError(.cannotParseResponse))
                return
            }
            task.didReceive(response)
            task.didReceive(slice)
            task.didFinish()
            return
        }

        headers["Content-Length"] = String(data.count)
        headers["Accept-Ranges"] = "bytes"
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: headers) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// "bytes=a-b" / "bytes=a-" / "bytes=-suffix" の単一レンジのみ対応
    static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard total > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(",") else { return nil }  // 複数レンジは全体応答へ
        let parts = spec.split(separator: "-", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            // 末尾 suffix 形式
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            let start = max(0, total - suffix)
            return start..<total
        }
        guard let start = Int(parts[0]), start >= 0, start < total else { return nil }
        let end = parts[1].isEmpty ? (total - 1) : min(Int(parts[1]) ?? 0, total - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}
