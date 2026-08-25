import Foundation
import WebKit

/// Custom scheme handler that serves resources inside an EPUB container to a WKWebView.
/// URL form: washi-epub://<instance ID>/<container path (percent-encoded)>
///
/// Design decisions (grounded in real-world operational experience):
/// - All responses happen on the main thread (a WKURLSchemeTask requirement). Only the
///   extraction runs in the background, and before responding we always verify the task
///   is still alive (responding after a stop crashes with NSInternalInconsistencyException).
/// - The MIME type is stated explicitly from the manifest declaration (scheme-handler
///   responses do no sniffing; XHTML is only XML-parsed when served as application/xhtml+xml).
/// - The CSP header gives defense-in-depth against external loads and scripts (the book is untrusted).
/// - audio/video receive Range requests, so 206 partial responses are supported.
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

    /// Container path → this book's URL.
    public func url(forContainerPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = instanceID
        components.path = "/" + path
        return components.url
    }

    /// URL → container path (nil if it does not belong to this book).
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
