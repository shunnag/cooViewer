import CoreGraphics
import Foundation
import Washi

/// 固定レイアウト EPUB(日本の漫画配信の標準形)を本として読む。
/// 電書協ガイドの FXL は「1 spine 項目 = 1 ページ = 画像 1 枚を敷く XHTML」
/// なので、Washi の単一画像ページ検出(simpleImagePath)で画像を直接取り出し、
/// 既存の画像パイプライン(先読み・ページカール・ルーペ・サムネイル)へ
/// そのまま流す。画像 1 枚に還元できない複雑なページのみ WebKit で
/// ラスタライズする(EPUBPageRasterizer)。
/// リフロー EPUB は本ソースの対象外(同じリーダーウインドウの EPUB 表示
/// モードが表示する。振り分けは ReaderWindowController.openBookFlow)。
///
/// actor なのはページ情報(viewport・画像パス)のキャッシュを守るためだけで、
/// 画像デコード自体は nonisolated で並列に走る(EPUBPublication は不変・
/// スレッド安全)
actor EPUBSource: BookSource {
    nonisolated let url: URL
    nonisolated let publication: EPUBPublication
    nonisolated var supportsDateSort: Bool { false }
    nonisolated var supportsParallelPageLoads: Bool { true }

    /// spine index → 解析済みページ情報のキャッシュ
    private var pageInfoCache: [Int: FixedLayoutPageInfo] = [:]

    init(url: URL) throws {
        let publication = try EPUBPublication(url: url)
        guard !publication.isDRMProtected else {
            throw BookSourceError.unreadable(url)
        }
        // リフローは画像の本として扱えない(呼び出し側で専用リーダーへ
        // 振り分け済みのはずだが、事前スプール等の別経路の安全網)
        guard publication.isFixedLayout else {
            throw BookSourceError.unsupportedFormat(url)
        }
        self.url = url
        self.publication = publication
    }

    func entries() async throws -> [PageEntry] {
        publication.readingOrder.map { entry in
            PageEntry(
                id: entry.spineIndex,
                name: (entry.containerPath as NSString).lastPathComponent,
                // 0 埋め擬似パスで名前順=spine 順を保つ(PDFSource と同じ手法)
                pathInBook: String(format: "%06d", entry.spineIndex),
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            )
        }
    }

    private func pageInfo(at index: Int) -> FixedLayoutPageInfo? {
        if let cached = pageInfoCache[index] { return cached }
        guard let info = try? publication.fixedLayoutInfo(forSpineIndex: index) else {
            return nil
        }
        pageInfoCache[index] = info
        return info
    }

    /// 見開き判定用の寸法。viewport メタが最速(XHTML 解析のみ)。
    /// 無ければ画像ヘッダから読む
    func imageSize(for entry: PageEntry) async -> CGSize? {
        guard let info = pageInfo(at: entry.id) else { return nil }
        if let viewport = info.viewportSize { return viewport }
        guard let imagePath = info.simpleImagePath,
              let (data, _) = try? publication.resource(at: imagePath) else {
            return nil
        }
        return ImageDecoding.imageSize(from: data)
    }

    nonisolated func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()
        guard let info = await pageInfo(at: entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        if let imagePath = info.simpleImagePath {
            let (data, _) = try publication.resource(at: imagePath)
            return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
        }
        // 複雑ページ(テキスト・SVG 合成)は WebKit でラスタライズ
        return try await FXLRasterizerPool.render(
            publication: publication, spineIndex: entry.id,
            maxPixelSize: maxPixelSize)
    }

    /// アニメーション画像(GIF/APNG が EPUB 内画像のこともある)を活かすため
    /// 元データを返す
    nonisolated func imageData(for entry: PageEntry) async -> Data? {
        guard let info = await pageInfo(at: entry.id),
              let imagePath = info.simpleImagePath else { return nil }
        return try? publication.resource(at: imagePath).data
    }

    /// EPUB メタデータ → ComicInfo ヒント(適用側の規則は ComicInfo と同じ:
    /// ユーザー設定は上書きしない)
    func metadata() async -> ComicInfo? {
        let metadata = publication.metadata
        var info = ComicInfo()
        info.title = metadata.mainTitle
        if let series = metadata.collections.first(where: { $0.type == "series" })
            ?? metadata.collections.first {
            info.series = series.name
            info.number = series.groupPosition
        }
        info.writer = metadata.creators.first { $0.role == "aut" }?.value
            ?? metadata.creators.first?.value
        info.publisher = metadata.publishers.first
        info.summary = metadata.description
        info.languageISO = metadata.languages.first
        info.pageCount = publication.readingOrder.count
        // 綴じ方向の表明は読み方向ヒントへ(ComicInfo の Manga と同じ扱い)
        if let hint = Self.mangaHint(for: publication.readingDirection) {
            info.manga = hint
        }
        // 目次 → 章ブックマーク(サムネイルの章ナビに使われる)
        var pages: [ComicInfo.PageInfo] = []
        for item in publication.navigation.toc {
            guard let index = publication.spineIndex(forNavItem: item),
                  !item.title.isEmpty else { continue }
            pages.append(ComicInfo.PageInfo(image: index, bookmark: item.title))
        }
        info.pages = pages
        return info.isEmpty ? nil : info
    }

    /// 綴じ方向表明 → ComicInfo ヒント。明示 ltr も対称に写す(リフローは
    /// 無条件採用するのに FXL だけ ltr を落とすと switchAction の入替が
    /// 同じ本で食い違う)。属性省略(default)はヒント無し(.unknown のまま)
    static func mangaHint(for direction: PageProgressionDirection)
        -> ComicInfo.Manga? {
        switch direction {
        case .rtl: .yesAndRightToLeft
        case .ltr: .no
        case .byDefault: nil
        @unknown default: nil
        }
    }
}

extension ComicInfo {
    /// 何のヒントも持たないか(EPUBSource が nil を返す判定用)
    var isEmpty: Bool {
        self == ComicInfo()
    }
}

/// 複雑 FXL ページ用ラスタライザの MainActor プール。
/// WKWebView を抱えるため、直近の本以外は捨てて溜め込まない
@MainActor
private enum FXLRasterizerPool {
    private static var rasterizers: [ObjectIdentifier: EPUBPageRasterizer] = [:]

    static func render(publication: EPUBPublication, spineIndex: Int,
                       maxPixelSize: Int?) async throws -> CGImage {
        let key = ObjectIdentifier(publication)
        let rasterizer: EPUBPageRasterizer
        if let existing = rasterizers[key] {
            rasterizer = existing
        } else {
            if rasterizers.count >= 2 { rasterizers.removeAll() }
            rasterizer = EPUBPageRasterizer(publication: publication)
            rasterizers[key] = rasterizer
        }
        return try await rasterizer.renderPage(atSpineIndex: spineIndex,
                                               maxPixelSize: maxPixelSize)
    }
}
