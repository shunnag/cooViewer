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

    /// 直近に Range 要求で展開したリソース(1件)。audio/video のシークは同じ
    /// ファイルへ Range 要求を繰り返すが、各要求ごとに publication.resource(at:) が
    /// エントリ全体を再 inflate + CRC していた(cooViewer-ebm)。展開結果を1件だけ
    /// 保持し、同一パスの後続 Range は再展開せず slice して返す。非 Range
    /// (XHTML/画像)は再要求されないので載せず、メディアと thrash させない。
    /// @MainActor なのでロック不要
    var cachedRangeResource: (path: String, data: Data, mediaType: String)?

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
            // 直近 Range リソースの命中(メディアのシーク連打)は再展開せず即応答
            if let self, let cached = self.cachedRangeResource, cached.path == path {
                guard self.liveTasks[id] != nil else { return }  // stop 済み
                self.liveTasks[id] = nil
                self.reply(to: urlSchemeTask, url: url, data: cached.data,
                           mediaType: cached.mediaType, rangeHeader: rangeHeader)
                return
            }
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
            // Range 要求(メディアのシーク)は同一ファイルへ繰り返し来るので、
            // 展開結果を1件だけ保持する(cooViewer-ebm)。非 Range は載せない
            if rangeHeader != nil {
                self.cachedRangeResource = (path, payload.data, payload.mediaType)
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

    static func contentType(for mediaType: String, data: Data) -> String {
        guard EPUBMediaType.isTextual(mediaType),
              let charset = declaredCharset(in: data, mediaType: mediaType)
        else { return mediaType }
        return "\(mediaType); charset=\(charset)"
    }

    /// 文書先頭の ASCII 互換な宣言部分だけを読み、本文そのものを先に
    /// 誤った文字コードで復号しないようにする
    private static func declaredCharset(in data: Data, mediaType: String) -> String? {
        let prefix = data.prefix(8192)
        guard let source = String(data: prefix, encoding: .isoLatin1) else {
            return nil
        }
        let type = mediaType.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isXML = type == "application/xml" || type.hasSuffix("+xml")
        if isXML,
           let charset = firstCapture(
            #"(?i)<\?xml\s+[^?]*?\bencoding\s*=\s*[\"']\s*([A-Za-z0-9._:-]+)\s*[\"']"#,
            in: source) {
            return charset
        }

        guard type == "text/html" || type == EPUBMediaType.xhtml else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<meta\b[^>]*>"#) else { return nil }
        for match in expression.matches(in: source, range: range) {
            guard let tagRange = Range(match.range, in: source) else { continue }
            let tag = String(source[tagRange])
            if let charset = attribute("charset", in: tag),
               isValidCharsetName(charset) {
                return charset
            }
            guard attribute("http-equiv", in: tag)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Content-Type") == .orderedSame,
                  let content = attribute("content", in: tag),
                  let charset = firstCapture(
                    #"(?i)\bcharset\s*=\s*[\"']?\s*([A-Za-z0-9._:-]+)"#,
                    in: content)
            else { continue }
            return charset
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in source: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: source,
                range: NSRange(source.startIndex..<source.endIndex, in: source)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[range])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?is)(?:^|\s)"# + escaped
            + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: tag,
                range: NSRange(tag.startIndex..<tag.endIndex, in: tag))
        else { return nil }
        for index in 1..<match.numberOfRanges
        where match.range(at: index).location != NSNotFound {
            guard let range = Range(match.range(at: index), in: tag) else { continue }
            return String(tag[range])
        }
        return nil
    }

    private static func isValidCharsetName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9._:-]+$"#,
                   options: .regularExpression) != nil
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
        headers["Content-Type"] = Self.contentType(for: mediaType, data: data)

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
