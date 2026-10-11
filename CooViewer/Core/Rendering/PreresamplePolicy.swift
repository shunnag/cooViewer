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

    /// 低電力時は次の見開きまで。左右ペアの予測揺れを含め最大 4 ページ(設計書 §5)。
    static func pageLimit(lowPowerMode: Bool) -> Int { lowPowerMode ? 4 : maxPages }

    /// 低電力時の実行計画は次の見開きだけに絞り、最大枚数も守る(設計書 §5)。
    static func spreadsToProcess(_ predicted: [[Int]], lowPowerMode: Bool) -> [[Int]] {
        guard lowPowerMode else { return predicted }
        return predicted.prefix(1).map { Array($0.prefix(pageLimit(lowPowerMode: true))) }
    }

    /// メモリ予算(バイト)。物理メモリの 1/8、上限 4GB。
    /// 低電力時は枚数 4/64 に比例させ、表示中ページの予算は変えない(設計書 §5)。
    static func byteBudget(physicalMemory: UInt64, lowPowerMode: Bool = false) -> Int {
        let normal = min(4 << 30, Int(clamping: physicalMemory / 8))
        return lowPowerMode ? normal / (maxPages / pageLimit(lowPowerMode: true)) : normal
    }

    /// bytesPerPage(表示ピクセルサイズの RGBA バイト数)から、予算内で
    /// 先行リサンプルしてよいページ数を返す(1...maxPages)
    static func pageBudget(bytesPerPage: Int, physicalMemory: UInt64,
                           lowPowerMode: Bool = false) -> Int {
        guard bytesPerPage > 0 else { return 1 }
        let budget = byteBudget(physicalMemory: physicalMemory, lowPowerMode: lowPowerMode)
        return min(pageLimit(lowPowerMode: lowPowerMode), max(1, budget / bytesPerPage))
    }

    // MARK: - デコード先読み(PageCache 側)の深さ

    /// デコード先読み(進行方向)のページ数。
    /// 「リサンプル先読み+4」(事前リサンプルが常にデコード済みへ命中し、
    /// I/O と ML 計算が直列化しない深さ)と「PageCache 予算の 1/3 に収まる
    /// 深さ」(現スプレッド・戻り分・ルーペの余裕を残す)の大きい方を採り、
    /// 媒体別下限(SSD 12/HDD 16/ネットワーク 20)〜maxPages に丸める
    static func decodeAhead(resamplePages: Int, decodedPageBytes: Int,
                            pageCacheByteLimit: Int, mediaFloor: Int,
                            lowPowerMode: Bool = false) -> Int {
        let byBudget = decodedPageBytes > 0
            ? pageCacheByteLimit / 3 / decodedPageBytes : 0
        let wanted = max(resamplePages + 4, byBudget)
        let normal = min(maxPages, max(mediaFloor, wanted))
        return lowPowerMode ? max(2, normal / 2) : normal
    }

    /// デコード先読み(逆方向)。戻り読みの体感用に進行方向の 1/4(3...16)
    static func decodeBehind(ahead: Int) -> Int {
        min(16, max(3, ahead / 4))
    }
}
