import Foundation

/// EPUB 関連 XML の名前空間 URI
enum XMLNamespace {
    static let container = "urn:oasis:names:tc:opendocument:xmlns:container"
    static let opf = "http://www.idpf.org/2007/opf"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let xhtml = "http://www.w3.org/1999/xhtml"
    static let epubOps = "http://www.idpf.org/2007/ops"
    static let ncx = "http://www.daisy.org/z3986/2005/ncx/"
    static let xmlEnc = "http://www.w3.org/2001/04/xmlenc#"
    static let xmlDSig = "http://www.w3.org/2000/09/xmldsig#"
    static let smil = "http://www.w3.org/ns/SMIL"
    static let svg = "http://www.w3.org/2000/svg"
    static let mathML = "http://www.w3.org/1998/Math/MathML"
    static let xlink = "http://www.w3.org/1999/xlink"
}

/// XMLDocument ベースのパースヘルパ。
/// EPUB の XML は well-formed が仕様要件だが、実在ファイルには DTD 未定義の
/// HTML 名前実体(&nbsp; 等)が混ざることがあるため、素のパースに失敗したら
/// 既知実体を数値参照へ置換して再試行する(WebKit 側の描画には影響しない、
/// Washi 自身がナビゲーション文書等を読むときだけの救済)。
enum WashiXML {
    /// 外部実体は決して読み込まない(EPUB RS 3.3 §3.6 の要件 + XXE 対策)
    private static let options: XMLNode.Options = [
        .nodePreserveWhitespace, .nodeLoadExternalEntitiesNever,
    ]

    static func document(from data: Data) throws -> XMLDocument {
        try validateProlog(data)   // ← 生データ先行の現順序は維持(変更禁止)
        // 外部 DTD 参照付き DOCTYPE の XHTML では .nodeLoadExternalEntitiesNever の
        // 下で名前付き実体(&nbsp; 等)が空展開され、素パースが成功して catch の
        // 救済に入らない。既知実体を含むなら先に数値参照へ畳んでから解析し、
        // WebKit の DOM 本文と抽出テキストを一致させる(cooViewer-aj4)。
        // ※ CDATA/コメント内の見かけ実体も置換されるが、従来の catch 経路と同じ
        //   既知の制限(実在 EPUB では稀)。
        let source = containsNamedEntity(data) ? sanitizeEntities(data) : data
        let document: XMLDocument
        do {
            document = try XMLDocument(data: source, options: options)
        } catch {
            // 前処理で拾えない実体・別の整形不良は従来どおり sanitize で再挑戦
            document = try XMLDocument(data: sanitizeEntities(data), options: options)
        }
        try validateDepth(document)
        return document
    }

    // MARK: - 攻撃的 XML の遮断

    /// 要素ネストの上限。実在 EPUB の XML(OPF/nav/NCX/SMIL 等)は深くても
    /// 数十段。これを大きく超える木は、下流の再帰ウォーカー
    /// (nav の入れ子リスト・NCX navPoint・SMIL seq 等)をスタック
    /// オーバーフロー(SIGSEGV)させる攻撃とみなして拒否する
    private static let maxElementDepth = 512

    private static func validateDepth(_ document: XMLDocument) throws {
        guard let root = document.rootElement() else { return }
        var stack: [(node: XMLNode, depth: Int)] = [(root, 1)]
        while let (node, depth) = stack.popLast() {
            guard depth <= maxElementDepth else {
                throw EPUBError.malformed("XML のネストが深すぎる(\(maxElementDepth) 超)")
            }
            for child in node.children ?? [] {
                stack.append((child, depth + 1))
            }
        }
    }

