import CoreGraphics
import Foundation
import ImageIO

// cooViewer-oxr.67 / cooViewer-oxr.71: 本文抽出結果を spine 単位で再利用する。
// EPUBPublication は Sendable のため、可変状態は NSLock の内側だけで扱う。
private final class ExtractedTextCache: @unchecked Sendable {
    private struct Entry {
        let text: String
        let characterCount: Int
    }

    private let lock = NSLock()
    private let characterLimit: Int
    private var entries: [Int: Entry] = [:]
    private var insertionOrder: [Int] = []
    private var totalCharacterCount = 0

    init(characterLimit: Int) {
        self.characterLimit = characterLimit
    }

    func value(for spineIndex: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[spineIndex]?.text
    }

    func insert(_ text: String, for spineIndex: Int) {
        let characterCount = text.count
        guard characterCount <= characterLimit else { return }

        lock.lock()
        defer { lock.unlock() }
        guard entries[spineIndex] == nil else { return }
        while totalCharacterCount + characterCount > characterLimit,
              let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalCharacterCount -= removed.characterCount
            }
        }
        entries[spineIndex] = Entry(text: text, characterCount: characterCount)
        insertionOrder.append(spineIndex)
        totalCharacterCount += characterCount
    }
}

private struct EffectiveReadingDirectionResolution: Sendable {
    let direction: EPUBReadingDirection
    let source: EPUBReadingDirectionSource
}

// cooViewer-oxr.36: EPUBPublication の Sendable 契約を保ったまま、CSS を含む
// 方向判定を最初の参照時に一度だけ実行する。
private final class EffectiveReadingDirectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var resolution: EffectiveReadingDirectionResolution?

    func value(
        computing loader: () -> EffectiveReadingDirectionResolution
    ) -> EffectiveReadingDirectionResolution {
        lock.lock()
        defer { lock.unlock() }
        if let resolution { return resolution }
        let loaded = loader()
        resolution = loaded
        return loaded
    }
}

// cooViewer-oxr.8: 目次は文書順を保ったまま一度だけ spine 位置へ写像する。
private struct IndexedTOCEntry: Sendable {
    let spineIndex: Int
    let depth: Int
    let title: String
}

/// A reading-order entry for one spine item (manifest- and path-resolved).
public struct ReadingOrderItem: Sendable {
    /// Index within the readingOrder array (what Washi calls the "spine index"; includes linear="no" items).
    public let spineIndex: Int
    public let itemRef: SpineItemRef
    public let item: ManifestItem
    /// Canonical path within the container.
    public let containerPath: String
    /// The first renderable, existing manifest item reached through the
    /// fallback chain. This equals ``item`` when no usable fallback is needed
    /// or available.
    public let resolvedItem: ManifestItem
    /// Canonical path of ``resolvedItem``. Rendering and content extraction
    /// should use this path while preserving ``containerPath`` as the declared
    /// spine identity.
    public let resolvedContainerPath: String
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
    /// Whether the viewport uses `device-width` or `device-height` and should
    /// therefore be sized from the current rendering target.
    public let viewportIsDeviceSized: Bool
    /// The container path of the image when the page merely lays out a single
    /// image; in that case the image can be decoded directly without WebKit
    /// (the vast majority of Japanese manga EPUBs are shaped this way).
    public let simpleImagePath: String?
    public let pageSpread: PageSpreadSlot?
}

