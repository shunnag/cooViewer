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
    private static let imageWrapperQueryName = "washi-wrap"

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

    /// URL for loading a reading-order entry in WebKit. Raster image spine
    /// items are represented by a generated XHTML document so the reflowable
    /// reader can apply its normal single-image-page layout.
    func url(forReadingOrderItem entry: ReadingOrderItem) -> URL? {
        guard var components = url(forContainerPath: entry.resolvedContainerPath)
            .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        else { return nil }
        guard Self.isImageMediaType(entry.resolvedItem.mediaType) else {
            return components.url
        }
        // cooViewer-oxr.15: 生画像を main resource として読む代わりに、
        // ReaderScripts の既存 image-page CSS 経路へ載せる予約 URL を発行する。
        components.queryItems = [URLQueryItem(
            name: Self.imageWrapperQueryName, value: "1")]
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
            if Self.isImageWrapperURL(url),
               let entry = publication.readingOrder.first(where: {
                   $0.resolvedContainerPath == path
                       && Self.isImageMediaType($0.resolvedItem.mediaType)
               }),
               let resourceURL = self?.url(forContainerPath: path),
               let wrapper = Self.imageWrapperData(
                   imageURL: resourceURL, title: entry.resolvedItem.id)
            {
                guard let self, self.liveTasks[id] != nil else { return }
                self.liveTasks[id] = nil
                self.reply(to: urlSchemeTask, url: url, data: wrapper,
                           mediaType: EPUBMediaType.xhtml, rangeHeader: nil)
                return
            }
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
        guard EPUBMediaType.isTextual(mediaType) else { return mediaType }
        let type = mediaType.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let isXML = type == "application/xml" || type.hasSuffix("+xml")
        if isXML, let charset = XMLCharsetDetector.declaredCharsetName(
            in: data, includesHTMLMeta: false)
        {
            return "\(mediaType); charset=\(charset)"
        }

        guard type == "text/html" || type == EPUBMediaType.xhtml,
              let charset = XMLCharsetDetector.declaredCharsetName(in: data)
        else { return mediaType }
        // cooViewer-oxr.12: UTF-8 として正しい本文では古い meta 宣言を採用せず、
        // WebKit が誤った Shift_JIS 等で再解釈しないよう明示的に UTF-8 を返す。
        if String(data: data, encoding: .utf8) != nil {
            return "\(mediaType); charset=utf-8"
        }
        return "\(mediaType); charset=\(charset)"
    }

    static func isImageWrapperURL(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == imageWrapperQueryName && $0.value == "1" }
            ?? false
    }

    private static func isImageMediaType(_ value: String) -> Bool {
        value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("image/") == true
    }

    static func imageWrapperData(imageURL: URL, title: String) -> Data? {
        func escaped(_ source: String) -> String {
            source
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        // cooViewer-oxr.15: body を画像 1 枚だけに保ち、既存の image-page
        // 判定と中央寄せ CSS をそのまま再利用する。
        let document = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>\(escaped(title))</title></head>
              <body><img src="\(escaped(imageURL.absoluteString))" alt=""/></body>
            </html>
            """
        return document.data(using: .utf8)
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
        let end: Int
        if parts[1].isEmpty {
            end = total - 1
        } else {
            // RFC 7233 の byte-range-spec は数値の終端を必須とする。
            // 不正値を 0 とみなさず Range 自体を無視する。
            guard let parsedEnd = Int(parts[1]), parsedEnd >= 0 else { return nil }
            end = min(parsedEnd, total - 1)
        }
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}
