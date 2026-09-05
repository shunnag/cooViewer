import CoreGraphics
import Foundation
import Washi

/// 固定レイアウト EPUB(日本の漫画配信の標準形)と、全 spine が単一画像の
/// リフロー EPUB を画像の本として読む(cooViewer-oxr.44)。
/// 電書協ガイドの FXL は「1 spine 項目 = 1 ページ = 画像 1 枚を敷く XHTML」
/// なので、Washi の単一画像ページ検出(simpleImagePath)で画像を直接取り出し、
/// 既存の画像パイプライン(先読み・ページカール・ルーペ・サムネイル)へ
/// そのまま流す。画像 1 枚に還元できない複雑なページのみ WebKit で
/// ラスタライズする(EPUBPageRasterizer)。
/// 通常のリフロー EPUB は本ソースの対象外(同じリーダーウインドウの EPUB
/// 表示モードが表示する。振り分けは ReaderWindowController.openBookFlow)。
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
    /// page-spread 由来の単ページ位置。初回要求時だけ全 spine を調べる。
    private var layoutSingleIndicesCache: Set<Int>?

    deinit {
        // ラスタライザプールの強参照を切る(cooViewer-o6e)。ObjectIdentifier は
        // Sendable なのでアクタ外の deinit から MainActor へ渡せる
        let key = ObjectIdentifier(publication)
        Task { @MainActor in FXLRasterizerPool.release(key) }
    }

    init(url: URL) throws {
        try self.init(publication: EPUBPublication(
            url: url, readStrategy: VolumeMappingPolicy.epubReadStrategy(for: url)), url: url)
    }

    /// メモリ上で開いた OCF を固定レイアウト本として受け取る。
    /// url はエラー表示・書名表示用で、publication の読み出し先ではない。
    init(publication: EPUBPublication, url: URL) throws {
        let imageOnlyPageInfos = publication.isFixedLayout
            ? nil : EPUBImageOnlyHeuristic.imageOnlyPageInfos(publication)
        try self.init(
            publication: publication, url: url,
            precomputedImageOnlyPageInfos: imageOnlyPageInfos)
    }

    /// 呼び出し側で画像のみ判定を済ませた経路。判定時のページ情報を引き継ぎ、
    /// XHTML を二度解析しない(cooViewer-oxr.44、設計書 §2.4)。
    init(publication: EPUBPublication, url: URL,
         precomputedImageOnlyPageInfos: [FixedLayoutPageInfo]?) throws {
        guard !publication.isDRMProtected else {
            throw BookSourceError.unreadable(url)
        }
        // 通常のリフローは専用リーダーへ送り、全 spine が単一画像の EPUB だけを
        // FXL と同じ画像パイプラインへ載せる(cooViewer-oxr.44)。
        guard publication.isFixedLayout
                || precomputedImageOnlyPageInfos != nil else {
            throw BookSourceError.unsupportedFormat(url)
        }
        self.url = url
        self.publication = publication
        if let precomputedImageOnlyPageInfos {
            self.pageInfoCache = Dictionary(uniqueKeysWithValues:
                precomputedImageOnlyPageInfos.map { ($0.spineIndex, $0) })
        }
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

    /// 画像のみ EPUB の判定で先読みされたページ情報数。
    /// 同一 Publication の振り分けと初期化で解析結果を共有できることの検証にも使う。
    var cachedPageInfoCount: Int { pageInfoCache.count }

    func layoutSinglePageIndices() async -> Set<Int> {
        if let layoutSingleIndicesCache { return layoutSingleIndicesCache }
        var slots: [PageSpreadSlot?] = []
        slots.reserveCapacity(publication.readingOrder.count)
        for entry in publication.readingOrder {
            slots.append(pageInfo(at: entry.spineIndex)?.pageSpread)
        }
        // cooViewer-oxr.36: page-spread の空きを置く側も、宣言省略を
        // 解決した実効方向へそろえる（設計書 §2.4）。
        let indices = EPUBSpreadHints.singleIndices(
            slots: slots, readingDirection: publication.effectiveReadingDirection)
        layoutSingleIndicesCache = indices
        return indices
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
        // 宣言省略の縦組みも Washi の解決結果で綴じ方向ヒントへ
        // 映す(cooViewer-oxr.36、設計書 §2.4)。
        info.manga = Self.mangaHint(for: publication)
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

    /// 宣言値だけでなく Kindle メタ・CSS 縦組み・言語まで
    /// 解決した実効方向を FXL の Manga ヒントに写す
    /// (cooViewer-oxr.36、設計書 §2.4)。
    static func mangaHint(for publication: EPUBPublication) -> ComicInfo.Manga {
        switch publication.effectiveReadingDirection {
        case .rtl: .yesAndRightToLeft
        case .ltr: .no
        case .byDefault: .no  // effective は default を返さないが将来の ABI へ防御
        @unknown default: .no
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
/// 参照を捨てるだけでは Washi の破棄契約を満たさないため、削除前に必ず
/// invalidate() を呼び、不可視の NSWindow と WebContent プロセスを畳む(cooViewer-oxr.43)。
@MainActor
private enum FXLRasterizerPool {
    private static var rasterizers: [ObjectIdentifier: EPUBPageRasterizer] = [:]

    /// ソース破棄時にラスタライザ(publication を強参照)を捨てる。in-memory で
    /// 開いた復号済み EPUB(暗号化祖先下、最大 256MiB)が書庫の寿命を越えて
    /// 常駐しないようにする(cooViewer-o6e)
    static func release(_ key: ObjectIdentifier) {
        rasterizers[key]?.invalidate()
        rasterizers[key] = nil
    }

    static func render(publication: EPUBPublication, spineIndex: Int,
                       maxPixelSize: Int?) async throws -> CGImage {
        let key = ObjectIdentifier(publication)
        let rasterizer: EPUBPageRasterizer
        if let existing = rasterizers[key] {
            rasterizer = existing
        } else {
            if rasterizers.count >= 2 {
                for rasterizer in rasterizers.values {
                    rasterizer.invalidate()
                }
                rasterizers.removeAll()
            }
            rasterizer = EPUBPageRasterizer(publication: publication)
            rasterizers[key] = rasterizer
        }
        return try await rasterizer.renderPage(atSpineIndex: spineIndex,
                                               maxPixelSize: maxPixelSize)
    }
}
