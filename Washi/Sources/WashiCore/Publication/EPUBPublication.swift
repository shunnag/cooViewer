import CoreGraphics
import Foundation
import ImageIO

/// A reading-order entry for one spine item (manifest- and path-resolved).
public struct ReadingOrderItem: Sendable {
    /// Index within the readingOrder array (what Washi calls the "spine index"; includes linear="no" items).
    public let spineIndex: Int
    public let itemRef: SpineItemRef
    public let item: ManifestItem
    /// Canonical path within the container.
    public let containerPath: String
}

/// Left/right spread placement (from FXL itemref properties).
public enum PageSpreadSlot: String, Sendable {
    case left, right, center
}

/// Information about a fixed-layout page.
public struct FixedLayoutPageInfo: Sendable {
    public let spineIndex: Int
    /// Page dimensions (CSS px) from the viewport meta tag (or SVG viewBox).
    public let viewportSize: CGSize?
    /// The container path of the image when the page merely lays out a single
    /// image; in that case the image can be decoded directly without WebKit
    /// (the vast majority of Japanese manga EPUBs are shaped this way).
    public let simpleImagePath: String?
    public let pageSpread: PageSpreadSlot?
}

/// A facade for a single EPUB book.
/// On open it parses OCF → package document → navigation → encryption.xml,
/// then stays immutable (`Sendable`). Resource reads are pure functions and
/// thread-safe.
public final class EPUBPublication: Sendable {
    public let url: URL
    let container: OCFContainer
    public let package: EPUBPackage
    public let navigation: EPUBNavigation
    public let encryption: EPUBEncryptionInfo
    public let readingOrder: [ReadingOrderItem]
    /// コンテナ内パス → マニフェスト項目(メディアタイプ解決用)
    private let manifestByPath: [String: ManifestItem]

    /// Opens an EPUB off the calling thread and returns the parsed publication.
    ///
    /// Parsing a large book (unzip, XML) is CPU-bound; this runs it at
    /// `.userInitiated` priority on a detached task so callers on the main
    /// actor stay responsive. Prefer this over the synchronous initializer in
    /// UI code.
    ///
    /// - Parameters:
    ///   - url: a `.epub` file or an unpacked EPUB directory.
    ///   - readStrategy: how the bytes are read from disk (see
    ///     ``EPUBReadStrategy``; `.alwaysCopy` avoids memory-mapping for
    ///     volatile or untrusted files).
    public static func open(url: URL,
                            readStrategy: EPUBReadStrategy = .mappedIfSafe)
        async throws -> EPUBPublication {
        try await Task.detached(priority: .userInitiated) {
            try EPUBPublication(url: url, readStrategy: readStrategy)
        }.value
    }

