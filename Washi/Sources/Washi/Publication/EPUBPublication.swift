import CoreGraphics
import Foundation
import ImageIO

/// spine 1 項目ぶんの読書順エントリ(マニフェスト解決・パス解決済み)
public struct ReadingOrderItem: Sendable {
    /// readingOrder 配列内の添字(= Washi が言う「spine index」。linear="no" も含む)
    public let spineIndex: Int
    public let itemRef: SpineItemRef
    public let item: ManifestItem
    /// コンテナ内正規形パス
    public let containerPath: String
}

/// 見開き左右指定(FXL の itemref properties)
public enum PageSpreadSlot: String, Sendable {
    case left, right, center
}

/// 固定レイアウトページの情報
public struct FixedLayoutPageInfo: Sendable {
    public let spineIndex: Int
    /// viewport メタ(または SVG viewBox)由来のページ寸法(CSS px)
    public let viewportSize: CGSize?
    /// ページが「1 枚の画像を敷くだけ」の構造なら、その画像のコンテナ内パス。
    /// この場合 WebKit を介さず画像を直接デコードできる(日本の漫画 EPUB の
    /// 大多数がこの形)
    public let simpleImagePath: String?
    public let pageSpread: PageSpreadSlot?
}

/// EPUB 1 冊を表すファサード。
/// 開いた時点で OCF → パッケージ文書 → ナビゲーション → encryption.xml まで
/// 解析し、以後は不変(Sendable)。リソース読み出しは純関数でスレッド安全。
public final class EPUBPublication: Sendable {
    public let url: URL
    let container: OCFContainer
    public let package: EPUBPackage
    public let navigation: EPUBNavigation
    public let encryption: EPUBEncryptionInfo
    public let readingOrder: [ReadingOrderItem]
    /// コンテナ内パス → マニフェスト項目(メディアタイプ解決用)
    private let manifestByPath: [String: ManifestItem]

    /// .epub ファイルまたは展開済みフォルダを開く
    public convenience init(url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path,
                                             isDirectory: &isDirectory) else {
            throw EPUBError.notAnEPUB(url.path)
        }
        if isDirectory.boolValue {
            try self.init(url: url, reader: FolderContainerReader(rootURL: url))
        } else {
            let archive: ZipArchive
            do {
                archive = try ZipArchive(url: url)
            } catch {
                throw EPUBError.notAnEPUB("ZIP として読めない: \(error)")
            }
            try self.init(url: url, reader: ZipContainerReader(archive: archive))
        }
    }

    /// メモリ上の .epub データから開く(書庫内 EPUB 等)
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
    public var readingDirection: PageProgressionDirection {
        package.readingDirection
    }

    /// spine のコンテンツ文書が未知アルゴリズムで暗号化されている =
    /// 本物の DRM 保護で、Washi では開けない。
    /// フォント等の補助リソースだけが未知暗号の場合は「開ける」(そのフォントを
    /// 使わずに描画継続。EPUB 3.3 OCF §4.4.2 の許容)
    public var isDRMProtected: Bool {
        guard !encryption.unknownEncryptedResources.isEmpty else { return false }
        let spinePaths = Set(readingOrder.map(\.containerPath))
        return encryption.unknownEncryptedResources.keys
            .contains { spinePaths.contains($0) }
    }

    /// DRM 方式の推定(META-INF の指紋ファイルで判定)。DRM でなければ nil
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

    /// この本の spine index から idref 併記の位置を作る(保存用はこちらを使う)
    public func locator(forSpineIndex index: Int,
                        progression: Double = 0) -> EPUBLocator {
        EPUBLocator(spineIndex: index, progression: progression,
                    idref: readingOrder.indices.contains(index)
                        ? readingOrder[index].itemRef.idref : nil)
    }

    /// 保存済み位置をこの本へ突き合わせる。idref があれば spine の並べ替え・
    /// 増減(配信本の改版)を追跡して正しい項目へ写像し、該当 idref が
    /// 消えていれば nil(呼び出し側が「先頭から」等を決める)。
    /// idref のない旧形式は範囲内クランプのみ行う
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

    /// マニフェストのフォールバック連鎖(自身を先頭に、循環はそこで打ち切り。
    /// EPUB RS 3.3 §5.4)
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

    /// カバー画像のコンテナ内パス
    public var coverImagePath: String? {
        guard let item = package.coverImageItem else { return nil }
        return ContainerPath.resolve(base: package.path, href: item.href)
    }

    /// 表紙画像のコンテナ内パスをフォールバック連鎖で解決する(ライブラリ
    /// 一覧用途: 宣言のない実在本でもできるだけ表紙を出す):
    /// ① manifest properties="cover-image" / EPUB 2 meta name="cover"
    /// ② landmarks の epub:type="cover" が指す先(画像そのもの、または
    ///    文書内の唯一の画像)
    /// ③ id かファイル名に cover を含む manifest の画像アイテム
    /// ④ 先頭 spine 項目が「画像 1 枚だけのページ」ならその画像
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

    /// 表紙画像をデコードして返す(ImageIO のみ・WebKit/AppKit 不使用なので
    /// ヘッドレスの索引ツール等からも使える)。maxPixelSize を指定すると
    /// 長辺がそれ以下のサムネイルへ縮小する(EXIF 回転適用済み)。
    /// 表紙が解決できない・SVG 等デコード不能・DRM で読めない場合は nil
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

    // MARK: - リソース読み出し

    /// コンテナ内パスでリソースを読む。フォント難読化は透過的に解除する。
    /// 未知の暗号化がかかったリソースは drmProtected を投げる
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

    /// 基準パス + 相対 href でリソースを読む(ナビゲーション項目の解決等)
    public func resource(relativeTo basePath: String,
                         href: String) throws -> (data: Data, mediaType: String) {
        guard let path = ContainerPath.resolve(base: basePath, href: href) else {
            throw EPUBError.resourceNotFound(href)
        }
        return try resource(at: path)
    }

    /// href(基準パスからの相対)をコンテナ内パスへ解決する
    public func containerPath(forHref href: String,
                              relativeTo basePath: String) -> String? {
        ContainerPath.resolve(base: basePath, href: href)
    }

    /// ナビゲーション項目の href を読書順 spine index へ解決する
    public func spineIndex(forNavItem item: EPUBNavItem) -> Int? {
        guard let href = item.href,
              let path = ContainerPath.resolve(base: navigation.basePath,
                                               href: href) else { return nil }
        return readingOrder.firstIndex { $0.containerPath == path }
    }

    /// spine index が属する章の題(目次を平坦化し、その位置以前で最後の
    /// 項目を現在章とする)。柱(running head)表示用。該当なしは nil
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

    /// コンテナ内パスの存在確認
    public func resourceExists(at containerPath: String) -> Bool {
        container.reader.exists(ContainerPath.sanitize(containerPath))
    }

    // MARK: - 固定レイアウト

    /// FXL ページの構造情報(viewport・単一画像ページ判定・見開き指定)。
    /// リフロー本の spine 項目に対しても viewport なしの情報を返す
    public func fixedLayoutInfo(forSpineIndex index: Int) throws -> FixedLayoutPageInfo {
        guard readingOrder.indices.contains(index) else {
            throw EPUBError.resourceNotFound("spine index \(index)")
        }
        let entry = readingOrder[index]
        let spread: PageSpreadSlot?
        if entry.itemRef.properties.contains("page-spread-left") {
            spread = .left
        } else if entry.itemRef.properties.contains("page-spread-right") {
            spread = .right
        } else if entry.itemRef.properties.contains("rendition:page-spread-center") {
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

    private static func firstDescendant(_ localName: String,
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
