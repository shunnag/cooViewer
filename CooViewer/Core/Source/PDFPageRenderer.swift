import CoreGraphics
import Foundation
import PDFKit

/// 文書内部の画像キャッシュも世代ごとに捨てる(設計書 §5)。
actor PDFPageRenderer {
    static let distinctPageLimit = 8

    struct Statistics: Sendable, Equatable {
        let distinctPageCount: Int
        let recycleCount: Int
        let recycleFailureCount: Int
    }

    private enum Input: Sendable {
        case file(URL)
        case memory(Data)

        func open(password: String?, expectedPageCount: Int) -> PDFDocument? {
            let document: PDFDocument?
            switch self {
            case .file(let url): document = PDFDocument(url: url)
            case .memory(let data): document = PDFDocument(data: data)
            }
            guard let document else { return nil }
            if let password { _ = document.unlock(withPassword: password) }
            guard !document.isLocked,
                  document.pageCount == expectedPageCount else { return nil }
            return document
        }
    }

    private var document: PDFDocument
    private let input: Input
    // 解錠済みソースと同じ読書セッション内だけ保持する。保管庫の保存同意は変えない(設計書 §2.4)。
    private let password: String?
    private let expectedPageCount: Int
    private var renderedPages: Set<Int> = []
    private var lastPageIndex: Int?
    private var recycleCount = 0
    private var recycleFailureCount = 0

    init?(url: URL, password: String?, expectedPageCount: Int) {
        self.init(input: .file(url), password: password,
                  expectedPageCount: expectedPageCount)
    }

    init?(data: Data, password: String?, expectedPageCount: Int) {
        self.init(input: .memory(data), password: password,
                  expectedPageCount: expectedPageCount)
    }

    private init?(input: Input, password: String?, expectedPageCount: Int) {
        guard let document = autoreleasepool(invoking: {
            input.open(password: password, expectedPageCount: expectedPageCount)
        }) else { return nil }
        self.document = document
        self.input = input
        self.password = password
        self.expectedPageCount = expectedPageCount
    }

    func statistics() -> Statistics {
        Statistics(distinctPageCount: renderedPages.count, recycleCount: recycleCount,
                   recycleFailureCount: recycleFailureCount)
    }

    func render(pageIndex: Int, name: String,
                maxPixelSize: Int?, pixelScale: CGFloat?) throws -> CGImage {
        try Task.checkCancellation()
        // 描画の途中では交換せず、直前のページはルーペ用に温存する(設計書 §5)。
        // 自動解放された PDFPage が旧文書を延命しないよう、描画単位で排出する。
        return try autoreleasepool {
            if pageIndex != lastPageIndex, renderedPages.count >= Self.distinctPageLimit,
               (0..<expectedPageCount).contains(pageIndex) {
                if let replacement = input.open(password: password,
                                                 expectedPageCount: expectedPageCount) {
                    document = replacement
                    renderedPages.removeAll(keepingCapacity: true)
                    recycleCount += 1
                } else {
                    // 再生成失敗はプールの成長停止と独立。旧文書で読み続ける(設計書 §7.4)。
                    recycleFailureCount += 1
                }
            }
            guard let page = document.page(at: pageIndex) else {
                throw BookSourceError.pageLoadFailed(name)
            }
            renderedPages.insert(pageIndex)
            lastPageIndex = pageIndex
            return try Self.renderPage(page, name: name, maxPixelSize: maxPixelSize,
                                       pixelScale: pixelScale)
        }
    }

    /// 呼び出し元の隔離内で描画し、白背景と倍率の規則を共通にする(設計書 §5)。
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
}