    /// 内部 DTD の実体宣言を検査する。.nodeLoadExternalEntitiesNever は
    /// **外部**実体しか遮断せず、内部サブセットの実体展開(billion laughs)は
    /// 素通しでメモリ枯渇に至る。一方、実在の EPUB 2 系ファイルには
    /// `<!ENTITY nbsp "&#160;">` 程度の互換シムが紛れるため、全面禁止は
    /// せず「少数・短値・入れ子なし」の宣言だけを許す
    private static func validateProlog(_ rawData: Data) throws {
        // cooViewer-oxr.85: EPUB が許すのは UTF-8/UTF-16。UTF-32 は ASCII
        // バイト検査を迂回して libxml2 に巨大な内部実体を展開させるため、
        // BOM・先頭バイト列・XML 宣言のいずれで判明しても解析前に拒否する。
        guard !isUTF32XML(rawData) else {
            throw EPUBError.malformed("UTF-32 XML is not supported")
        }
        // libxml2 が見るのと同じ文字列で検査する。UTF-16(BOM または
        // 交互の 0x00)は UTF-8 相当へ正規化する — さもないと ASCII バイト
        // リテラルを見るスキャナが DOCTYPE を素通しし、UTF-16 で書かれた
        // 実体爆弾がガードを丸ごと迂回する
        let data = normalizedXMLBytes(rawData)
        guard let doctype = try internalDoctypeSlice(data),
              doctype.firstRange(of: Data("<!ENTITY".utf8)) != nil else { return }
        guard let rawText = String(data: doctype, encoding: .utf8) else {
            // 内部 DTD に非 UTF-8 のバイトを含む(実体値の日本語等)。
            // ENTITY 宣言があるのに検査できないので安全側で拒否する
            // (実在 EPUB の XML はほぼ UTF-8/UTF-16)
            throw EPUBError.malformed("DTD の文字コードを判定できない")
        }
        // 内部サブセットのコメント・処理命令を除去してから宣言を数える。
        // コメントアウトされた `<!ENTITY>` を宣言と誤認して正当な XML を
        // 拒否しないため(かつ PI 内に隠した宣言も無効化される)
        let text = strippingCommentsAndPIs(rawText)
        guard text.contains("<!ENTITY") else { return }
        // 宣言の形は「名前 + 引用値」のみ許可(SYSTEM/PUBLIC/NDATA/
        // パラメータ実体 % は不許可 — 外部実体は読まないので宣言ごと拒否)
        var count = 0
        var searchFrom = text.startIndex
        while let range = text.range(of: "<!ENTITY", range: searchFrom..<text.endIndex) {
            searchFrom = range.upperBound
            count += 1
            guard count <= 64 else {
                throw EPUBError.malformed("内部 DTD の実体宣言が多すぎる")
            }
            let declaration = text[range.lowerBound...]
            guard let match = declaration.prefixMatch(
                of: /<!ENTITY\s+([^\s%>]+)\s+(?:"([^"]*)"|'([^']*)')\s*>/),
                  isSafeEntityValue(String(match.2 ?? match.3 ?? "")) else {
                throw EPUBError.malformed("内部 DTD に危険な実体宣言がある")
            }
        }
    }

    private static func isUTF32XML(_ data: Data) -> Bool {
        let head = Array(data.prefix(4))
        if head.count == 4 {
            // 通常の UTF-32 BOM、XML 1.0 が定義する BOM なしの先頭 '<'、
            // および稀な UCS-4 2143/3412 バイト順をすべて安全側で扱う。
            let signatures: [[UInt8]] = [
                [0xFF, 0xFE, 0x00, 0x00], [0x00, 0x00, 0xFE, 0xFF],
                [0x3C, 0x00, 0x00, 0x00], [0x00, 0x00, 0x00, 0x3C],
                [0x00, 0x00, 0x3C, 0x00], [0x00, 0x3C, 0x00, 0x00],
                [0x00, 0x00, 0xFF, 0xFE], [0xFE, 0xFF, 0x00, 0x00],
            ]
            if signatures.contains(head) { return true }
        }
        guard let name = XMLCharsetDetector.declaredCharsetName(
            in: data, includesHTMLMeta: false)
        else { return false }
        let normalized = name.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized.hasPrefix("utf32") || normalized.hasPrefix("ucs4")
    }

