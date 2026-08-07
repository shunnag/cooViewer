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

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try render(entry: entry, maxPixelSize: maxPixelSize, pixelScale: nil)
    }

    /// ルーペ用: ベクトルから倍率連動でラスタライズする(設計書 §5 描画品質)。
    /// 通常表示の 2 倍キャップとは独立で、非使用時のコストに影響しない。
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
    func checkAndSetPassword(_ password: String) async -> Bool {
        document.unlock(withPassword: password)
    }
}
