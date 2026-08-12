import Foundation

/// 事前リサンプル(次スプレッドの先行リサンプル)のページ数予算。
/// 上限は 5 ページ、ただし「1 ページの表示ピクセルサイズ × ページ数」が
/// メモリ予算(物理メモリの 1/32、最大 512MB)に収まる数まで。
/// 4K 超のディスプレイ等で 1 ページが大きい環境では自動的に減る。
/// 純関数(ReaderWindowController から使用。テスト対象)
enum PreresamplePolicy {
    /// 先行リサンプルするページ数の上限
    static let maxPages = 5

    /// メモリ予算(バイト)。物理メモリの 1/32、上限 512MB
    static func byteBudget(physicalMemory: UInt64) -> Int {
        min(512 << 20, Int(clamping: physicalMemory / 32))
    }

    /// bytesPerPage(表示ピクセルサイズの RGBA バイト数)から、予算内で
    /// 先行リサンプルしてよいページ数を返す(1...maxPages)
    static func pageBudget(bytesPerPage: Int, physicalMemory: UInt64) -> Int {
        guard bytesPerPage > 0 else { return 1 }
        let budget = byteBudget(physicalMemory: physicalMemory)
        return min(maxPages, max(1, budget / bytesPerPage))
    }
}
