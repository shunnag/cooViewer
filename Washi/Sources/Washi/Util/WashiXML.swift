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
        do {
            return try XMLDocument(data: data, options: options)
        } catch {
            let sanitized = sanitizeEntities(data)
            return try XMLDocument(data: sanitized, options: options)
        }
    }

    /// XML の定義済み 5 実体以外の頻出 HTML 実体を数値文字参照へ置換する
    private static func sanitizeEntities(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
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
        return Data(text.utf8)
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
