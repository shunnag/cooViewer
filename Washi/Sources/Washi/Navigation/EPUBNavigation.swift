import Foundation

/// 目次・ページリスト・ランドマークの 1 項目(木構造)
public struct EPUBNavItem: Sendable, Hashable {
    public let title: String
    /// ナビゲーション文書からの相対 href(フラグメント込み・記載のまま)。
    /// 見出しだけの項目(リンクなし span)は nil
    public let href: String?
    /// ランドマークの epub:type("cover" / "bodymatter" / "toc" 等)
    public let epubType: String?
    public let children: [EPUBNavItem]

    public init(title: String, href: String?, epubType: String? = nil,
                children: [EPUBNavItem] = []) {
        self.title = title
        self.href = href
        self.epubType = epubType
        self.children = children
    }
}

/// ナビゲーション一式
public struct EPUBNavigation: Sendable {
    public var toc: [EPUBNavItem] = []
    public var pageList: [EPUBNavItem] = []
    public var landmarks: [EPUBNavItem] = []
    /// ナビゲーション文書(または NCX)のコンテナ内パス(href 解決の基準)
    public var basePath: String = ""
}

/// EPUB 3 ナビゲーション文書(XHTML nav。EPUB 3.3 §7)のパーサ
enum NavigationDocumentParser {
    static func parse(data: Data, at containerPath: String) throws -> EPUBNavigation {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("ナビゲーション文書が壊れている: \(containerPath)")
        }
        var navigation = EPUBNavigation()
        navigation.basePath = containerPath

        let navElements = collectNavElements(root)
        for nav in navElements {
            let types = (nav.attr("type", ns: XMLNamespace.epubOps, prefix: "epub") ?? "")
                .components(separatedBy: .whitespaces)
            let items = parseList(nav)
            if types.contains("toc") {
                navigation.toc = items
            } else if types.contains("page-list") {
                navigation.pageList = items
            } else if types.contains("landmarks") {
                navigation.landmarks = items
            } else if navigation.toc.isEmpty {
                // epub:type を欠く不正ファイルの救済: 最初の nav を目次とみなす
                navigation.toc = items
            }
        }
        return navigation
    }

    private static func collectNavElements(_ element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        if element.localName == "nav" { result.append(element) }
        for node in element.children ?? [] {
            if let child = node as? XMLElement {
                result.append(contentsOf: collectNavElements(child))
            }
        }
        return result
    }

    /// nav 直下の ol(なければ子孫最初の ol)を木として読む
    private static func parseList(_ nav: XMLElement) -> [EPUBNavItem] {
        guard let list = firstDescendant("ol", in: nav) else { return [] }
        return parseListItems(list)
    }

    private static func parseListItems(_ list: XMLElement) -> [EPUBNavItem] {
        var items: [EPUBNavItem] = []
        for node in list.children ?? [] {
            guard let li = node as? XMLElement, li.localName == "li" else { continue }
            var title = ""
            var href: String?
            var epubType: String?
            var children: [EPUBNavItem] = []
            for childNode in li.children ?? [] {
                guard let child = childNode as? XMLElement else { continue }
                switch child.localName {
                case "a":
                    title = child.normalizedText
                    href = child.attr("href")
                    epubType = child.attr("type", ns: XMLNamespace.epubOps,
                                          prefix: "epub")
                case "span":
                    title = child.normalizedText
                case "ol":
                    children = parseListItems(child)
                default:
                    break
                }
            }
            guard !title.isEmpty || href != nil || !children.isEmpty else { continue }
            items.append(EPUBNavItem(title: title, href: href,
                                     epubType: epubType, children: children))
        }
        return items
    }

    private static func firstDescendant(_ localName: String,
                                        in element: XMLElement) -> XMLElement? {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == localName { return child }
            if let found = firstDescendant(localName, in: child) { return found }
        }
        return nil
    }
}

/// EPUB 2 互換の NCX(toc.ncx)パーサ。EPUB 3 でも後方互換のため同梱される
/// ことが多く、nav 文書がない場合のフォールバックに使う
enum NCXParser {
    static func parse(data: Data, at containerPath: String) throws -> EPUBNavigation {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("NCX が壊れている: \(containerPath)")
        }
        var navigation = EPUBNavigation()
        navigation.basePath = containerPath
        if let navMap = root.wsFirst("navMap", ns: XMLNamespace.ncx) {
            navigation.toc = parseNavPoints(in: navMap)
        }
        if let pageList = root.wsFirst("pageList", ns: XMLNamespace.ncx) {
            navigation.pageList = pageList
                .wsChildren("pageTarget", ns: XMLNamespace.ncx)
                .compactMap(parsePoint)
        }
        return navigation
    }

    private static func parseNavPoints(in element: XMLElement) -> [EPUBNavItem] {
        element.wsChildren("navPoint", ns: XMLNamespace.ncx).compactMap { point in
            guard let item = parsePoint(point) else { return nil }
            let children = parseNavPoints(in: point)
            return EPUBNavItem(title: item.title, href: item.href,
                               children: children)
        }
    }

    private static func parsePoint(_ point: XMLElement) -> EPUBNavItem? {
        let label = point.wsFirst("navLabel", ns: XMLNamespace.ncx)?
            .wsFirst("text", ns: XMLNamespace.ncx)?.normalizedText ?? ""
        let src = point.wsFirst("content", ns: XMLNamespace.ncx)?.attr("src")
        guard !label.isEmpty || src != nil else { return nil }
        return EPUBNavItem(title: label, href: src)
    }
}
