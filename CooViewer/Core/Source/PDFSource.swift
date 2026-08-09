import CoreGraphics
import Foundation
import PDFKit

/// PDF を本として読む(仕様書 §4.14)。
/// 旧実装の「全ページ共有 rep + setCurrentPage」と異なり、ページ毎に独立して
/// レンダリングする。PDFDocument はスレッド安全でないため actor で直列化する。
/// 描画特性(白背景・ポイント原寸)は旧実装を踏襲する。
/// EN: Reads a PDF as a book, rendering each page independently.
/// EN: PDFDocument is not thread-safe, hence the actor.
actor PDFSource: BookSource {
    nonisolated let url: URL
    private let document: PDFDocument

    nonisolated var supportsDateSort: Bool { false }

    init(url: URL) throws {
        self.url = url
        guard let document = PDFDocument(url: url) else {
            throw BookSourceError.unreadable(url)
        }
        self.document = document
    }

    func entries() async throws -> [PageEntry] {
        // ロック解除前は pageCount が 0 になるため、毎回計算する
        // EN: pageCount is 0 before unlock, so recompute on every call.
        (0..<document.pageCount).map { index in
            PageEntry(
                id: index,
                name: String(localized: "Page \(index + 1)"),
                // 全ページ同一フォルダ扱い(仕様書 §4.3.5)。0 埋めで名前順=ページ順を保つ
                // EN: Zero-padded pseudo path keeps name order == page order.
                pathInBook: String(format: "%06d", index),
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            )
        }
    }

    /// ページ寸法(ポイント。回転適用後)。見開き判定は縦横比だけを使うので
    /// ピクセルでなくポイントで十分
    /// EN: Page bounds in points (rotation applied); pairing only needs the
    /// EN: aspect ratio, so points are fine.
    func imageSize(for entry: PageEntry) async -> CGSize? {
        guard let page = document.page(at: entry.id) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        return CGSize(width: rotated ? bounds.height : bounds.width,
                      height: rotated ? bounds.width : bounds.height)
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        return try render(entry: entry, maxPixelSize: maxPixelSize, pixelScale: nil)
    }

    /// ルーペ用: ベクトルから倍率連動でラスタライズする(設計書 §5 描画品質)。
    /// 通常表示の 2 倍キャップとは独立で、非使用時のコストに影響しない。
    /// EN: Loupe path re-rasterizes from vector at the requested scale (max 6x).
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        try render(entry: entry, maxPixelSize: nil, pixelScale: min(pixelScale, 6.0))
    }

    private func render(entry: PageEntry, maxPixelSize: Int?,
                        pixelScale: CGFloat?) throws -> CGImage {
        guard let page = document.page(at: entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
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
        // EN: Display renders at up to 2x from vector to stay sharp on Retina;
        // EN: no maxPixelSize (actual-size view) keeps 1 point = 1 pixel.
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
            throw BookSourceError.pageLoadFailed(entry.name)
        }

        // 白背景(透過 PDF 対策。仕様書 §4.14)
        // EN: White background so transparent PDFs stay readable.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return image
    }

    func isEncrypted() async -> Bool {
        document.isEncrypted && document.isLocked
    }

    /// 旧実装には無かった PDF パスワード対応(改善)。
    /// EN: PDF password support (an improvement over the legacy app).
    func checkAndSetPassword(_ password: String) async -> Bool {
        document.unlock(withPassword: password)
    }
}