    /// 実体値の安全判定: 64 バイト以下で、`&` は「文字参照 `&#…;`」または
    /// 「XML 定義済み 5 実体(amp/lt/gt/quot/apos)」のみ許可。これらは
    /// 再帰展開しないので指数爆発の入口にならない。一般実体参照 `&name;` は
    /// 不許可。`&#38;`(&)・`&#37;`(%)・`&amp;` は宣言済み値へ後から参照を
    /// 密輸する抜け道になるため数値・実体いずれの形でも不許可
    private static func isSafeEntityValue(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let predefinedSafe: Set<String> = ["lt", "gt", "quot", "apos"]
        var rest = Substring(value)
        while let amp = rest.firstIndex(of: "&") {
            let after = rest[amp...]
            if let match = after.prefixMatch(
                of: /&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});/) {
                let number = match.1
                let scalar = number.hasPrefix("x")
                    ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                guard let scalar, scalar != 0x26, scalar != 0x25 else { return false }
                rest = after[match.range.upperBound...]
            } else if let match = after.prefixMatch(of: /&([a-zA-Z]+);/),
                      predefinedSafe.contains(String(match.1)) {
                rest = after[match.range.upperBound...]
            } else {
                return false  // 一般実体参照・&amp;・不正形は不許可
            }
        }
        return true
    }

    /// UTF-16(BOM 付き、または BOM なしで交互に 0x00 が入る)を UTF-8 の
    /// バイト列へ変換する。それ以外(UTF-8・Shift_JIS 等の ASCII 上位互換)は
    /// そのまま返す。DOCTYPE スキャナが ASCII リテラルで動くための正規化
    private static func normalizedXMLBytes(_ data: Data) -> Data {
        func toUTF8(_ encoding: String.Encoding, skippingBOM: Int) -> Data? {
            String(data: data.dropFirst(skippingBOM), encoding: encoding)
                .map { Data($0.utf8) }
        }
        let head = Array(data.prefix(4))
        if head.count >= 2 {
            if head[0] == 0xFF, head[1] == 0xFE {
                return toUTF8(.utf16LittleEndian, skippingBOM: 2) ?? data
            }
            if head[0] == 0xFE, head[1] == 0xFF {
                return toUTF8(.utf16BigEndian, skippingBOM: 2) ?? data
            }
        }
        // BOM なし UTF-16 は先頭 '<'(0x3C)が 0x00 と対になる
        if head.count >= 2 {
            if head[0] == 0x3C, head[1] == 0x00 {
                return toUTF8(.utf16LittleEndian, skippingBOM: 0) ?? data
            }
            if head[0] == 0x00, head[1] == 0x3C {
                return toUTF8(.utf16BigEndian, skippingBOM: 0) ?? data
            }
        }
        return data
    }

    /// 文字列からコメント(`<!-- -->`)と処理命令(`<? ?>`)を取り除く。
    /// DOCTYPE 内部サブセットの実体宣言カウントを、コメント/PI に隠された
    /// `<!ENTITY` に惑わされずに行うための前処理
    private static func strippingCommentsAndPIs(_ text: String) -> String {
        var result = text
        for pattern in [/<!--[\s\S]*?-->/, /<\?[\s\S]*?\?>/] {
            result = result.replacing(pattern, with: "")
        }
        return result
    }

    /// プロローグ(ルート要素より前)にある DOCTYPE 宣言全体のスライスを返す。
    /// コメント・処理命令を正しく飛ばし、DOCTYPE 内は引用文字列・コメント・
    /// 内部サブセット [ ] を追跡して終端 `>` を決める(引用中の `]>` 等で
    /// 早期終了して以降の宣言を見逃さないため)
    private static func internalDoctypeSlice(_ data: Data) throws -> Data? {
        // cooViewer-oxr.86: 未終端 DOCTYPE を後段の正規表現へ無制限に渡さない。
        // 1 回の前向き走査を 64 KiB で打ち切り、入力長に依存する二乗時間を防ぐ。
        let maxDoctypeByteCount = 64 * 1024
        var i = data.startIndex
        let lt = UInt8(ascii: "<")
        func matches(_ literal: String, at index: Data.Index) -> Bool {
            let bytes = Array(literal.utf8)
            guard data.distance(from: index, to: data.endIndex) >= bytes.count
            else { return false }
            for (offset, byte) in bytes.enumerated()
            where data[data.index(index, offsetBy: offset)] != byte {
                return false
            }
            return true
        }
        while i < data.endIndex {
            guard data[i] == lt else {
                i = data.index(after: i)
                continue
            }
            if matches("<?", at: i) {
                // 処理命令・XML 宣言: "?>" まで飛ばす
                guard let end = data[i...].firstRange(of: Data("?>".utf8))
                else { return nil }
                i = end.upperBound
            } else if matches("<!--", at: i) {
                guard let end = data[i...].firstRange(of: Data("-->".utf8))
                else { return nil }
                i = end.upperBound
            } else if matches("<!DOCTYPE", at: i) {
                let start = i
                var j = data.index(i, offsetBy: 9)
                var quote: UInt8? = nil
                var subsetDepth = 0
                var inComment = false
                var inProcessingInstruction = false
                while j < data.endIndex {
                    guard data.distance(from: start, to: j) < maxDoctypeByteCount else {
                        throw EPUBError.malformed(
                            "DOCTYPE exceeds the 65536-byte safety limit")
                    }
                    let byte = data[j]
                    if inComment {
                        if matches("-->", at: j) {
                            inComment = false
                            j = data.index(j, offsetBy: 3)
                            continue
                        }
                    } else if inProcessingInstruction {
                        if matches("?>", at: j) {
                            inProcessingInstruction = false
                            j = data.index(j, offsetBy: 2)
                            continue
                        }
                    } else if let q = quote {
                        if byte == q { quote = nil }
                    } else if matches("<!--", at: j) {
                        inComment = true
                        j = data.index(j, offsetBy: 4)
                        continue
                    } else if matches("<?", at: j) {
                        // 内部サブセット内の処理命令。PI 内の `]` や `>` に
                        // 騙されて DOCTYPE を早期終了しないよう "?>" まで飛ばす
                        inProcessingInstruction = true
                        j = data.index(j, offsetBy: 2)
                        continue
                    } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                        quote = byte
                    } else if byte == UInt8(ascii: "[") {
                        subsetDepth += 1
                    } else if byte == UInt8(ascii: "]") {
                        subsetDepth = max(0, subsetDepth - 1)
                    } else if byte == UInt8(ascii: ">"), subsetDepth == 0 {
                        return data[start...j]
                    }
                    j = data.index(after: j)
                }
                throw EPUBError.malformed("Unterminated DOCTYPE declaration")
            } else {
                return nil  // ルート要素(または他の <! 構文)に到達: DTD なし
            }
        }
        return nil
    }

    /// cooViewer-oxr.10/13: WHATWG 表にある HTML 名前実体を 1 回の走査で探す。
    /// & (0x26) は Shift_JIS/EUC-JP の trail byte 範囲に入らないため、
    /// 非 UTF-8 のまま走査しても ASCII の実体名を誤認しない。
    private static func containsNamedEntity(_ data: Data) -> Bool {
        let normalized = normalizedXMLBytes(data)
        return normalized.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                guard bytes[index] == UInt8(ascii: "&") else {
                    index += 1
                    continue
                }
                let nameStart = index + 1
                guard nameStart < bytes.count, isASCIIEntityNameStart(bytes[nameStart])
                else {
                    index += 1
                    continue
                }
                var cursor = nameStart + 1
                while cursor < bytes.count,
                      cursor - nameStart < 32,
                      isASCIIEntityNameContinuation(bytes[cursor]) {
                    cursor += 1
                }
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";") {
                    let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self)
                    if HTMLEntities.table[name] != nil { return true }
                }
                index += 1
            }
            return false
        }
    }

    /// cooViewer-oxr.10/13: XML 定義済み 5 実体以外の HTML 実体を、
    /// 1 回の走査で数値文字参照へ置換する。未知の実体名は変更しない。
    /// 非 UTF-8(Shift_JIS/EUC-JP/UTF-16)の文書でも救済できるよう、宣言の
    /// encoding を尊重して復号してから置換し、UTF-8 で再エンコードする
    private static func sanitizeEntities(_ rawData: Data) -> Data {
        // UTF-16 は先に UTF-8 バイトへ畳む
        let data = normalizedXMLBytes(rawData)
        guard let text = decodeXMLText(data) else { return data }
        let sanitized = replacingNamedEntities(in: text)
        // 出力バイトは UTF-8。宣言の encoding が別物のままだと再パースが
        // "switching encoding" で失敗するため、宣言も UTF-8 に書き換える
        return Data(rewriteXMLEncodingToUTF8(sanitized).utf8)
    }

    /// cooViewer-oxr.12: UTF-8 を優先し、不正な場合だけ共有 detector が
    /// XML 宣言、meta charset、http-equiv の順で見つけた文字コードを使う。
    private static func decodeXMLText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        guard let encoding = XMLCharsetDetector.declaredEncoding(in: data) else {
            return nil
        }
        return String(data: data, encoding: encoding)
    }

    private static func replacingNamedEntities(in text: String) -> String {
        let input = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var unchangedStart = 0
        var index = 0
        while index < input.count {
            guard input[index] == UInt8(ascii: "&") else {
                index += 1
                continue
            }
            let nameStart = index + 1
            guard nameStart < input.count, isASCIIEntityNameStart(input[nameStart])
            else {
                index += 1
                continue
            }
            var cursor = nameStart + 1
            while cursor < input.count,
                  cursor - nameStart < 32,
                  isASCIIEntityNameContinuation(input[cursor]) {
                cursor += 1
            }
            guard cursor < input.count, input[cursor] == UInt8(ascii: ";"),
                  let replacement = HTMLEntities.table[
                    String(decoding: input[nameStart..<cursor], as: UTF8.self)]
            else {
                index += 1
                continue
            }
            output.append(contentsOf: input[unchangedStart..<index])
            output.append(contentsOf: replacement.utf8)
            index = cursor + 1
            unchangedStart = index
        }
        output.append(contentsOf: input[unchangedStart...])
        return String(decoding: output, as: UTF8.self)
    }

    private static func isASCIIEntityNameStart(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isASCIIEntityNameContinuation(_ byte: UInt8) -> Bool {
        isASCIIEntityNameStart(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    /// 先頭 XML 宣言内の encoding 属性を UTF-8 へ書き換える(宣言が無ければ無変更)
    private static func rewriteXMLEncodingToUTF8(_ text: String) -> String {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>") else {
            return text
        }
        let declaration = text[text.startIndex..<end.upperBound]
        let rewritten = declaration.replacing(
            /encoding\s*=\s*["'][^"'<>]+["']/, with: "encoding=\"UTF-8\"")
        return String(rewritten) + String(text[end.upperBound...])
    }
}

extension XMLElement {
    // cooViewer-oxr.7/89: 本文抽出と JavaScript のテキスト地図が共有する
    // 非表示要素名。表示層は同じ名前一覧だけを複製して DOM を走査する。
    static let readableTextSkippedElementNames =
        alwaysSkippedReadableTextElementNames
            .union(svgSkippedReadableTextElementNames)
            .union(mathMLSkippedReadableTextElementNames)

    static func shouldSkipReadableTextElement(_ element: XMLElement) -> Bool {
        guard let name = element.localName?.lowercased() else { return false }
        if alwaysSkippedReadableTextElementNames.contains(name) { return true }
        var ancestor: XMLNode? = element
        while let node = ancestor {
            if let candidate = node as? XMLElement {
                let ancestorName = candidate.localName?.lowercased()
                if svgSkippedReadableTextElementNames.contains(name),
                   candidate.uri == XMLNamespace.svg || ancestorName == "svg"
                {
                    return true
                }
                if mathMLSkippedReadableTextElementNames.contains(name),
                   candidate.uri == XMLNamespace.mathML
                    || ancestorName == "math"
                {
                    return true
                }
            }
            ancestor = node.parent
        }
        return false
    }

    private static let alwaysSkippedReadableTextElementNames: Set<String> = [
        "rt", "rp", "rtc", "script", "style",
    ]
    private static let svgSkippedReadableTextElementNames: Set<String> = [
        "title", "desc",
    ]
    private static let mathMLSkippedReadableTextElementNames: Set<String> = [
        "annotation", "annotation-xml",
    ]

    /// 名前空間 URI + ローカル名で子要素を探す。名前空間宣言を欠いた不正
    /// ファイルの救済として、URI 一致に加え「接頭辞なし・URI なし」の要素も
    /// 同名なら受け入れる(EPUB 実在ファイルへの寛容さを優先)
    func wsChildren(_ localName: String, ns uri: String) -> [XMLElement] {
        let matched = elements(forLocalName: localName, uri: uri)
        if !matched.isEmpty { return matched }
        return (children ?? []).compactMap { node -> XMLElement? in
            guard let element = node as? XMLElement,
                  element.localName == localName,
                  element.uri == nil || element.uri?.isEmpty == true
            else { return nil }
            return element
        }
    }

    func wsFirst(_ localName: String, ns uri: String) -> XMLElement? {
        wsChildren(localName, ns: uri).first
    }

    /// 属性値(接頭辞なし属性は名前空間を持たないため名前だけで引く)
    func attr(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }

    /// 名前空間付き属性(epub:type 等)。宣言漏れファイルの救済として
    /// 接頭辞付きの素の名前でも引いてみる
    func attr(_ localName: String, ns uri: String, prefix: String) -> String? {
        attribute(forLocalName: localName, uri: uri)?.stringValue
            ?? attribute(forName: "\(prefix):\(localName)")?.stringValue
    }

    /// cooViewer-oxr.7: XML 空白と NBSP の連続だけを畳み、U+3000 は保持する。
    var normalizedText: String {
        Self.collapsingXMLWhitespace(stringValue ?? "")
    }

    /// cooViewer-oxr.7/89: ルビ読み・非表示テキストを除いた目次用文字列。
    /// SVG と MathML の代替説明は名前空間または祖先要素を見て除外する。
    var readableText: String {
        func collect(
            from element: XMLElement,
            insideSVG: Bool,
            insideMathML: Bool
        ) -> String {
            let name = element.localName?.lowercased() ?? ""
            let isSVG = insideSVG || element.uri == XMLNamespace.svg || name == "svg"
            let isMathML = insideMathML
                || element.uri == XMLNamespace.mathML
                || name == "math"
            if Self.alwaysSkippedReadableTextElementNames.contains(name)
                || (isSVG && Self.svgSkippedReadableTextElementNames.contains(name))
                || (isMathML
                    && Self.mathMLSkippedReadableTextElementNames.contains(name))
            {
                return ""
            }
            return (element.children ?? []).map { node in
                if let child = node as? XMLElement {
                    return collect(
                        from: child, insideSVG: isSVG, insideMathML: isMathML)
                }
                return node.kind == .text ? (node.stringValue ?? "") : ""
            }.joined()
        }

        let text = Self.collapsingXMLWhitespace(
            collect(from: self, insideSVG: false, insideMathML: false))
        if !text.isEmpty { return text }

        // cooViewer-oxr.7: W3C RS 3.4 §8 に従い画像代替文を優先する。
        if let image = Self.firstDescendantImage(in: self) {
            for value in [image.attr("alt"), image.attr("title")].compactMap({ $0 }) {
                let fallback = Self.collapsingXMLWhitespace(value)
                if !fallback.isEmpty { return fallback }
            }
        }
        for value in [attr("aria-label"), attr("title")].compactMap({ $0 }) {
            let fallback = Self.collapsingXMLWhitespace(value)
            if !fallback.isEmpty { return fallback }
        }
        return ""
    }

    private static func firstDescendantImage(in element: XMLElement) -> XMLElement? {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName?.lowercased() == "img" { return child }
            if let image = firstDescendantImage(in: child) { return image }
        }
        return nil
    }

    private static func collapsingXMLWhitespace(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var pendingSpace = false
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0x0009, 0x000A, 0x000D, 0x0020, 0x00A0:
                if !result.isEmpty { pendingSpace = true }
            default:
                if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // cooViewer-oxr.6/7: 画像ページ判定専用。非本文の要素と非表示の代替文を
    // 除く。Core では外部 CSS は評価しない。
    var normalizedVisibleText: String {
        func text(in element: XMLElement, insideSVG: Bool) -> String {
            let name = element.localName?.lowercased() ?? ""
            let isSVG = insideSVG || name == "svg"
            if name == "script" || name == "style"
                || (isSVG && (name == "title" || name == "desc"))
                || element.attribute(forName: "hidden") != nil {
                return ""
            }
            // cooViewer-oxr.6: インラインの display:none も WebKit 側と揃える。
            if let style = element.attr("style"),
               style.range(of: #"(?:^|;)\s*display\s*:\s*none\s*(?:!important\s*)?(?:;|$)"#,
                           options: [.regularExpression, .caseInsensitive]) != nil {
                return ""
            }
            return (element.children ?? []).map { node in
                if let child = node as? XMLElement {
                    return text(in: child, insideSVG: isSVG)
                }
                return node.kind == .text ? (node.stringValue ?? "") : ""
            }.joined()
        }
        return text(in: self, insideSVG: false)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
