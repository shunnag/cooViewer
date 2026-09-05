import CoreFoundation
import Foundation

// cooViewer-oxr.12/90: XML 宣言と HTML meta の判定を解析層と表示層で共有し、
// 日本語の旧来 EPUB では Shift_JIS 系を CP932 として復号する。
package enum XMLCharsetDetector {
    private static let scanByteCount = 1024

    /// cooViewer-oxr.12: XML 宣言、meta charset、http-equiv の順に宣言名を探す。
    package static func declaredCharsetName(
        in data: Data,
        includesHTMLMeta: Bool = true
    ) -> String? {
        guard let source = String(
            data: data.prefix(scanByteCount), encoding: .isoLatin1)
        else { return nil }

        if let charset = firstCapture(
            #"(?is)<\?xml\b[^?]*?\bencoding\s*=\s*[\"']\s*([A-Za-z0-9._:-]+)\s*[\"']"#,
            in: source)
        {
            return charset
        }
        guard includesHTMLMeta else { return nil }

        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?is)<meta\b[^>]*>"#)
        else { return nil }
        let tags = expression.matches(in: source, range: range).compactMap { match in
            Range(match.range, in: source).map { String(source[$0]) }
        }

        // cooViewer-oxr.12: 直接 charset は http-equiv より優先する。
        for tag in tags {
            if let charset = attribute("charset", in: tag),
               isValidCharsetName(charset)
            {
                return charset
            }
        }
        for tag in tags {
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

    /// cooViewer-oxr.12/90: 宣言名を Foundation の復号用 encoding へ写す。
    package static func declaredEncoding(in data: Data) -> String.Encoding? {
        guard let name = declaredCharsetName(in: data) else { return nil }
        return encoding(forCharsetName: name)
    }

    /// cooViewer-oxr.90: JIS X 0208 の厳密な shiftJIS ではなく、
    /// NEC/IBM 拡張文字を含む CP932 対応の DOS Japanese を選ぶ。
    package static func encoding(forCharsetName name: String) -> String.Encoding? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "shift_jis", "shift-jis", "sjis", "ms_kanji", "ms-kanji",
             "csshiftjis", "windows-31j", "ms932", "cp932":
            let value = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
            return String.Encoding(rawValue: value)
        case "euc-jp", "euc_jp", "eucjp":
            return .japaneseEUC
        default:
            let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard value != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue:
                CFStringConvertEncodingToNSStringEncoding(value))
        }
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
}
