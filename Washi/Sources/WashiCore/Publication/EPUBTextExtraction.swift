import Foundation

/// A full-text search hit within a publication.
public struct EPUBSearchHit: Sendable, Equatable {
    /// Index of the spine item (reading-order position) containing the match.
    public let spineIndex: Int
    /// Character offset of the match within the item's extracted plain text.
    /// Suitable as a stable anchor for later highlighting.
    public let characterOffset: Int
    /// Length of the matched text, in characters.
    public let length: Int
    /// A short excerpt of surrounding text, with the match in the middle.
    public let snippet: String

    public init(spineIndex: Int, characterOffset: Int,
                length: Int, snippet: String) {
        self.spineIndex = spineIndex
        self.characterOffset = characterOffset
        self.length = length
        self.snippet = snippet
    }
}

extension EPUBPublication {
    /// Extracts the readable plain text of one spine item.
    ///
    /// The XHTML body is flattened to text: element boundaries that imply a
    /// break (paragraphs, headings, list items, `<br>`) become newlines,
    /// `<script>`/`<style>` content is dropped, and ruby annotation text
    /// (`<rt>`, `<rp>`) is removed so the base text reads continuously — which
    /// is also what a reader searches for. Runs of whitespace are collapsed.
    ///
    /// - Parameter index: reading-order index of the spine item.
    /// - Returns: the item's plain text, or an empty string if it has no
    ///   readable body (e.g. an image-only page).
    /// - Throws: ``EPUBError`` if the item cannot be read.
    public func extractText(forSpineIndex index: Int) throws -> String {
        guard readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        let (data, _) = try resource(at: readingOrder[index].containerPath)
        guard let document = try? WashiXML.document(from: data),
              let root = document.rootElement() else { return "" }
        let body = Self.firstDescendant("body", in: root) ?? root
        var text = ""
        Self.appendPlainText(of: body, into: &text)
        return Self.collapsingWhitespace(text)
    }

    /// A fast, WebKit-free estimate of each spine item's page count, based on
    /// extracted text length. Useful to show an approximate "~N pages" instantly
    /// before the exact offscreen census completes. Image-only pages (no body
    /// text) count as one page.
    ///
    /// - Parameter charactersPerPage: assumed characters per reflowed page.
    ///   Calibrate it from a real census (total characters ÷ measured pages) for
    ///   the current font and viewport to sharpen the estimate; the default
    ///   suits a typical body font at a comfortable reading width.
    public func estimatedPageCounts(charactersPerPage: Int = 1200) -> [Int] {
        let perPage = Double(max(1, charactersPerPage))
        return readingOrder.indices.map { index in
            let chars = (try? extractText(forSpineIndex: index))?.count ?? 0
            return max(1, Int((Double(chars) / perPage).rounded(.up)))
        }
    }

    /// A fast, WebKit-free estimate of the whole book's page count.
    /// See ``estimatedPageCounts(charactersPerPage:)``.
    public func estimatedPageCount(charactersPerPage: Int = 1200) -> Int {
        estimatedPageCounts(charactersPerPage: charactersPerPage).reduce(0, +)
    }

    /// Searches the whole publication for a substring, in reading order.
    ///
    /// Each spine item is extracted with ``extractText(forSpineIndex:)`` and
    /// scanned for `query`. Matching is case- and diacritic-insensitive and
    /// width-insensitive (full-width and half-width forms compare equal), which
    /// suits Japanese text. Returns every occurrence. Note that a few
    /// decomposed half-width forms (e.g. half-width dakuten kana `ｶﾞ`) are not
    /// folded to their full-width equivalents and may be missed.
    ///
    /// This runs on the calling context and reads/parses every item; for a
    /// large book prefer calling it off the main actor.
    ///
    /// - Parameters:
    ///   - query: the text to find. Empty or whitespace-only returns no hits.
    ///   - snippetRadius: how many characters of context to include on each
    ///     side of a match in ``EPUBSearchHit/snippet``.
    /// - Returns: hits ordered by spine index, then by offset.
    public func search(_ query: String,
                       snippetRadius: Int = 24) -> [EPUBSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        // 負の radius はスニペットの範囲(lower..<upper)を反転させてトラップ
        // するため、公開入口で非負にクランプする(0 = ヒット語のみ)
        let radius = max(0, snippetRadius)
        var hits: [EPUBSearchHit] = []
        for index in readingOrder.indices {
            guard let text = try? extractText(forSpineIndex: index),
                  !text.isEmpty else { continue }
            hits.append(contentsOf: Self.matches(
                of: needle, in: text, spineIndex: index,
                snippetRadius: radius))
        }
        return hits
    }

