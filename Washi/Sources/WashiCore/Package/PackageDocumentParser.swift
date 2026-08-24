import Foundation

/// property 値(接頭辞付きトークン)の正規化。
/// 予約接頭辞(EPUB 3.3 §D.1)はそのまま、package@prefix で独自宣言された
/// 接頭辞は予約 vocab の IRI と一致すれば予約接頭辞形へ写す。
/// 例: prefix="rend: http://www.idpf.org/vocab/rendition/#" のとき
/// "rend:layout" → "rendition:layout"
struct PropertyResolver: Sendable {
    /// 予約 vocab IRI → 正規接頭辞
    private static let reservedVocabs: [String: String] = [
        "http://www.idpf.org/vocab/rendition/#": "rendition",
        "http://purl.org/dc/terms/": "dcterms",
        "http://www.idpf.org/epub/vocab/package/a11y/#": "a11y",
        "http://id.loc.gov/vocabulary/": "marc",
        "http://www.idpf.org/epub/vocab/overlays/#": "media",
        "http://www.editeur.org/ONIX/book/codelists/current.html#": "onix",
        "http://schema.org/": "schema",
        "http://www.w3.org/2001/XMLSchema#": "xsd",
    ]
    private static let reservedPrefixes = Set(reservedVocabs.values)

    /// 宣言済み接頭辞 → IRI
    let declared: [String: String]

    /// package@prefix の書式は「接頭辞: IRI」の空白区切り列
    init(prefixAttribute: String?) {
        var mapping: [String: String] = [:]
        if let prefixAttribute {
            let tokens = prefixAttribute
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            var pending: String?
            for token in tokens {
                if token.hasSuffix(":"), pending == nil {
                    pending = String(token.dropLast())
                } else if let prefix = pending {
                    mapping[prefix] = token
                    pending = nil
                }
            }
        }
        self.declared = mapping
    }

    func canonicalize(_ property: String) -> String {
        let trimmed = property.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let prefix = String(trimmed[..<colon])
        let name = String(trimmed[trimmed.index(after: colon)...])
        if Self.reservedPrefixes.contains(prefix) { return trimmed }
        if let iri = declared[prefix], let canonical = Self.reservedVocabs[iri] {
            return canonical + ":" + name
        }
        return trimmed
    }

    /// 空白区切りの property リスト(manifest/itemref の properties 属性)
    func canonicalizeList(_ list: String?) -> Set<String> {
        guard let list else { return [] }
        return Set(list.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map(canonicalize))
    }
}

/// パッケージ文書(OPF)のパーサ(EPUB 3.3 §5、EPUB 2.0.1 互換込み)
enum PackageDocumentParser {
    static func parse(data: Data, at containerPath: String) throws -> EPUBPackage {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement(), root.localName == "package" else {
            throw EPUBError.malformed("package 要素がない: \(containerPath)")
        }
        let version = root.attr("version") ?? "3.0"
        let resolver = PropertyResolver(prefixAttribute: root.attr("prefix"))

        guard let metadataElement = root.wsFirst("metadata", ns: XMLNamespace.opf) else {
            throw EPUBError.malformed("metadata 要素がない: \(containerPath)")
        }
        var metadata = parseMetadata(metadataElement, resolver: resolver)
        if let uniqueIDRef = root.attr("unique-identifier") {
            metadata.uniqueIdentifier = metadata.identifiers
                .first { $0.id == uniqueIDRef }?.value
        }
        // unique-identifier 参照が壊れているファイルの救済(最初の識別子を採用)
        if metadata.uniqueIdentifier == nil {
            metadata.uniqueIdentifier = metadata.identifiers.first?.value
        }

        guard let manifestElement = root.wsFirst("manifest", ns: XMLNamespace.opf) else {
            throw EPUBError.malformed("manifest 要素がない: \(containerPath)")
        }
        var manifest: [ManifestItem] = []
        var manifestByID: [String: ManifestItem] = [:]
        for element in manifestElement.wsChildren("item", ns: XMLNamespace.opf) {
            guard let id = element.attr("id"),
                  let href = element.attr("href"),
                  let mediaType = element.attr("media-type") else { continue }
            let item = ManifestItem(
                id: id,
                href: href,
                mediaType: mediaType,
                properties: resolver.canonicalizeList(element.attr("properties")),
                fallback: element.attr("fallback"),
                mediaOverlay: element.attr("media-overlay")
            )
            if manifestByID[id] == nil {
                manifestByID[id] = item
                manifest.append(item)
            }
        }

        guard let spineElement = root.wsFirst("spine", ns: XMLNamespace.opf) else {
            throw EPUBError.malformed("spine 要素がない: \(containerPath)")
        }
        let direction = spineElement.attr("page-progression-direction")
            .flatMap(PageProgressionDirection.init(rawValue:)) ?? .byDefault
        var itemRefs: [SpineItemRef] = []
        for element in spineElement.wsChildren("itemref", ns: XMLNamespace.opf) {
            guard let idref = element.attr("idref") else { continue }
            itemRefs.append(SpineItemRef(
                idref: idref,
                linear: element.attr("linear")?.lowercased() != "no",
                properties: resolver.canonicalizeList(element.attr("properties"))
            ))
        }
        let spine = EPUBSpine(
            itemRefs: itemRefs,
            pageProgressionDirection: direction,
            tocItemID: spineElement.attr("toc")
        )

        return EPUBPackage(
            version: version,
            metadata: metadata,
            manifest: manifest,
            manifestByID: manifestByID,
            spine: spine,
            path: containerPath
        )
    }

