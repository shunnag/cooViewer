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
        try validateProlog(data)
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data, options: options)
        } catch {
            let sanitized = sanitizeEntities(data)
            document = try XMLDocument(data: sanitized, options: options)
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
        // libxml2 が見るのと同じ文字列で検査する。UTF-16(BOM または
        // 交互の 0x00)は UTF-8 相当へ正規化する — さもないと ASCII バイト
        // リテラルを見るスキャナが DOCTYPE を素通しし、UTF-16 で書かれた
        // 実体爆弾がガードを丸ごと迂回する
        let data = normalizedXMLBytes(rawData)
        guard let doctype = internalDoctypeSlice(data),
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
    private static func internalDoctypeSlice(_ data: Data) -> Data? {
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
                var inSubset = false
                while j < data.endIndex {
                    let byte = data[j]
                    if let q = quote {
                        if byte == q { quote = nil }
                    } else if matches("<!--", at: j) {
                        guard let end = data[j...].firstRange(of: Data("-->".utf8))
                        else { return data[start...] }
                        j = data.index(before: end.upperBound)
                    } else if matches("<?", at: j) {
                        // 内部サブセット内の処理命令。PI 内の `]` や `>` に
                        // 騙されて DOCTYPE を早期終了しないよう "?>" まで飛ばす
                        guard let end = data[j...].firstRange(of: Data("?>".utf8))
                        else { return data[start...] }
                        j = data.index(before: end.upperBound)
                    } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                        quote = byte
                    } else if byte == UInt8(ascii: "[") {
                        inSubset = true
                    } else if byte == UInt8(ascii: "]") {
                        inSubset = false
                    } else if byte == UInt8(ascii: ">"), !inSubset {
                        return data[start...j]
                    }
                    j = data.index(after: j)
                }
                return data[start...]  // 未終端 DOCTYPE は全体を検査対象に
            } else {
                return nil  // ルート要素(または他の <! 構文)に到達: DTD なし
            }
        }
        return nil
    }

    /// XML の定義済み 5 実体以外の頻出 HTML 実体を数値文字参照へ置換する。
    /// 非 UTF-8(Shift_JIS/EUC-JP/UTF-16)の文書でも救済できるよう、宣言の
    /// encoding を尊重して復号してから置換し、UTF-8 で再エンコードする
    /// (Shift_JIS + &nbsp; 等は日本の旧来 EPUB で頻出のため、これを取りこぼすと
    /// OPF なら本が開けず、本文なら抽出・検索が黙って空になる)
    private static func sanitizeEntities(_ rawData: Data) -> Data {
        // UTF-16 は先に UTF-8 バイトへ畳む
        let data = normalizedXMLBytes(rawData)
        guard var text = decodeXMLText(data) else { return data }
        let replacements: [(String, String)] = [
            ("&nbsp;", "&#160;"), ("&copy;", "&#169;"), ("&reg;", "&#174;"),
            ("&trade;", "&#8482;"), ("&hellip;", "&#8230;"), ("&mdash;", "&#8212;"),
            ("&ndash;", "&#8211;"), ("&lsquo;", "&#8216;"), ("&rsquo;", "&#8217;"),
            ("&ldquo;", "&#8220;"), ("&rdquo;", "&#8221;"), ("&middot;", "&#183;"),
            ("&times;", "&#215;"), ("&laquo;", "&#171;"), ("&raquo;", "&#187;"),
        ]
        for (entity, numeric) in replacements {
            text = text.replacingOccurrences(of: entity, with: numeric)
        }
        // 出力バイトは UTF-8。宣言の encoding が別物のままだと再パースが
        // "switching encoding" で失敗するため、宣言も UTF-8 に書き換える
        return Data(rewriteXMLEncodingToUTF8(text).utf8)
    }

    /// XML 宣言の encoding を尊重してテキスト化する。UTF-8 で読めればそのまま、
    /// 読めなければ宣言の encoding(Shift_JIS/EUC-JP 等)で復号する。
    /// 宣言のない非 UTF-8 は判別不能なので nil(誤推測して壊さない)
    private static func decodeXMLText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        guard let encoding = declaredEncoding(data) else { return nil }
        return String(data: data, encoding: encoding)
    }

    /// 先頭の XML 宣言から encoding="X" を読み、String.Encoding へ写す。
    /// 宣言部は ASCII なので Latin-1 でそのまま読める
    private static func declaredEncoding(_ data: Data) -> String.Encoding? {
        guard let head = String(data: data.prefix(256), encoding: .isoLatin1),
              let match = head.firstMatch(
                of: /encoding\s*=\s*["']([^"'<>]+)["']/) else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(
            String(match.1) as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
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

    /// 子孫のテキストを連結して空白を正規化した文字列
    var normalizedText: String {
        (stringValue ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