/// A facade for a single EPUB book.
/// On open it parses OCF → package document → navigation → encryption.xml,
/// then exposes immutable publication metadata (`Sendable`). Resource reads
/// and the synchronized extracted-text cache are thread-safe.
public final class EPUBPublication: Sendable {
    public let url: URL
    let container: OCFContainer
    public let package: EPUBPackage
    public let navigation: EPUBNavigation
    public let encryption: EPUBEncryptionInfo
    public let readingOrder: [ReadingOrderItem]
    /// コンテナ内パス → マニフェスト項目(メディアタイプ解決用)
    private let manifestByPath: [String: ManifestItem]
    /// cooViewer-oxr.8: 目次解決を呼び出しごとの spine 線形走査にしない。
    private let spineIndexByContainerPath: [String: Int]
    /// cooViewer-oxr.8: NCX 補完時は toc と nav 補助一覧の基準文書が異なる。
    private let tocBasePath: String
    private let indexedTOC: [IndexedTOCEntry]
    /// cooViewer-oxr.67 / cooViewer-oxr.71: 約 800 万文字を上限に FIFO で保持する。
    private let extractedTextCache: ExtractedTextCache
    private let effectiveReadingDirectionCache = EffectiveReadingDirectionCache()

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
                throw EPUBError.notAnEPUB(
                    "Unable to read ZIP: \(error.localizedDescription)")
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
            throw EPUBError.notAnEPUB(
                "Unable to read ZIP: \(error.localizedDescription)")
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
            throw EPUBError.malformed("Package document not found")
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
            // cooViewer-oxr.16: 宣言項目が非描画形式または欠落なら、fallback
            // 連鎖のうち描画可能かつ実在する最初の項目を表示用に採用する。
            let resolved = Self.resolvedSpineResource(
                for: item, package: package, packagePath: packagePath,
                reader: reader) ?? (item: item, path: path)
            readingOrder.append(ReadingOrderItem(
                spineIndex: readingOrder.count,
                itemRef: itemRef, item: item, containerPath: path,
                resolvedItem: resolved.item,
                resolvedContainerPath: resolved.path))
        }
        guard !readingOrder.isEmpty else {
            throw EPUBError.malformed("Spine is empty")
        }
        self.readingOrder = readingOrder
        self.manifestByPath = manifestByPath

        var spineIndexByContainerPath: [String: Int] = [:]
        for entry in readingOrder {
            for path in [entry.containerPath, entry.resolvedContainerPath]
            where spineIndexByContainerPath[path] == nil {
                spineIndexByContainerPath[path] = entry.spineIndex
            }
        }
        self.spineIndexByContainerPath = spineIndexByContainerPath

        // cooViewer-oxr.9: EPUB 3 nav を優先し、toc が空なら NCX で補完する。
        var navigation = EPUBNavigation()
        if let navItem = package.navItem,
           let navPath = ContainerPath.resolve(base: packagePath, href: navItem.href),
           reader.exists(navPath),
           let parsed = try? NavigationDocumentParser.parse(
               data: reader.read(navPath), at: navPath) {
            navigation = parsed
        }
        var tocBasePath = navigation.basePath
        if navigation.toc.isEmpty {
            let declaredNCX = package.spine.tocItemID
                .flatMap { package.manifestByID[$0] }
            let ncxItem = declaredNCX ?? package.manifest.first {
                $0.mediaType.lowercased() == "application/x-dtbncx+xml"
            }
            if let ncxItem,
               let ncxPath = ContainerPath.resolve(base: packagePath,
                                                   href: ncxItem.href),
               reader.exists(ncxPath),
               let ncx = try? NCXParser.parse(
                   data: reader.read(ncxPath), at: ncxPath) {
                tocBasePath = ncx.basePath
                if navigation.basePath.isEmpty {
                    navigation = ncx
                } else {
                    // cooViewer-oxr.9: nav と NCX の配置先が異なっても、単一の
                    // navigation.basePath から両方を正しく解決できる形へ直す。
                    navigation.toc = Self.rootRelativeNavigationItems(
                        ncx.toc, sourceBasePath: ncx.basePath)
                    if navigation.pageList.isEmpty {
                        navigation.pageList = Self.rootRelativeNavigationItems(
                            ncx.pageList, sourceBasePath: ncx.basePath)
                    }
                    tocBasePath = navigation.basePath
                }
            }
        }
        self.navigation = navigation
        self.tocBasePath = tocBasePath
        self.indexedTOC = Self.indexTOC(
            navigation.toc, basePath: tocBasePath,
            spineIndexByContainerPath: spineIndexByContainerPath)
        self.extractedTextCache = ExtractedTextCache(characterLimit: 8_000_000)
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

    /// The resolved reading direction after applying package, CSS, and language signals.
    ///
    /// Unlike ``readingDirection``, this value is always ``PageProgressionDirection/ltr``
    /// or ``PageProgressionDirection/rtl`` and never `default`.
    public var effectiveReadingDirection: EPUBReadingDirection {
        effectiveReadingDirectionResolution.direction
    }

    /// The publication signal that selected ``effectiveReadingDirection``.
    public var effectiveReadingDirectionSource: EPUBReadingDirectionSource {
        effectiveReadingDirectionResolution.source
    }

    private var effectiveReadingDirectionResolution: EffectiveReadingDirectionResolution {
        effectiveReadingDirectionCache.value {
            computeEffectiveReadingDirection()
        }
    }

    /// cooViewer-oxr.36: 宣言値、Kindle メタ、冒頭 CSS、RTL 言語の順で
    /// 省略されたページ進行方向を決定する。
    private func computeEffectiveReadingDirection() -> EffectiveReadingDirectionResolution {
        switch readingDirection {
        case .ltr, .rtl:
            return EffectiveReadingDirectionResolution(
                direction: readingDirection,
                source: .declared)
        case .byDefault:
            break
        }

        if let writingMode = metadata.metaItems.first(where: {
            $0.refines == nil
                && $0.property.lowercased() == "primary-writing-mode"
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch writingMode {
            case "vertical-rl", "horizontal-rl":
                return EffectiveReadingDirectionResolution(
                    direction: .rtl,
                    source: .primaryWritingModeMeta)
            case "vertical-lr", "horizontal-lr":
                return EffectiveReadingDirectionResolution(
                    direction: .ltr,
                    source: .primaryWritingModeMeta)
            default:
                break
            }
        }

        if firstReadingOrderStylesUseVerticalRTL() {
            return EffectiveReadingDirectionResolution(
                direction: .rtl,
                source: .verticalWritingCSS)
        }

        if let primaryLanguage = metadata.languages.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-", maxSplits: 1)
            .first.map(String.init),
           Self.rtlLanguageCodes.contains(primaryLanguage) {
            return EffectiveReadingDirectionResolution(
                direction: .rtl,
                source: .rtlLanguage)
        }

        return EffectiveReadingDirectionResolution(
            direction: .ltr,
            source: .fallback)
    }

    private static let rtlLanguageCodes: Set<String> = [
        "ar", "he", "fa", "ur", "yi", "ps", "sd", "ug", "dv",
    ]

    /// cooViewer-oxr.36: 冒頭の XHTML 最大 3 項目が実際に読み込む style/link
    /// だけを見る。CSS セレクタの完全評価はせず、使用中シート内の宣言を方向の
    /// ヒューリスティックとして扱う。
    private func firstReadingOrderStylesUseVerticalRTL() -> Bool {
        let documents = readingOrder.lazy.filter {
            Self.normalizedMediaType($0.resolvedItem.mediaType) == EPUBMediaType.xhtml
        }.prefix(3)

        for item in documents {
            guard let data = try? resource(at: item.resolvedContainerPath).data,
                  let document = try? WashiXML.document(from: data),
                  let root = document.rootElement()
            else { continue }

            let html = root.localName?.lowercased() == "html"
                ? root : Self.firstDescendant("html", in: root)
            let body = html.flatMap { Self.firstDescendant("body", in: $0) }
            if [html?.attr("style"), body?.attr("style")]
                .compactMap({ $0 })
                .contains(where: Self.cssUsesVerticalRTL) {
                return true
            }

            let styles = Self.descendants("style", in: root)
                .compactMap(\.stringValue)
            if styles.contains(where: Self.cssUsesVerticalRTL) {
                return true
            }

            for link in Self.descendants("link", in: root) {
                let relationships = (link.attr("rel") ?? "")
                    .lowercased()
                    .split(whereSeparator: { $0.isWhitespace })
                guard relationships.contains("stylesheet"),
                      let href = link.attr("href"),
                      let path = ContainerPath.resolve(
                        base: item.resolvedContainerPath,
                        href: href),
                      let cssData = try? resource(at: path).data,
                      let css = Self.cssString(cssData),
                      Self.cssUsesVerticalRTL(css)
                else { continue }
                return true
            }
        }
        return false
    }

    private static func cssString(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
    }

    private static func cssUsesVerticalRTL(_ css: String) -> Bool {
        css.range(
            of: #"(?i)(?:^|[;{\s])(?:-(?:webkit|epub)-)?writing-mode\s*:\s*(?:vertical-rl|tb-rl)(?:\s|[;!}]|$)"#,
            options: .regularExpression) != nil
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
        // Honor the contract ("nil when not DRM-protected") for every branch: a
        // stray META-INF/sinf.xml or license.lcpl in a repackaged, non-encrypted
        // EPUB must not report DRM (cooViewer-2hp). Adobe ADEPT already gated on
        // isDRMProtected; lift the gate to the top so LCP/FairPlay share it.
        guard isDRMProtected else { return nil }
        let reader = container.reader
        if reader.exists("META-INF/license.lcpl") { return "Readium LCP" }
        if reader.exists("META-INF/sinf.xml") { return "Apple FairPlay" }
        if reader.exists("META-INF/rights.xml") { return "Adobe ADEPT" }
        return "Unknown DRM"
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

    /// cooViewer-oxr.16: spine 表示に使える Core Media Type と XHTML だけを
    /// fallback 解決の終端候補にする。未知形式は連鎖をさらに辿る。
    private static func isRenderableSpineItem(_ item: ManifestItem) -> Bool {
        let mediaType = normalizedMediaType(item.mediaType)
        return mediaType == EPUBMediaType.xhtml
            || EPUBMediaType.coreImageTypes.contains(mediaType)
    }

    /// cooViewer-oxr.16: 循環を打ち切りつつ、実在性も含めて fallback を解決する。
    private static func resolvedSpineResource(
        for item: ManifestItem, package: EPUBPackage, packagePath: String,
        reader: any ContainerReader
    ) -> (item: ManifestItem, path: String)? {
        var current: ManifestItem? = item
        var seen: Set<String> = []
        while let candidate = current, seen.insert(candidate.id).inserted {
            if let path = ContainerPath.resolve(
                base: packagePath, href: candidate.href),
               isRenderableSpineItem(candidate), reader.exists(path) {
                return (candidate, path)
            }
            current = candidate.fallback.flatMap { package.manifestByID[$0] }
        }
        return nil
    }

    private static func normalizedMediaType(_ mediaType: String) -> String {
        mediaType.split(separator: ";", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } ?? ""
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
    /// or a web response). Uses the same fallback chain as
    /// ``coverImage(maxPixelSize:)``.
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
        let bases = tocBasePath == navigation.basePath
            ? [tocBasePath] : [tocBasePath, navigation.basePath]
        // cooViewer-oxr.9: NCX の toc と nav の補助一覧を併用する場合は、
        // それぞれの基準パスを定数個だけ試す。
        for basePath in bases {
            if let path = ContainerPath.resolve(
                base: basePath, href: String(withoutFragment)),
               let index = spineIndexByContainerPath[path] {
                return index
            }
        }
        return nil
    }

    /// Whether any spine item declares a media overlay (SMIL narration). Use
    /// ``mediaOverlay(forSpineIndex:)`` to get the parsed clips for one item.
    public var hasMediaOverlays: Bool {
        readingOrder.contains { $0.item.mediaOverlay != nil }
    }

    /// The chapter title a spine index belongs to.
    ///
    /// The first table-of-contents entry in document order wins when multiple
    /// entries target the same spine item. Fragment positions inside an item
    /// are not considered. For running-head display; nil when there is no match.
    public func chapterTitle(forSpineIndex index: Int) -> String? {
        var bestSpineIndex = -1
        var title: String?
        for entry in indexedTOC
        where entry.spineIndex <= index && !entry.title.isEmpty {
            // cooViewer-oxr.8: 同じ spine の後続項目では上書きせず文書順先頭を保つ。
            if entry.spineIndex > bestSpineIndex {
                bestSpineIndex = entry.spineIndex
                title = entry.title
            }
        }
        return title
    }

    /// cooViewer-oxr.67 / cooViewer-oxr.71: 本文抽出・検索・概算ページ数の共有経路。
    func cachedExtractedText(forSpineIndex index: Int,
                             loader: () throws -> String) rethrows -> String {
        if let cached = extractedTextCache.value(for: index) { return cached }
        let text = try loader()
        extractedTextCache.insert(text, for: index)
        return text
    }

    /// cooViewer-oxr.8: 深さ優先の文書順を崩さず、href を O(1) の索引で写像する。
    private static func indexTOC(
        _ items: [EPUBNavItem], basePath: String,
        spineIndexByContainerPath: [String: Int], depth: Int = 0
    ) -> [IndexedTOCEntry] {
        var result: [IndexedTOCEntry] = []
        for item in items {
            if let href = item.href,
               let path = ContainerPath.resolve(base: basePath, href: href),
               let spineIndex = spineIndexByContainerPath[path] {
                result.append(IndexedTOCEntry(
                    spineIndex: spineIndex, depth: depth, title: item.title))
            }
            result.append(contentsOf: indexTOC(
                item.children, basePath: basePath,
                spineIndexByContainerPath: spineIndexByContainerPath,
                depth: depth + 1))
        }
        return result
    }

    /// cooViewer-oxr.9: 別文書から併合する href をコンテナルート相対へ写す。
    private static func rootRelativeNavigationItems(
        _ items: [EPUBNavItem], sourceBasePath: String
    ) -> [EPUBNavItem] {
        items.map { item in
            let href = item.href.map { rawHref -> String in
                guard let path = ContainerPath.resolve(
                    base: sourceBasePath, href: rawHref) else { return rawHref }
                let suffixIndex = rawHref.firstIndex { $0 == "?" || $0 == "#" }
                let suffix = suffixIndex.map { String(rawHref[$0...]) } ?? ""
                return "/" + path + suffix
            }
            return EPUBNavItem(
                title: item.title, href: href, epubType: item.epubType,
                children: rootRelativeNavigationItems(
                    item.children, sourceBasePath: sourceBasePath))
        }
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

        let resolvedPath = entry.resolvedContainerPath
        let data = try resource(at: resolvedPath).data
        let mediaType = Self.normalizedMediaType(entry.resolvedItem.mediaType)
        // cooViewer-oxr.15: Core 画像が spine 自身なら ImageIO のヘッダー情報
        // だけで自然寸法を得て、WebKit を通さず画像そのものを表示できる。
        if mediaType.hasPrefix("image/"), mediaType != EPUBMediaType.svg {
            return FixedLayoutPageInfo(
                spineIndex: index, viewportSize: Self.imagePixelSize(data),
                viewportIsDeviceSized: false, simpleImagePath: resolvedPath,
                pageSpread: spread)
        }
        // cooViewer-oxr.91: SVG 単体 spine 項目も単一 image ラッパーなら
        // 参照画像を直接デコードできる。
        if mediaType == EPUBMediaType.svg {
            let document = try? WashiXML.document(from: data)
            let root = document?.rootElement()
            let size = root.flatMap(Self.svgSize)
            let imagePath = root.flatMap(Self.simpleSVGImageHref).flatMap {
                ContainerPath.resolve(base: resolvedPath, href: $0)
            }
            return FixedLayoutPageInfo(
                spineIndex: index, viewportSize: size,
                viewportIsDeviceSized: false, simpleImagePath: imagePath,
                pageSpread: spread)
        }
        guard let document = try? WashiXML.document(from: data),
              let root = document.rootElement() else {
            return FixedLayoutPageInfo(
                spineIndex: index, viewportSize: nil,
                viewportIsDeviceSized: false, simpleImagePath: nil,
                pageSpread: spread)
        }
        let viewport = Self.viewportDescription(in: root)
            ?? package.metadata.rendition.viewport.flatMap(Self.parseViewportDescription)
        let imageHref = Self.simpleImageHref(in: root)
        let imagePath = imageHref.flatMap {
            ContainerPath.resolve(base: resolvedPath, href: $0)
        }
        return FixedLayoutPageInfo(
            spineIndex: index, viewportSize: viewport?.size,
            viewportIsDeviceSized: viewport?.isDeviceSized ?? false,
            simpleImagePath: imagePath, pageSpread: spread)
    }

    /// <meta name="viewport" content="width=1200, height=1920"> の解析
    private static func viewportDescription(in root: XMLElement) -> ParsedViewport? {
        guard let head = firstDescendant("head", in: root) else { return nil }
        for meta in descendants("meta", in: head) {
            guard meta.attr("name") == "viewport",
                  let content = meta.attr("content") else { continue }
            if let viewport = parseViewportDescription(content) { return viewport }
        }
        return nil
    }

    static func parseViewportContent(_ content: String) -> CGSize? {
        parseViewportDescription(content)?.size
    }

    private struct ParsedViewport {
        let size: CGSize?
        let isDeviceSized: Bool
    }

    /// cooViewer-oxr.50: device-width/device-height は数値欠落ではなく、表示先
    /// 寸法へ追従する明示指定として保持する。
    private static func parseViewportDescription(_ content: String) -> ParsedViewport? {
        var width: Double?
        var height: Double?
        var sawWidth = false
        var sawHeight = false
        var isDeviceSized = false
        for pair in content.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // 最初の width/height 宣言だけを使う(EPUB RS 3.3 §8.1.2)
            if key == "width", !sawWidth {
                sawWidth = true
                if rawValue == "device-width" {
                    isDeviceSized = true
                } else {
                    width = leadingNumber(rawValue)
                }
            }
            if key == "height", !sawHeight {
                sawHeight = true
                if rawValue == "device-height" {
                    isDeviceSized = true
                } else {
                    height = leadingNumber(rawValue)
                }
            }
        }
        if isDeviceSized {
            return ParsedViewport(size: nil, isDeviceSized: true)
        }
        guard let width, let height, width > 0, height > 0 else { return nil }
        return ParsedViewport(size: CGSize(width: width, height: height),
                              isDeviceSized: false)
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

    /// cooViewer-oxr.15: 完全デコードせず ImageIO のプロパティから画素寸法を得る。
    private static func imagePixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { return nil }
        let size = CGSize(width: width.doubleValue, height: height.doubleValue)
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// cooViewer-oxr.91: 非描画メタデータを除き、唯一の描画内容が image の
    /// SVG だけを直接画像ページとして扱う。
    private static func simpleSVGImageHref(in root: XMLElement) -> String? {
        guard root.localName?.lowercased() == "svg" else { return nil }
        let ignored: Set<String> = ["title", "desc", "defs", "metadata"]
        let structural: Set<String> = ["svg", "g", "a"]
        var hrefs: [String?] = []
        var hasUnsupportedContent = false

        func inspect(_ element: XMLElement) {
            for node in element.children ?? [] {
                if node.kind == .text {
                    if !(node.stringValue ?? "").trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty {
                        hasUnsupportedContent = true
                    }
                    continue
                }
                guard node.kind == .element,
                      let child = node as? XMLElement,
                      let localName = child.localName?.lowercased()
                else { continue }
                if ignored.contains(localName) { continue }
                if localName == "text" {
                    hasUnsupportedContent = true
                } else if localName == "image" {
                    hrefs.append(child.attribute(
                        forLocalName: "href", uri: XMLNamespace.xlink)?.stringValue
                        ?? child.attr("xlink:href") ?? child.attr("href"))
                } else if structural.contains(localName) {
                    inspect(child)
                } else {
                    hasUnsupportedContent = true
                }
            }
        }

        inspect(root)
        guard !hasUnsupportedContent, hrefs.count == 1,
              let href = hrefs[0]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty else { return nil }
        return href
    }

    // cooViewer-oxr.6: 可視本文がなく、img / svg image の参照先が
    // 重複を除いて 1 種類だけの XHTML なら画像 href を返す。
    private static func simpleImageHref(in root: XMLElement) -> String? {
        guard let body = firstDescendant("body", in: root) else { return nil }
        // cooViewer-oxr.6: ReaderScripts と同じ可視テキスト・同一 src の判定。
        // style/script や隠された代替文、KCC のパネル用複製で表紙を除外しない。
        guard body.normalizedVisibleText.isEmpty else { return nil }
        let imgs = descendants("img", in: body)
        let svgImages = descendants("svg", in: body).flatMap { descendants("image", in: $0) }
        let sources = imgs.map { $0.attr("src") } + svgImages.map { image in
            image.attribute(forLocalName: "href", uri: XMLNamespace.xlink)?.stringValue
                ?? image.attr("xlink:href")
                ?? image.attr("href")
        }
        guard !sources.isEmpty, sources.allSatisfy({
            guard let source = $0 else { return false }
            return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        let uniqueSources = Set(sources.compactMap { $0 })
        return uniqueSources.count == 1 ? uniqueSources.first : nil
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