    // MARK: - metadata

    /// metadata 直下の要素列。EPUB 2.0 の <dc-metadata>/<x-metadata> ラッパーが
    /// あればその中身も平坦化して含める(OPF 2.0.1 互換)
    private static func flattenedChildren(_ element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == "dc-metadata" || child.localName == "x-metadata" {
                result.append(contentsOf: (child.children ?? [])
                    .compactMap { $0 as? XMLElement })
            } else {
                result.append(child)
            }
        }
        return result
    }

    private static func parseMetadata(
        _ element: XMLElement, resolver: PropertyResolver) -> EPUBMetadata {
        var metadata = EPUBMetadata()
        let children = flattenedChildren(element)

        // meta を先に集め、refines="#id" → id ごとの refine 辞書を作る
        var metaItems: [EPUBMetaItem] = []
        for meta in children where meta.localName == "meta" {
            if let property = meta.attr("property") {
                // EPUB 3 形式
                let refines = meta.attr("refines").map { ref -> String in
                    ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
                }
                metaItems.append(EPUBMetaItem(
                    property: resolver.canonicalize(property),
                    value: meta.normalizedText,
                    refines: refines,
                    scheme: meta.attr("scheme").map(resolver.canonicalize)
                ))
            } else if let name = meta.attr("name"), let content = meta.attr("content") {
                // EPUB 2 形式(cover 等)
                metaItems.append(EPUBMetaItem(
                    property: name, value: content, refines: nil, scheme: nil))
            }
        }
        var refinesByID: [String: [EPUBMetaItem]] = [:]
        for item in metaItems {
            if let refines = item.refines {
                refinesByID[refines, default: []].append(item)
            }
        }
        func refine(_ id: String?, _ property: String) -> String? {
            guard let id else { return nil }
            return refinesByID[id]?.first { $0.property == property }?.value
        }

        // dc:* 要素の走査(EPUB 2 互換の opf:* 属性・dc-metadata ラッパーも拾う)
        for child in children {
            guard child.uri == XMLNamespace.dc || child.name?.hasPrefix("dc:") == true,
                  let localName = child.localName else { continue }
            let value = child.normalizedText
            guard !value.isEmpty else { continue }
            let id = child.attr("id")
            switch localName {
            case "title":
                metadata.titles.append(EPUBTitle(
                    value: value,
                    type: refine(id, "title-type"),
                    fileAs: refine(id, "file-as")
                        ?? child.attr("file-as", ns: XMLNamespace.opf, prefix: "opf"),
                    displaySeq: refine(id, "display-seq").flatMap(Int.init)
                ))
            case "creator", "contributor":
                let person = EPUBCreator(
                    value: value,
                    role: refine(id, "role")
                        ?? child.attr("role", ns: XMLNamespace.opf, prefix: "opf"),
                    fileAs: refine(id, "file-as")
                        ?? child.attr("file-as", ns: XMLNamespace.opf, prefix: "opf"),
                    displaySeq: refine(id, "display-seq").flatMap(Int.init)
                )
                if localName == "creator" {
                    metadata.creators.append(person)
                } else {
                    metadata.contributors.append(person)
                }
            case "identifier":
                metadata.identifiers.append(EPUBIdentifier(
                    value: value,
                    id: id,
                    scheme: refine(id, "identifier-type")
                        ?? child.attr("scheme", ns: XMLNamespace.opf, prefix: "opf")
                ))
            case "language":
                metadata.languages.append(value)
            case "publisher":
                metadata.publishers.append(value)
            case "date":
                if metadata.date == nil { metadata.date = value }
            case "description":
                if metadata.description == nil { metadata.description = value }
            case "rights":
                if metadata.rights == nil { metadata.rights = value }
            case "subject":
                metadata.subjects.append(value)
            default:
                break
            }
        }

        // display-seq に従って安定ソート(未指定は末尾・元順維持)
        metadata.titles = stableOrdered(metadata.titles, seq: \.displaySeq)
        metadata.creators = stableOrdered(metadata.creators, seq: \.displaySeq)

        // 文書全体 meta(refines なし)の解釈
        for item in metaItems where item.refines == nil {
            switch item.property {
            case "dcterms:modified":
                if metadata.modified == nil { metadata.modified = item.value }
            case "rendition:layout":
                metadata.rendition.layout =
                    RenditionLayout(rawValue: item.value) ?? .reflowable
            case "rendition:orientation":
                metadata.rendition.orientation =
                    RenditionOrientation(rawValue: item.value) ?? .auto
            case "rendition:spread":
                // 廃止値 portrait は both と等価に扱う(EPUB 3.3 §D.3.4)
                metadata.rendition.spread = item.value == "portrait"
                    ? .both : (RenditionSpread(rawValue: item.value) ?? .auto)
            case "rendition:flow":
                metadata.rendition.flow =
                    RenditionFlow(rawValue: item.value) ?? .auto
            case "rendition:viewport":
                if metadata.rendition.viewport == nil {
                    metadata.rendition.viewport = item.value
                }
            default:
                break
            }
        }
        // belongs-to-collection は refine(collection-type / group-position)の
        // 解決に meta 要素自身の id 属性が要るため XML を直接見て組み立てる
        metadata.collections = resolveCollections(element, resolver: resolver,
                                                  refinesByID: refinesByID) ?? []
        metadata.metaItems = metaItems
        return metadata
    }

    /// belongs-to-collection の完全解決(meta 要素の id 属性が必要なため
    /// XML を直接見直す)。id 付きが 1 つもなければ nil(簡易版を維持)
    private static func resolveCollections(
        _ element: XMLElement, resolver: PropertyResolver,
        refinesByID: [String: [EPUBMetaItem]]) -> [EPUBCollectionMembership]? {
        var result: [EPUBCollectionMembership] = []
        var sawAny = false
        for meta in element.wsChildren("meta", ns: XMLNamespace.opf) {
            guard let property = meta.attr("property"),
                  resolver.canonicalize(property) == "belongs-to-collection",
                  meta.attr("refines") == nil else { continue }
            sawAny = true
            let id = meta.attr("id")
            let refines = id.flatMap { refinesByID[$0] } ?? []
            result.append(EPUBCollectionMembership(
                name: meta.normalizedText,
                type: refines.first { $0.property == "collection-type" }?.value,
                groupPosition: refines.first { $0.property == "group-position" }?.value
            ))
        }
        return sawAny ? result : nil
    }

    /// display-seq 指定付き要素を前に、指定順で並べる(未指定は元順のまま後ろ)
    private static func stableOrdered<T>(
        _ items: [T], seq: KeyPath<T, Int?>) -> [T] {
        let withSeq = items.enumerated().filter { $0.element[keyPath: seq] != nil }
        guard !withSeq.isEmpty else { return items }
        let ordered = withSeq.sorted {
            ($0.element[keyPath: seq] ?? 0, $0.offset)
                < ($1.element[keyPath: seq] ?? 0, $1.offset)
        }.map(\.element)
        let without = items.enumerated()
            .filter { $0.element[keyPath: seq] == nil }.map(\.element)
        return ordered + without
    }
}
