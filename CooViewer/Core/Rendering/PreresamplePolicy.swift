import Foundation

/// 次スプレッドの事前リサンプル(先読み)の量を決めるポリシー(設計書 §5)。
/// ページ数の固定上限と、表示サイズ×枚数のメモリ予算の小さい方を採る。
/// 結果は ImageResampler の LRU に載るため、予算は LRU の上限
/// (物理メモリの 1/5・最大 12GB)より一回り小さくして、表示中スプレッド
/// やルーペ超解像を追い出さないようにする
enum PreresamplePolicy {
    /// 先行リサンプルするページ数の上限(メモリ予算が実質の上限で、
    /// これは小さすぎるページでの暴走を抑える保険)
    static let maxPages = 64

    /// 先行リサンプルの枚数上限(設計書 §5)。
    /// ML 品質(強/最高)は 1 ページ数秒の GPU / Neural Engine 計算のため、通常でも
    /// 次の 2 見開き(最大 4 ページ)に留める。省エネ時は次の見開きだけで、
    /// 非 ML は左右ペアの予測揺れを含め最大 4 ページ、ML は見開き 1 組ぶんの 2 ページ。
    static func pageLimit(usesML: Bool, conserveEnergy: Bool) -> Int {
        switch (usesML, conserveEnergy) {
        case (false, false): maxPages
        case (false, true), (true, false): 4
        case (true, true): 2
        }
    }

    /// 処理する見開きの数。省エネ時は次の見開きだけ、ML は 2 見開き、それ以外は予測の全部。
    static func spreadLimit(usesML: Bool, conserveEnergy: Bool) -> Int {
        if conserveEnergy { return 1 }
        return usesML ? 2 : maxPages
    }

    /// 実行計画。見開き数と枚数の両方の上限を守る(設計書 §5)。
    /// 見開きは分割しない: 枚数予算に収まらない見開きは片側だけ先読みせず丸ごと落として
    /// 打ち切る(Book.predictedAdjacentSpreads と同じ規則。片側だけ鮮明になるめくりを避ける)
    static func spreadsToProcess(_ predicted: [[Int]], usesML: Bool, conserveEnergy: Bool) -> [[Int]] {
        var remaining = pageLimit(usesML: usesML, conserveEnergy: conserveEnergy)
        return Array(predicted.prefix(spreadLimit(usesML: usesML, conserveEnergy: conserveEnergy))
            .prefix { spread in
                guard spread.count <= remaining else { return false }
                remaining -= spread.count
                return true
            })
    }

    /// メモリ予算(バイト)。物理メモリの 1/8、上限 4GB。
    /// 枚数を絞るときは予算も枚数 / 64 に比例させ、表示中ページの予算は変えない(設計書 §5)。
    /// メモリ圧迫中はリサンプル LRU の実効上限と同じ係数(1/2・1/4)で縮め、先読み結果が
    /// 下がった LRU に収まらず互いに追い出し合うのを防ぐ
    /// 既定値は持たない: 省略すると実際の先読み(ML・省エネで 4/2 ページ)と食い違う
    /// 計画を黙って作れてしまうため、呼び出し側に毎回明示させる
    static func byteBudget(physicalMemory: UInt64, usesML: Bool, conserveEnergy: Bool,
                           memoryPressure: MemoryPressureLevel) -> Int {
        let normal = min(4 << 30, Int(clamping: physicalMemory / 8))
        let scaled = normal / (maxPages / pageLimit(usesML: usesML, conserveEnergy: conserveEnergy))
        return MemoryBudgetPolicy.effectiveLimit(configured: scaled, level: memoryPressure)
    }

    /// bytesPerPage(表示ピクセルサイズの RGBA バイト数)から、予算内で
    /// 先行リサンプルしてよいページ数を返す(1...maxPages)
    static func pageBudget(bytesPerPage: Int, physicalMemory: UInt64,
                           usesML: Bool, conserveEnergy: Bool,
                           memoryPressure: MemoryPressureLevel) -> Int {
        guard bytesPerPage > 0 else { return 1 }
        let budget = byteBudget(physicalMemory: physicalMemory, usesML: usesML,
                                conserveEnergy: conserveEnergy, memoryPressure: memoryPressure)
        return min(pageLimit(usesML: usesML, conserveEnergy: conserveEnergy),
                   max(1, budget / bytesPerPage))
    }

    // MARK: - 実行可否(ウインドウの可視性・アプリの前面性)

    /// 事前リサンプルの実行モード(設計書 §5)。
    enum Mode: Equatable {
        /// ウインドウが見えていない(隠蔽・最小化・アプリ非表示): 始めず、進行中は次のページ境界で止める
        case paused
        /// 省エネ扱い(次の見開きだけ)。見えてはいるがアプリが非前面、または省エネ条件
        case conserving
        case normal
    }

    /// 可視でなければ常に停止。前面でない間は見えていても省エネ扱いにし、他アプリで
    /// 作業中の GPU / Neural Engine の長時間占有を避ける。
    static func mode(windowVisible: Bool, appActive: Bool, conserveEnergy: Bool) -> Mode {
        guard windowVisible else { return .paused }
        return conserveEnergy || !appActive ? .conserving : .normal
    }

    // MARK: - デコード先読み(PageCache 側)の深さ

    /// デコード先読み(進行方向)のページ数。
    /// 「リサンプル先読み+4」(事前リサンプルが常にデコード済みへ命中し、
    /// I/O と ML 計算が直列化しない深さ)と「PageCache 予算の 1/3 に収まる
    /// 深さ」(現スプレッド・戻り分・ルーペの余裕を残す)の大きい方を採り、
    /// 媒体別下限(SSD 12/HDD 16/ネットワーク 20)〜maxPages に丸める
    static func decodeAhead(resamplePages: Int, decodedPageBytes: Int,
                            pageCacheByteLimit: Int, mediaFloor: Int,
                            conserveEnergy: Bool = false) -> Int {
        let byBudget = decodedPageBytes > 0
            ? pageCacheByteLimit / 3 / decodedPageBytes : 0
        let wanted = max(resamplePages + 4, byBudget)
        let normal = min(maxPages, max(mediaFloor, wanted))
        return conserveEnergy ? max(2, normal / 2) : normal
    }

    /// デコード先読み(逆方向)。戻り読みの体感用に進行方向の 1/4(3...16)
    static func decodeBehind(ahead: Int) -> Int {
        min(16, max(3, ahead / 4))
    }
}