    // MARK: - 実装(内部コメントは日本語)

    /// 検索用の 1 文字畳み込み。半角濁点カナ(ｶﾞ 等)は 1 書記素で、
    /// widthInsensitive では全角(ガ)に畳まれず取りこぼす。全角/半角形ブロック
    /// (U+FF00–FFEF)を含む文字だけ NFKC で畳んで全角化する(1 文字に畳める
    /// ものだけ。稀な合字は 1:1 を保つためそのまま)。他の文字は素通しなので、
    /// 通常のテキストでは畳み結果=原文(既存挙動は不変)で高速
    private static func foldForSearch(_ c: Character) -> Character {
        guard c.unicodeScalars.contains(where: { (0xFF00...0xFFEF).contains($0.value) })
        else { return c }
        let n = String(c).precomposedStringWithCompatibilityMapping
        return n.count == 1 ? n.first! : c
    }

    /// query の出現位置を全て返す。比較は大小・濁点・全半角・半角濁点カナを
    /// 無視する。畳み込みは 1 文字→1 文字なので、畳み文字列上のオフセットは
    /// 元テキストのオフセットにそのまま一致する(写像不要)
    private static func matches(of needle: String, in text: String,
                                spineIndex: Int,
                                snippetRadius: Int) -> [EPUBSearchHit] {
        let chars = Array(text)
        let foldedText = String(chars.map(Self.foldForSearch))
        let foldedNeedle = String(Array(needle).map(Self.foldForSearch))
        guard !foldedNeedle.isEmpty else { return [] }
        let options: String.CompareOptions =
            [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var hits: [EPUBSearchHit] = []
        var searchStart = foldedText.startIndex
        // オフセットは前回マッチ末尾からの距離だけ足して増分計算(毎回
        // startIndex から数え直すと高頻度クエリ×長い項目で O(M·n) になる)
        var baseOffset = 0
        while let range = foldedText.range(of: foldedNeedle, options: options,
                                           range: searchStart..<foldedText.endIndex) {
            let offset = baseOffset
                + foldedText.distance(from: searchStart, to: range.lowerBound)
            let length = foldedText.distance(from: range.lowerBound,
                                             to: range.upperBound)
            // 1:1 畳み込みなので offset/length は元テキストの chars にそのまま対応
            let lower = max(0, offset - snippetRadius)
            let upper = min(chars.count, offset + length + snippetRadius)
            let snippet = String(chars[lower..<upper])
            hits.append(EPUBSearchHit(spineIndex: spineIndex,
                                      characterOffset: offset,
                                      length: length, snippet: snippet))
            // 次の探索は今回のマッチ末尾から(ゼロ幅は起きない=needle 非空)
            searchStart = range.upperBound
            baseOffset = offset + length
        }
        return hits
    }

    /// 要素配下のテキストを、改行を挿む要素境界を尊重しつつ連結する。
    /// script/style は捨て、ルビの読み(rt/rp)は本文から除く
    private static func appendPlainText(of element: XMLElement,
                                        into text: inout String) {
        let skip: Set<String> = ["script", "style", "rt", "rp"]
        let breaking: Set<String> = [
            "p", "div", "br", "li", "tr", "section", "article", "blockquote",
            "h1", "h2", "h3", "h4", "h5", "h6", "figure", "figcaption",
            "table", "ul", "ol", "dl", "dd", "dt", "hr", "pre",
        ]
        for node in element.children ?? [] {
            switch node.kind {
            case .text:
                text += node.stringValue ?? ""
            case .element:
                guard let child = node as? XMLElement,
                      let name = child.localName else { continue }
                if skip.contains(name) { continue }
                if breaking.contains(name), !text.hasSuffix("\n") {
                    text += "\n"
                }
                appendPlainText(of: child, into: &text)
                if breaking.contains(name), !text.hasSuffix("\n") {
                    text += "\n"
                }
            default:
                continue
            }
        }
    }

    /// 連続する空白を 1 つに畳み、行頭行末の空白を除く(改行は段落境界として
    /// 残すが、3 つ以上連続する改行は 2 つへ丸める)
    private static func collapsingWhitespace(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = rawLine
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            lines.append(collapsed)
        }
        // 空行の連続を 1 つへ
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty == true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
