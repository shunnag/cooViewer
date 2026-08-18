import SwiftUI

/// 割当チップ列の折り返しレイアウト(行ごとに右寄せ)。
/// 1 機能に多数の入力を割り当てても行が横にあふれないようにする。
/// SwiftUI に標準のフローレイアウトが無いための最小実装
struct TrailingFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0
        var lines = 1
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                totalHeight += lineHeight + spacing
                maxLineWidth = max(maxLineWidth, lineWidth)
                lineWidth = 0
                lineHeight = 0
                lines += 1
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        maxLineWidth = max(maxLineWidth, lineWidth)
        totalHeight += lineHeight
        // 折り返したときは提案幅いっぱいを取り、1 行で収まるときは実幅だけ
        // 取る(HStack 内で Spacer が効くように)
        let width = lines > 1 ? (proposal.width ?? maxLineWidth) : maxLineWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var lineItems: [(view: LayoutSubviews.Element, size: CGSize)] = []
        var lineWidth: CGFloat = 0
        var y = bounds.minY

        func flushLine() {
            guard !lineItems.isEmpty else { return }
            let height = lineItems.map(\.size.height).max() ?? 0
            var x = bounds.maxX - lineWidth  // 右寄せ
            for item in lineItems {
                item.view.place(
                    at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                    proposal: .unspecified)
                x += item.size.width + spacing
            }
            y += height + spacing
            lineItems = []
            lineWidth = 0
        }

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > bounds.width {
                flushLine()
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
            lineItems.append((view, size))
        }
        flushLine()
    }
}
