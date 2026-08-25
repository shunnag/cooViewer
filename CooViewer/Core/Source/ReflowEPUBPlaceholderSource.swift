import CoreGraphics
import CoreText
import Foundation
import Washi

/// コレクション(フォルダの合本)内のリフロー EPUB を代表する 1 ページの
/// 代理ソース。リフローは動的ページ割りのため画像の本に混ぜられない —
/// 代わりに表紙 1 枚を「本の背表紙」として合本に置き、表示到達で
/// ReaderWindowController が EPUB モードへシームレスに切り替える
/// (設計書 §2.4 EPUB 対応。旧実装に対応物のない新機能)。
/// 表紙が取れない本は題名入りのタイトルカードを合成する
struct ReflowEPUBPlaceholderSource: BookSource {
    let url: URL
    private let publication: EPUBPublication

    var supportsDateSort: Bool { false }

    init(url: URL) throws {
        guard let publication = try? EPUBPublication(url: url) else {
            throw BookSourceError.unreadable(url)
        }
        // 固定レイアウトは EPUBSource(ページ統合)の担当
        guard !publication.isFixedLayout else {
            throw BookSourceError.unsupportedFormat(url)
        }
        self.url = url
        self.publication = publication
    }

    func entries() async throws -> [PageEntry] {
        [PageEntry(
            id: 0,
            name: url.lastPathComponent,
            pathInBook: url.lastPathComponent,
            fileURL: url,
            creationDate: nil,
            modificationDate: nil,
            reflowEPUBURL: url)]
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()
        // Washi のフォールバック連鎖(cover-image → EPUB2 meta → landmarks の
        // cover → cover を含む名前の画像)で表紙を解決する。宣言のない本でも
        // 実表紙が出る率が上がり、タイトルカード合成に落ちにくくなる
        if let cover = publication.coverImage(maxPixelSize: maxPixelSize) {
            return cover
        }
        return try Self.titleCard(
            title: publication.metadata.mainTitle ?? url.lastPathComponent,
            author: publication.metadata.creators.first?.value)
    }

    // MARK: - タイトルカード(表紙のない本の代役)

    /// 紙色の背景に題名(+著者)を描いた簡素な表紙を合成する
    private static func titleCard(title: String, author: String?) throws -> CGImage {
        let width = 900
        let height = 1350
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw BookSourceError.pageLoadFailed(title)
        }
        context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        context.setLineWidth(4)
        context.stroke(CGRect(x: 40, y: 40, width: width - 80, height: height - 80))

        func draw(_ text: String, fontSize: CGFloat, centerY: CGFloat) {
            let font = CTFontCreateWithName("HiraMinProN-W6" as CFString,
                                            fontSize, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: CGColor(gray: 0.2, alpha: 1),
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let maxSize = CGSize(width: CGFloat(width) - 160,
                                 height: CGFloat(height) / 3)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil, maxSize, nil)
            let rect = CGRect(
                x: (CGFloat(width) - size.width) / 2,
                y: centerY - size.height / 2,
                width: size.width, height: min(size.height, maxSize.height))
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
        }
        draw(title, fontSize: 64, centerY: CGFloat(height) * 0.62)
        if let author, !author.isEmpty {
            draw(author, fontSize: 40, centerY: CGFloat(height) * 0.35)
        }
        guard let image = context.makeImage() else {
            throw BookSourceError.pageLoadFailed(title)
        }
        return image
    }
}
