import AppKit

/// 実行時に生成する多言語対応のプレースホルダ画像。
/// 旧 broken.png(固定画像・文言なし)の置き換えで、理由をページ上に表示する。
@MainActor
enum PlaceholderImage {
    /// 警告記号+メッセージ入りの縦長ページ画像を作る。
    static func make(text: String,
                     size: CGSize = CGSize(width: 700, height: 1000)) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        NSColor(white: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let message = NSMutableAttributedString()
        message.append(NSAttributedString(string: "⚠\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 96),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
            .paragraphStyle: paragraph,
        ]))
        message.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .medium),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
            .paragraphStyle: paragraph,
        ]))

        let inset: CGFloat = 60
        let bounds = NSRect(x: inset, y: 0, width: size.width - inset * 2, height: size.height)
        let textHeight = message.boundingRect(
            with: NSSize(width: bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).height
        let textRect = NSRect(x: bounds.minX,
                              y: (size.height - textHeight) / 2,
                              width: bounds.width, height: textHeight)
        message.draw(with: textRect, options: [.usesLineFragmentOrigin])

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
