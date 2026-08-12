import Foundation

/// 次スプレッドの事前リサンプル(先読み)の量を決めるポリシー(設計書 §5)。
/// ページ数の固定上限と、表示サイズ×枚数のメモリ予算の小さい方を採る。
/// 結果は ImageResampler の LRU に載るため、予算は LRU の上限
/// (物理メモリの 1/6・最大 4.5GB)より一回り小さくして、表示中スプレッド
/// やルーペ超解像を追い出さないようにする
enum PreresamplePolicy {
    /// 先行リサンプルするページ数の上限(メモリ予算が実質の上限で、
    /// これは小さすぎるページでの暴走を抑える保険)
    static let maxPages = 64

    /// メモリ予算(バイト)。物理メモリの 1/8、上限 4GB
    static func byteBudget(physicalMemory: UInt64) -> Int {
        min(4 << 30, Int(clamping: physicalMemory / 8))
    }

    /// bytesPerPage(表示ピクセルサイズの RGBA バイト数)から、予算内で
    /// 先行リサンプルしてよいページ数を返す(1...maxPages)
    static func pageBudget(bytesPerPage: Int, physicalMemory: UInt64) -> Int {
        guard bytesPerPage > 0 else { return 1 }
        let budget = byteBudget(physicalMemory: physicalMemory)
        return min(maxPages, max(1, budget / bytesPerPage))
    }
}
