import Foundation

/// cooViewer-oxr.46 C42: WebKit に別名の無い `-epub-` 接頭辞 CSS を、配信時に
/// 標準プロパティで補う。
///
/// WebKit は `-epub-writing-mode` などの多くを標準プロパティの別名として解釈
/// するが、次の 6 つは解釈しない(macOS 26 / WebKit で実測)。とくに
/// `-epub-text-combine-horizontal: all` は日本語縦書きの縦中横そのもので、
/// 電書協テンプレート系の本で広く使われている。
///
/// 元の宣言は残したまま標準プロパティの宣言を後ろへ足すだけなので、WebKit が
/// 将来 `-epub-` を解釈するようになっても結果は変わらない(同じ値になる)。
public enum EPUBPrefixedCSS {
    /// 補う対象(`-epub-` 名 → 標準名)。WebKit が解釈するものは入れない。
    static let unsupported: [(prefixed: String, standard: String)] = [
        ("-epub-text-combine-horizontal", "text-combine-upright"),
        ("-epub-line-break", "line-break"),
        ("-epub-text-align-last", "text-align-last"),
        ("-epub-text-emphasis-position", "text-emphasis-position"),
        ("-epub-text-underline-position", "text-underline-position"),
        ("-epub-ruby-position", "ruby-position"),
    ]

    /// スタイルシート本文に標準プロパティの宣言を補う。
    /// 値の切れ目は `;` と宣言ブロックの終わり `}` の手前まで。
    public static func polyfilled(_ css: String) -> String {
        var result = css
        for (prefixed, standard) in unsupported {
            guard result.contains(prefixed) else { continue }
            result = expand(result, prefixed: prefixed, standard: standard)
        }
        return result
    }

    /// テキスト種別が CSS のときだけ通す入口。
    public static func polyfilledStylesheet(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("-epub-") else { return data }
        let converted = polyfilled(text)
        return converted == text ? data : Data(converted.utf8)
    }

    private static func expand(_ css: String, prefixed: String,
                               standard: String) -> String {
        var out = ""
        out.reserveCapacity(css.count + 64)
        var index = css.startIndex
        while let range = css.range(of: prefixed, range: index..<css.endIndex) {
            // 名前の一部(`-epub-line-breakish` 等)への誤爆を避ける
            let after = range.upperBound
            let beforeOK = range.lowerBound == css.startIndex
                || !isNameCharacter(css[css.index(before: range.lowerBound)])
            guard beforeOK, after < css.endIndex else {
                out += css[index..<after]
                index = after
                continue
            }
            var cursor = after
            while cursor < css.endIndex, css[cursor] == " " { cursor = css.index(after: cursor) }
            guard css[cursor] == ":" else {
                out += css[index..<after]
                index = after
                continue
            }
            let valueStart = css.index(after: cursor)
            var valueEnd = valueStart
            while valueEnd < css.endIndex, css[valueEnd] != ";", css[valueEnd] != "}" {
                valueEnd = css.index(after: valueEnd)
            }
            let value = css[valueStart..<valueEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out += css[index..<valueEnd]
            if !value.isEmpty {
                out += "; \(standard): \(value)"
            }
            index = valueEnd
        }
        out += css[index...]
        return out
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
}
