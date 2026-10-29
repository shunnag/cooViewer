import CoreGraphics
import Foundation
import PDFKit

/// PDF を本として読む(仕様書 §4.14)。
/// 旧実装の「全ページ共有 rep + setCurrentPage」と異なり、ページ毎に独立して
/// レンダリングする。PDFDocument はスレッド安全でないため actor で直列化する。
/// 描画特性(白背景・ポイント原寸)は旧実装を踏襲する。
actor PDFSource: BookSource {
    nonisolated let url: URL
    private let document: PDFDocument
    /// メモリ背景(暗号化親のネスト PDF)。非 nil のとき disk を読まず、
    /// レンダラープールもこの共有 Data から再オープンする(平文を temp に置かない)
    private let sourceData: Data?

    nonisolated var supportsDateSort: Bool { false }

    init(url: URL) throws {
        self.url = url
        self.sourceData = nil
        guard FileDescriptorHeadroom.isAvailable() else {
            throw BookSourceError.temporarilyUnavailable(url)
        }
        guard let document = PDFDocument(url: url) else {
            throw BookSourceError.unreadable(url)
        }
        self.document = document
    }

    /// 暗号化親のネスト PDF をメモリから開く(復号済みバイトを disk に置かない。
    /// cooViewer-6ax)。合成 url は識別用のみで disk は決して読まない
    init(data: Data) throws {
        self.url = URL(fileURLWithPath: "in-memory.pdf")
        self.sourceData = data
        guard let document = PDFDocument(data: data) else {
            throw BookSourceError.unreadable(url)
        }
        self.document = document
    }

    /// PDF 自身のメタデータ(文書属性 + アウトライン)を ComicInfo へ合成して返す
    /// (cooViewer-oo6)。暗号化 PDF は解錠後のみ意味のある値になる(未解錠は nil)
    func metadata() async -> ComicInfo? {
        ComicInfo.from(pdf: document)
    }

    func entries() async throws -> [PageEntry] {
        // ロック解除前は pageCount が 0 になるため、毎回計算する
        (0..<document.pageCount).map { index in
            PageEntry(
                id: index,
                name: String(localized: "Page \(index + 1)"),
                // 全ページ同一フォルダ扱い(仕様書 §4.3.5)。0 埋めで名前順=ページ順を保つ
                pathInBook: String(format: "%06d", index),
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            )
        }
    }

    /// ページ寸法(ポイント。回転適用後)。見開き判定は縦横比だけを使うので
    /// ピクセルでなくポイントで十分
    func imageSize(for entry: PageEntry) async -> CGSize? {
        guard let page = document.page(at: entry.id) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        return CGSize(width: rotated ? bounds.height : bounds.width,
                      height: rotated ? bounds.width : bounds.height)
    }

    /// レンダラープール(PDFDocument は非スレッド安全なので actor 毎に独立の
    /// 文書を持たせ、先読みをページ間で並列化する。最大 3)。
    /// 空きレンダラーの再利用が最優先で、**全員使用中のときだけ**成長する:
    /// 直列読み(HDD プロファイル等)では 1 つのままで、余計な文書再オープンや
    /// メモリ消費をしない。作成失敗(差し替え・削除)やページ数不一致は成長を
    /// 恒久停止してメイン文書の直列描画に戻す(改稿前と同じ挙動)
    private var renderers: [PDFPageRenderer] = []
    private var rendererBusyCounts: [Int] = []
    private var rendererPages: [Int] = []
    private var poolGrowthDisabled = false
    private var storedPassword: String?
    private static let rendererPoolSize = 3

    // 同時に届いたサムネイルを一群とし、最後の要求が終われば文書を捨てる(設計書 §5)。
    private var thumbnailRenderer: PDFPageRenderer?
    private var thumbnailBusyCount = 0
    private var thumbnailBatchCount = 0

    private func makeRenderer() -> PDFPageRenderer? {
        if let sourceData {
            return PDFPageRenderer(data: sourceData, password: storedPassword,
                                   expectedPageCount: document.pageCount)
        }
        return PDFPageRenderer(url: url, password: storedPassword,
                               expectedPageCount: document.pageCount)
    }

    private func acquireRenderer(pageIndex: Int) -> (index: Int, renderer: PDFPageRenderer)? {
        // ロック中はレンダラーを作らない(解錠前の再試行でディスクを叩かない)
        guard !document.isLocked else { return nil }
        // 直前に同じページを受け持った文書を優先し、ルーペの再復号を避ける(設計書 §5)。
        if let warm = rendererPages.firstIndex(of: pageIndex) {
            rendererBusyCounts[warm] += 1
            return (warm, renderers[warm])
        }
        if let idle = rendererBusyCounts.indices.first(
            where: { rendererBusyCounts[$0] == 0 }) {
            rendererBusyCounts[idle] += 1
            rendererPages[idle] = pageIndex
            return (idle, renderers[idle])
        }
        if !poolGrowthDisabled, renderers.count < Self.rendererPoolSize {
            // ページ数一致を検証してから採用する(開いた後にファイルが
            // 差し替えられた場合、entries()/見開き判定と食い違う描画を防ぐ)。
            // メモリ背景(暗号化親のネスト PDF)は共有 Data から再オープンし、
            // 平文を disk に置かずに並列レンダリングを保つ(cooViewer-6ax)
            if let renderer = makeRenderer() {
                renderers.append(renderer)
                rendererBusyCounts.append(1)
                rendererPages.append(pageIndex)
                return (renderers.count - 1, renderer)
            }
            poolGrowthDisabled = true
        }
        guard !renderers.isEmpty else { return nil }
        // 上限到達(または成長不能)時はいちばん空いているレンダラーに相乗り
        var index = 0
        for i in rendererBusyCounts.indices
            where rendererBusyCounts[i] < rendererBusyCounts[index] { index = i }
        rendererBusyCounts[index] += 1
        rendererPages[index] = pageIndex
        return (index, renderers[index])
    }

    private func releaseRenderer(_ index: Int) {
        if rendererBusyCounts.indices.contains(index) {
            rendererBusyCounts[index] -= 1
        }
    }

    /// プールがある限り並列レンダリング可能。
    /// 宣言を要件と同じ async にしてある: 同期宣言だと async 文脈の直接呼び出しが
    /// 「async 優先」規則でプロトコル拡張の既定実装(false)に解決されてしまう
    func currentlySupportsParallelPageLoads() async -> Bool {
        !(poolGrowthDisabled && renderers.isEmpty)
    }

    nonisolated func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        if PageRequestIntent.isThumbnail {
            return try await thumbnailImage(for: entry, maxPixelSize: maxPixelSize)
        }
        guard let (index, renderer) = await acquireRenderer(pageIndex: entry.id) else {
            return try await renderWithMainDocument(
                entry: entry, maxPixelSize: maxPixelSize, pixelScale: nil,
                displayColorTarget: PageRequestIntent.displayColorTarget)
        }
        do {
            let image = try await renderer.render(
                pageIndex: entry.id, name: entry.name,
                maxPixelSize: maxPixelSize, pixelScale: nil,
                displayColorTarget: PageRequestIntent.displayColorTarget)
            await releaseRenderer(index)
            return image
        } catch {
            await releaseRenderer(index)
            throw error
        }
    }

    /// ルーペ用: ベクトルから倍率連動でラスタライズする(設計書 §5 描画品質)。
    /// 通常表示の 2 倍キャップとは独立で、非使用時のコストに影響しない。
    nonisolated func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        let capped = min(pixelScale, 6.0)
        guard let (index, renderer) = await acquireRenderer(pageIndex: entry.id) else {
            return try await renderWithMainDocument(
                entry: entry, maxPixelSize: nil, pixelScale: capped,
                displayColorTarget: PageRequestIntent.displayColorTarget)
        }
        do {
            let image = try await renderer.render(
                pageIndex: entry.id, name: entry.name,
                maxPixelSize: nil, pixelScale: capped,
                displayColorTarget: PageRequestIntent.displayColorTarget)
            await releaseRenderer(index)
            return image
        } catch {
            await releaseRenderer(index)
            throw error
        }
    }

    private func acquireThumbnailRenderer() -> PDFPageRenderer? {
        guard !document.isLocked else { return nil }
        if thumbnailRenderer == nil {
            thumbnailRenderer = makeRenderer()
            if thumbnailRenderer != nil { thumbnailBatchCount += 1 }
        }
        guard let thumbnailRenderer else { return nil }
        thumbnailBusyCount += 1
        return thumbnailRenderer
    }

    private func releaseThumbnailRenderer() {
        thumbnailBusyCount -= 1
        if thumbnailBusyCount == 0 { thumbnailRenderer = nil }
    }

    private nonisolated func thumbnailImage(for entry: PageEntry,
                                            maxPixelSize: Int?) async throws -> CGImage {
        guard let renderer = await acquireThumbnailRenderer() else {
            return try await renderWithMainDocument(
                entry: entry, maxPixelSize: maxPixelSize, pixelScale: nil)
        }
        do {
            let image = try await renderer.render(pageIndex: entry.id, name: entry.name,
                                                  maxPixelSize: maxPixelSize, pixelScale: nil)
            await releaseThumbnailRenderer()
            return image
        } catch {
            await releaseThumbnailRenderer()
            throw error
        }
    }

    /// 検証用。用途別の寿命と、表示文書の再生成を観測する(設計書 §7.6)。
    func debugRendererStatistics() async -> (display: [PDFPageRenderer.Statistics],
                                            thumbnailBatches: Int, thumbnailActive: Bool) {
        var display: [PDFPageRenderer.Statistics] = []
        for renderer in renderers { display.append(await renderer.statistics()) }
        return (display, thumbnailBatchCount, thumbnailRenderer != nil)
    }

    /// プールが作れない場合の従来経路(メイン文書で直列レンダリング)
    private func renderWithMainDocument(entry: PageEntry, maxPixelSize: Int?,
                                        pixelScale: CGFloat?,
                                        displayColorTarget: DisplayColorTarget? = nil) throws -> CGImage {
        guard let page = document.page(at: entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return try PDFPageRenderer.renderPage(page, name: entry.name,
                                               maxPixelSize: maxPixelSize, pixelScale: pixelScale,
                                               displayColorTarget: displayColorTarget)
    }

    func isEncrypted() async -> Bool {
        document.isEncrypted && document.isLocked
    }

    /// 解錠後も「保護コンテンツを含む」ままにする(isEncrypted は解錠後
    /// false になるため。サムネイル/キャッシュのディスク素通り判定用。CWE-312)
    func containsProtectedContent() async -> Bool {
        document.isEncrypted
    }

    /// 旧実装には無かった PDF パスワード対応(改善)。PDFKit の unlock は正否しか
    /// 返さないため、読み取り失敗の区別(unreadable)はない
    func checkAndSetPassword(_ password: String) async -> PasswordCheck {
        let unlocked = document.unlock(withPassword: password)
        if unlocked {
            storedPassword = password  // プールのレンダラー作成時に引き継ぐ
        }
        return unlocked ? .accepted : .rejected
    }
}