    /// Opens a `.epub` file or an already-unpacked EPUB directory.
    /// `readStrategy` controls how the bytes are read (see ``EPUBReadStrategy``).
    public convenience init(url: URL,
                            readStrategy: EPUBReadStrategy = .mappedIfSafe) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory) else {
            throw EPUBError.notAnEPUB(url.path)
        }
        if isDirectory.boolValue {
            try self.init(url: url, reader: FolderContainerReader(
                rootURL: url, readStrategy: readStrategy))
        } else {
            let archive: ZipArchive
            do {
                archive = try ZipArchive(url: url, readStrategy: readStrategy)
            } catch {
                throw EPUBError.notAnEPUB("ZIP として読めない: \(error)")
            }
            try self.init(url: url, reader: ZipContainerReader(archive: archive))
        }
    }

    /// Opens from in-memory `.epub` data (e.g. an EPUB nested inside an archive).
    public convenience init(data: Data, displayURL: URL) throws {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data)
        } catch {
            throw EPUBError.notAnEPUB("ZIP として読めない: \(error)")
        }
        try self.init(url: displayURL, reader: ZipContainerReader(archive: archive))
    }

    init(url: URL, reader: any ContainerReader) throws {
        self.url = url
        let container = try OCFContainer(reader: reader)
        self.container = container

        // 複数 rootfile は先頭(デフォルトレンディション)を採用(OCF §3.5.2.1)
        guard let packagePath = container.packageDocumentPaths.first,
              reader.exists(packagePath) else {
            throw EPUBError.malformed("パッケージ文書が見つからない")
        }
        let package = try PackageDocumentParser.parse(
            data: reader.read(packagePath), at: packagePath)
        self.package = package

        // encryption.xml(なければ空)
        let encryptionPath = "META-INF/encryption.xml"
        if reader.exists(encryptionPath) {
            self.encryption = (try? EPUBEncryptionInfo.parse(
                data: reader.read(encryptionPath))) ?? .empty
        } else {
            self.encryption = .empty
        }

        // 読書順: spine → manifest → コンテナ内パス
        var readingOrder: [ReadingOrderItem] = []
        var manifestByPath: [String: ManifestItem] = [:]
        for item in package.manifest {
            if let path = ContainerPath.resolve(base: packagePath, href: item.href) {
                manifestByPath[path] = item
            }
        }
        for itemRef in package.spine.itemRefs {
            guard let item = package.manifestByID[itemRef.idref],
                  let path = ContainerPath.resolve(base: packagePath, href: item.href)
            else { continue }
            readingOrder.append(ReadingOrderItem(
                spineIndex: readingOrder.count,
                itemRef: itemRef, item: item, containerPath: path))
        }
        guard !readingOrder.isEmpty else {
            throw EPUBError.malformed("spine が空")
        }
        self.readingOrder = readingOrder
        self.manifestByPath = manifestByPath

        // ナビゲーション: EPUB 3 nav → NCX の順で試し、両方なければ空
        var navigation = EPUBNavigation()
        if let navItem = package.navItem,
           let navPath = ContainerPath.resolve(base: packagePath, href: navItem.href),
           reader.exists(navPath),
           let parsed = try? NavigationDocumentParser.parse(
               data: reader.read(navPath), at: navPath) {
            navigation = parsed
        } else if let tocID = package.spine.tocItemID,
                  let ncxItem = package.manifestByID[tocID],
                  let ncxPath = ContainerPath.resolve(base: packagePath,
                                                      href: ncxItem.href),
                  reader.exists(ncxPath),
                  let parsed = try? NCXParser.parse(
                      data: reader.read(ncxPath), at: ncxPath) {
            navigation = parsed
        }
        self.navigation = navigation
    }

    // MARK: - 基本情報

    public var metadata: EPUBMetadata { package.metadata }
    public var isFixedLayout: Bool { package.isFixedLayout }

    /// Every non-directory resource path in the container, in no particular
    /// order. Useful for indexing, extraction tools, or auditing what a book
    /// ships. Read individual resources with ``resource(at:)``.
    public var resourcePaths: [String] { container.reader.allPaths }
    public var readingDirection: PageProgressionDirection {
        package.readingDirection
    }

    /// True when a spine content document is encrypted with an unknown
    /// algorithm — genuine DRM protection that Washi cannot open.
    /// If only auxiliary resources (fonts, etc.) use unknown encryption the
    /// book is still openable (rendering continues without that font;
    /// permitted by EPUB 3.3 OCF §4.4.2).
    public var isDRMProtected: Bool {
        guard !encryption.unknownEncryptedResources.isEmpty else { return false }
        let spinePaths = Set(readingOrder.map(\.containerPath))
        return encryption.unknownEncryptedResources.keys
            .contains { spinePaths.contains($0) }
    }

    /// Best-guess DRM scheme (detected from fingerprint files under META-INF); nil when not DRM-protected.
    public var drmSchemeName: String? {
        let reader = container.reader
        if reader.exists("META-INF/license.lcpl") { return "Readium LCP" }
        if reader.exists("META-INF/sinf.xml") { return "Apple FairPlay" }
        if reader.exists("META-INF/rights.xml"), isDRMProtected {
            return "Adobe ADEPT"
        }
        return isDRMProtected ? "不明な DRM" : nil
    }

    // MARK: - 読書位置の突き合わせ

    /// Builds a locator with the idref recorded alongside the spine index; use this for persisting a position.
    public func locator(forSpineIndex index: Int,
                        progression: Double = 0) -> EPUBLocator {
        EPUBLocator(spineIndex: index, progression: progression,
                    idref: readingOrder.indices.contains(index)
                        ? readingOrder[index].itemRef.idref : nil)
    }

    /// Matches a saved position against this book. When an idref is present it
    /// tracks spine reordering and additions/removals (a revised edition of the
    /// book) to map onto the correct item, returning nil if that idref is gone
    /// (leaving the caller to decide, e.g. "start from the beginning").
    /// Legacy positions without an idref are only clamped into range.
    public func resolve(_ locator: EPUBLocator) -> EPUBLocator? {
        guard !readingOrder.isEmpty else { return nil }
        if let idref = locator.idref {
            if readingOrder.indices.contains(locator.spineIndex),
               readingOrder[locator.spineIndex].itemRef.idref == idref {
                return locator
            }
            guard let entry = readingOrder.first(
                where: { $0.itemRef.idref == idref }) else { return nil }
            return EPUBLocator(spineIndex: entry.spineIndex,
                               progression: locator.progression, idref: idref)
        }
        let clamped = max(0, min(locator.spineIndex, readingOrder.count - 1))
        return EPUBLocator(spineIndex: clamped, progression: locator.progression)
    }

    /// The manifest fallback chain (starting with the item itself; cycles are
    /// broken there. EPUB RS 3.3 §5.4).
    public func fallbackChain(for item: ManifestItem) -> [ManifestItem] {
        var chain: [ManifestItem] = [item]
        var seen: Set<String> = [item.id]
        var current = item
        while let fallbackID = current.fallback,
              let next = package.manifestByID[fallbackID],
              !seen.contains(fallbackID) {
            chain.append(next)
            seen.insert(fallbackID)
            current = next
        }
        return chain
    }

    /// Container path of the cover image.
    public var coverImagePath: String? {
        guard let item = package.coverImageItem else { return nil }
        return ContainerPath.resolve(base: package.path, href: item.href)
    }

    /// Resolves the cover image's container path through a fallback chain (for
    /// library listings: surface a cover even for real-world books that never
    /// declare one):
    /// ① manifest properties="cover-image" / EPUB 2 meta name="cover"
    /// ② the target of a landmark with epub:type="cover" (the image itself, or
    ///    the sole image within the document)
    /// ③ a manifest image item whose id or file name contains "cover"
    /// ④ the first spine item's image, if that item is a single-image page
    public var resolvedCoverImagePath: String? {
        if let path = coverImagePath { return path }
        if let path = landmarkCoverPath { return path }
        if let item = package.manifest.first(where: { item in
            item.mediaType.hasPrefix("image/")
                && item.id.lowercased().contains("cover")
        }) ?? package.manifest.first(where: { item in
            item.mediaType.hasPrefix("image/")
                && (item.href.split(separator: "/").last ?? "")
                    .lowercased().contains("cover")
        }) {
            return ContainerPath.resolve(base: package.path, href: item.href)
        }
        if let info = try? fixedLayoutInfo(forSpineIndex: 0),
           let imagePath = info.simpleImagePath {
            return imagePath
        }
        return nil
    }

    /// landmarks の epub:type="cover" 経由の表紙解決(②)
    private var landmarkCoverPath: String? {
        guard let landmark = navigation.landmarks.first(where: {
            $0.epubType?.components(separatedBy: .whitespaces)
                .contains("cover") == true
        }), let href = landmark.href else { return nil }
        let raw = href.split(separator: "#").first.map(String.init) ?? href
        guard let docPath = ContainerPath.resolve(
            base: navigation.basePath, href: raw) else { return nil }
        let mediaType = manifestByPath[docPath]?.mediaType
            ?? EPUBMediaType.guessed(fromPath: docPath)
        if mediaType.hasPrefix("image/") { return docPath }
        // 表紙ページ(XHTML)の中の唯一の画像を表紙とみなす
        guard mediaType == EPUBMediaType.xhtml,
              let (data, _) = try? resource(at: docPath),
              let document = try? WashiXML.document(from: data),
              let root = document.rootElement(),
              let body = Self.firstDescendant("body", in: root) else { return nil }
        let imgs = Self.descendants("img", in: body)
        if imgs.count == 1, let src = imgs[0].attr("src") {
            return ContainerPath.resolve(base: docPath, href: src)
        }
        let svgImages = Self.descendants("image", in: body)
        if imgs.isEmpty, svgImages.count == 1 {
            let href = svgImages[0].attribute(forLocalName: "href",
                                              uri: XMLNamespace.xlink)?.stringValue
                ?? svgImages[0].attr("xlink:href") ?? svgImages[0].attr("href")
            return href.flatMap { ContainerPath.resolve(base: docPath, href: $0) }
        }
        return nil
    }

    /// Decodes and returns the cover image (ImageIO only, no WebKit/AppKit, so
    /// it works from headless indexing tools too). Passing maxPixelSize scales
    /// it down to a thumbnail whose long edge is at most that many pixels (with
    /// EXIF rotation applied). Returns nil when the cover cannot be resolved,
    /// cannot be decoded (e.g. SVG), or is unreadable due to DRM.
    public func coverImage(maxPixelSize: Int? = nil) -> CGImage? {
        guard let path = resolvedCoverImagePath,
              let (data, _) = try? resource(at: path),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            return CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The resolved cover image's raw bytes and media type, without decoding —
    /// useful to store or serve the original file as-is (e.g. a library cache
    /// or a web response). Uses the same fallback chain as ``coverImage``.
    /// Nil if no cover resolves or it cannot be read (e.g. DRM).
    public func coverImageData() -> (data: Data, mediaType: String)? {
        guard let path = resolvedCoverImagePath else { return nil }
        return try? resource(at: path)
    }

    // MARK: - リソース読み出し

    /// Reads a resource by its container path, transparently reversing font
    /// obfuscation. Throws drmProtected for a resource under unknown encryption.
    public func resource(at containerPath: String) throws -> (data: Data, mediaType: String) {
        // コンテナ内パスはデコード済みが正規形。二重デコードしない(sanitize)
        let path = ContainerPath.sanitize(containerPath)
        if let algorithm = encryption.unknownEncryptedResources[path] {
            throw EPUBError.drmProtected(scheme: algorithm)
        }
        var data = try container.reader.read(path)
        if let algorithm = encryption.obfuscatedResources[path],
           let uid = obfuscationIdentifier(for: algorithm) {
            data = FontDeobfuscator.deobfuscate(data, algorithm: algorithm,
                                                uniqueIdentifier: uid)
        }
        let mediaType = manifestByPath[path]?.mediaType
            ?? EPUBMediaType.guessed(fromPath: path)
        return (data, mediaType)
    }

    /// 難読化解除に使う識別子の選択。IDPF は unique-identifier そのもの。
    /// Adobe は「UUID 形の dc:identifier」を鍵にするツールが実在するため、
    /// unique-identifier が UUID 形でなければ他の識別子から UUID 形を探す
    /// (readium-js #153 の実運用知見)
    private func obfuscationIdentifier(
        for algorithm: EPUBEncryptionInfo.ObfuscationAlgorithm) -> String? {
        switch algorithm {
        case .idpf:
            return metadata.uniqueIdentifier
        case .adobe:
            if let uid = metadata.uniqueIdentifier,
               FontDeobfuscator.adobeKey(uniqueIdentifier: uid) != nil {
                return uid
            }
            return metadata.identifiers.map(\.value)
                .first { FontDeobfuscator.adobeKey(uniqueIdentifier: $0) != nil }
                ?? metadata.uniqueIdentifier
        }
    }

    /// Reads a resource from a base path plus a relative href (e.g. resolving navigation items).
    public func resource(relativeTo basePath: String,
                         href: String) throws -> (data: Data, mediaType: String) {
        guard let path = ContainerPath.resolve(base: basePath, href: href) else {
            throw EPUBError.resourceNotFound(href)
        }
        return try resource(at: path)
    }

    /// Resolves an href (relative to a base path) into a container path.
    public func containerPath(forHref href: String,
                              relativeTo basePath: String) -> String? {
        ContainerPath.resolve(base: basePath, href: href)
    }

    /// Resolves a navigation item's href into a reading-order spine index.
    public func spineIndex(forNavItem item: EPUBNavItem) -> Int? {
        guard let href = item.href else { return nil }
        return spineIndex(forHref: href)
    }

    /// Resolves an href (as written in the navigation document, with an optional
    /// fragment) into a reading-order spine index. The fragment is ignored — the
    /// result is the spine item that contains the target. Nil if it resolves to
    /// no spine item. Useful for navigating from a TOC or a cross-reference.
    public func spineIndex(forHref href: String) -> Int? {
        let withoutFragment = href.split(separator: "#", maxSplits: 1,
                                         omittingEmptySubsequences: false)[0]
        guard let path = ContainerPath.resolve(base: navigation.basePath,
                                               href: String(withoutFragment))
        else { return nil }
        return readingOrder.firstIndex { $0.containerPath == path }
    }

    /// Whether any spine item declares a media overlay (SMIL narration). Use
    /// ``mediaOverlay(forSpineIndex:)`` to get the parsed clips for one item.
    public var hasMediaOverlays: Bool {
        readingOrder.contains { $0.item.mediaOverlay != nil }
    }

    /// The chapter title a spine index belongs to (the TOC is flattened and the
    /// last item at or before that position is taken as the current chapter).
    /// For running-head display; nil when there is no match.
    public func chapterTitle(forSpineIndex index: Int) -> String? {
        var best: (index: Int, title: String)?
        func walk(_ items: [EPUBNavItem]) {
            for item in items {
                if let itemIndex = spineIndex(forNavItem: item),
                   itemIndex <= index,
                   best.map({ itemIndex >= $0.index }) ?? true,
                   !item.title.isEmpty {
                    best = (itemIndex, item.title)
                }
                walk(item.children)
            }
        }
        walk(navigation.toc)
        return best?.title
    }

    /// Checks whether a container path exists.
    public func resourceExists(at containerPath: String) -> Bool {
        container.reader.exists(ContainerPath.sanitize(containerPath))
    }

    // MARK: - 固定レイアウト

    /// Structural information about an FXL page (viewport, single-image-page
    /// detection, spread placement). Also returns viewport-less info for the
    /// spine items of a reflowable book.
    public func fixedLayoutInfo(forSpineIndex index: Int) throws -> FixedLayoutPageInfo {
        guard readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        let entry = readingOrder[index]
        // page-spread は接頭辞なし(EPUB 3.0 遺物)と rendition: 付き
        // (EPUB 3.1+)の両同義形を受ける
        let props = entry.itemRef.properties
        func hasSpread(_ slot: String) -> Bool {
            props.contains("page-spread-\(slot)")
                || props.contains("rendition:page-spread-\(slot)")
        }
        let spread: PageSpreadSlot?
        if hasSpread("left") {
            spread = .left
        } else if hasSpread("right") {
            spread = .right
        } else if hasSpread("center") {
            spread = .center
        } else {
            spread = nil
        }

        let (data, mediaType) = try resource(at: entry.containerPath)
        // SVG 単体 spine 項目
        if mediaType == EPUBMediaType.svg {
            let document = try? WashiXML.document(from: data)
            let size = (document?.rootElement()).flatMap(Self.svgSize)
            return FixedLayoutPageInfo(spineIndex: index, viewportSize: size,
                                       simpleImagePath: nil, pageSpread: spread)
        }
        guard let document = try? WashiXML.document(from: data),
              let root = document.rootElement() else {
            return FixedLayoutPageInfo(spineIndex: index, viewportSize: nil,
                                       simpleImagePath: nil, pageSpread: spread)
        }
        let viewport = Self.viewportSize(in: root)
            ?? package.metadata.rendition.viewport.flatMap(Self.parseViewportContent)
        let imageHref = Self.simpleImageHref(in: root)
        let imagePath = imageHref.flatMap {
            ContainerPath.resolve(base: entry.containerPath, href: $0)
        }
        return FixedLayoutPageInfo(spineIndex: index, viewportSize: viewport,
                                   simpleImagePath: imagePath, pageSpread: spread)
    }

    /// <meta name="viewport" content="width=1200, height=1920"> の解析
    private static func viewportSize(in root: XMLElement) -> CGSize? {
        guard let head = firstDescendant("head", in: root) else { return nil }
        for meta in descendants("meta", in: head) {
            guard meta.attr("name") == "viewport",
                  let content = meta.attr("content") else { continue }
            if let size = parseViewportContent(content) { return size }
        }
        return nil
    }

    static func parseViewportContent(_ content: String) -> CGSize? {
        var width: Double?
        var height: Double?
        for pair in content.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = leadingNumber(parts[1].trimmingCharacters(in: .whitespaces))
            // 最初の width/height 宣言だけを使う(EPUB RS 3.3 §8.1.2)
            if key == "width", width == nil { width = value }
            if key == "height", height == nil { height = value }
        }
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// "500px" → 500 の数値サルベージ(EPUB RS 3.3 §8.1.2 の寛容処理)
    private static func leadingNumber(_ text: String) -> Double? {
        var numeric = ""
        for ch in text {
            if ch.isNumber || (ch == "." && !numeric.contains(".")) {
                numeric.append(ch)
            } else {
                break
            }
        }
        return Double(numeric)
    }

    /// SVG ルートの寸法(viewBox 優先、なければ width/height 属性)
    private static func svgSize(_ root: XMLElement) -> CGSize? {
        if let viewBox = root.attr("viewBox") {
            let numbers = viewBox
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            if numbers.count == 4, numbers[2] > 0, numbers[3] > 0 {
                return CGSize(width: numbers[2], height: numbers[3])
            }
        }
        if let width = root.attr("width").flatMap(parseCSSLength),
           let height = root.attr("height").flatMap(parseCSSLength) {
            return CGSize(width: width, height: height)
        }
        return nil
    }

    private static func parseCSSLength(_ value: String) -> Double? {
        Double(value.trimmingCharacters(
            in: CharacterSet(charactersIn: "pxt ")))
    }

    /// 「画像 1 枚だけのページ」判定。本文テキストがなく、img が 1 つ
    /// (または svg > image が 1 つ)だけの XHTML なら画像 href を返す
    private static func simpleImageHref(in root: XMLElement) -> String? {
        guard let body = firstDescendant("body", in: root) else { return nil }
        // 本文にテキストがあれば画像ページではない
        guard body.normalizedText.isEmpty else { return nil }
        let imgs = descendants("img", in: body)
        let svgImages = descendants("image", in: body)
        if imgs.count == 1, svgImages.isEmpty {
            return imgs[0].attr("src")
        }
        if imgs.isEmpty, svgImages.count == 1 {
            let image = svgImages[0]
            return image.attribute(forLocalName: "href",
                                   uri: XMLNamespace.xlink)?.stringValue
                ?? image.attr("xlink:href")
                ?? image.attr("href")
        }
        return nil
    }

    // 別ファイルの extension(本文抽出)からも使うため internal
    static func firstDescendant(_ localName: String,
                                in element: XMLElement) -> XMLElement? {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == localName { return child }
            if let found = firstDescendant(localName, in: child) { return found }
        }
        return nil
    }

    private static func descendants(_ localName: String,
                                    in element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == localName { result.append(child) }
            result.append(contentsOf: descendants(localName, in: child))
        }
        return result
    }
}
