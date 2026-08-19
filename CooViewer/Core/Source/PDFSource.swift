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
    private var poolGrowthDisabled = false
    private var storedPassword: String?
    private static let rendererPoolSize = 3

    private func acquireRenderer() -> (index: Int, renderer: PDFPageRenderer)? {
        // ロック中はレンダラーを作らない(解錠前の再試行でディスクを叩かない)
        guard !document.isLocked else { return nil }
        if let idle = rendererBusyCounts.indices.first(
            where: { rendererBusyCounts[$0] == 0 }) {
            rendererBusyCounts[idle] += 1
            return (idle, renderers[idle])
        }
        if !poolGrowthDisabled, renderers.count < Self.rendererPoolSize {
            // ページ数一致を検証してから採用する(開いた後にファイルが
            // 差し替えられた場合、entries()/見開き判定と食い違う描画を防ぐ)。
            // メモリ背景(暗号化親のネスト PDF)は共有 Data から再オープンし、
            // 平文を disk に置かずに並列レンダリングを保つ(cooViewer-6ax)
            let grown: PDFPageRenderer?
            if let sourceData {
                grown = PDFPageRenderer(data: sourceData, password: storedPassword,
                                        expectedPageCount: document.pageCount)
            } else {
                grown = PDFPageRenderer(url: url, password: storedPassword,
                                        expectedPageCount: document.pageCount)
            }
            if let renderer = grown {
                renderers.append(renderer)
                rendererBusyCounts.append(1)
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
        guard let (index, renderer) = await acquireRenderer() else {
            return try await renderWithMainDocument(
                entry: entry, maxPixelSize: maxPixelSize, pixelScale: nil)
        }
        do {
            let image = try await renderer.render(
                pageIndex: entry.id, name: entry.name,
                maxPixelSize: maxPixelSize, pixelScale: nil)
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
        guard let (index, renderer) = await acquireRenderer() else {
            return try await renderWithMainDocument(
                entry: entry, maxPixelSize: nil, pixelScale: capped)
        }
        do {
            let image = try await renderer.render(
                pageIndex: entry.id, name: entry.name,
                maxPixelSize: nil, pixelScale: capped)
            await releaseRenderer(index)
            return image
        } catch {
            await releaseRenderer(index)
            throw error
        }
    }

    /// プールが作れない場合の従来経路(メイン文書で直列レンダリング)
    private func renderWithMainDocument(entry: PageEntry, maxPixelSize: Int?,
                                        pixelScale: CGFloat?) throws -> CGImage {
        guard let page = document.page(at: entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return try Self.renderPage(page, name: entry.name,
                                   maxPixelSize: maxPixelSize, pixelScale: pixelScale)
    }

    /// ページ 1 枚のラスタライズ(呼び出し元の隔離内で同期実行される)
    nonisolated static func renderPage(_ page: PDFPage, name: String,
                                       maxPixelSize: Int?,
                                       pixelScale: CGFloat?) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotation = page.rotation
        let rotated = rotation % 180 != 0
        let pointSize = CGSize(
            width: rotated ? bounds.height : bounds.width,
            height: rotated ? bounds.width : bounds.height
        )

        // 表示用(maxPixelSize あり)はベクトルから 2 倍でラスタライズして
        // Retina でのぼやけを防ぐ(旧「ポイント原寸」§4.14 からの仕様変更)。
        // サムネイル等の小さい指定では従来どおり縮小になる。
        // maxPixelSize なし(原寸表示)はポイント原寸を維持する。
        var scale: CGFloat = pixelScale ?? 1.0
        if let maxPixelSize {
            let longSide = max(pointSize.width, pointSize.height)
            if longSide > 0 { scale = min(2.0, CGFloat(maxPixelSize) / longSide) }
        }
        let pixelWidth = max(1, Int(pointSize.width * scale))
        let pixelHeight = max(1, Int(pointSize.height * scale))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw BookSourceError.pageLoadFailed(name)
        }

        // 白背景(透過 PDF 対策。仕様書 §4.14)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw BookSourceError.pageLoadFailed(name)
        }
        return image
    }

    func isEncrypted() async -> Bool {
        document.isEncrypted && document.isLocked
    }

    /// 解錠後も「保護コンテンツを含む」ままにする(isEncrypted は解錠後
    /// false になるため。サムネイル/キャッシュのディスク素通り判定用。CWE-312)
    func containsProtectedContent() async -> Bool {
        document.isEncrypted
    }

    /// 旧実装には無かった PDF パスワード対応(改善)。
    func checkAndSetPassword(_ password: String) async -> Bool {
        let unlocked = document.unlock(withPassword: password)
        if unlocked {
            storedPassword = password  // プールのレンダラー作成時に引き継ぐ
        }
        return unlocked
    }
}

/// PDF ページのレンダラー(独立した PDFDocument を actor で直列化)。
/// PDFSource がプールとして複数持ち、ページ間の並列レンダリングを実現する
actor PDFPageRenderer {
    private let document: PDFDocument

    /// expectedPageCount: メイン文書のページ数。開いた後にファイルが差し替え
    /// られていた場合に、旧文書のエントリ列と食い違う内容を描かないための検証
    /// (ページ数が同じ差し替えまでは検出しない割り切り)
    init?(url: URL, password: String?, expectedPageCount: Int) {
        guard let document = PDFDocument(url: url) else { return nil }
        if let password {
            _ = document.unlock(withPassword: password)
        }
        guard !document.isLocked,
              document.pageCount == expectedPageCount else { return nil }
        self.document = document
    }

    /// メモリ背景版(暗号化親のネスト PDF。共有 Data から独立文書を開く。
    /// 平文を disk に置かずに並列レンダリングする。cooViewer-6ax)
    init?(data: Data, password: String?, expectedPageCount: Int) {
        guard let document = PDFDocument(data: data) else { return nil }
        if let password {
            _ = document.unlock(withPassword: password)
        }
        guard !document.isLocked,
              document.pageCount == expectedPageCount else { return nil }
        self.document = document
    }

    func render(pageIndex: Int, name: String,
                maxPixelSize: Int?, pixelScale: CGFloat?) throws -> CGImage {
        guard let page = document.page(at: pageIndex) else {
            throw BookSourceError.pageLoadFailed(name)
        }
        return try PDFSource.renderPage(page, name: name,
                                        maxPixelSize: maxPixelSize,
                                        pixelScale: pixelScale)
    }
}
