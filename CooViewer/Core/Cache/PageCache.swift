import CoreGraphics
import Foundation

/// デコード済みページ画像の LRU キャッシュ(仕様書 §4.5.1 の cacheArray に相当)。
/// 旧実装の「枚数基準(設定値+4)」を廃し、バイト基準で管理する
/// (設計書「キャッシュ・先読み設計」)。メモリ圧迫の段階に応じて実効上限を下げ、
/// normal に戻るまで保つ(設計書 §5)。
/// Book が単独所有するメモリ索引なので同じ MainActor に置く。
/// 取得・失効・読み込み登録の間に await を挟まず、設定変更との競合を防ぐ(設計書 §7.3)。
@MainActor
final class PageCache {
    /// 表示先が異なる縮小復号結果を混ぜない。未指定は表示非依存の画像用(設計書 §5)。
    private struct Key: Hashable {
        let id: Int
        let colorSpaceIdentity: String
    }
    private var storage: [Key: CGImage] = [:]
    private var order: [Key] = []  // 末尾が最新(MRU)
    private var costs: [Key: Int] = [:]
    private var totalCost = 0
    /// 設定上の上限(高度設定の明示値はここに入る)。圧迫中もこれは変えない
    private(set) var configuredByteLimit: Int
    /// 実効上限 = MemoryBudgetPolicy(configured, 圧迫段階)。先読み計画もこれを読む
    private(set) var byteLimit: Int
    /// 最後に適用した圧迫段階(設定上の上限を変えても実効上限に掛け続ける)
    private var pressureLevel: MemoryPressureLevel
    private let pressureObservation: MemoryPressureObservation

    init(byteLimit: Int,
         pressure: any MemoryPressureProviding = MemoryPressureMonitor.shared,
         center: NotificationCenter = .default) {
        configuredByteLimit = max(1, byteLimit)
        // 圧迫中に開いた本は最初から下げた上限で始める
        pressureLevel = pressure.memoryPressureLevel
        self.byteLimit = MemoryBudgetPolicy.effectiveLimit(
            configured: configuredByteLimit, level: pressureLevel)
        let observation = MemoryPressureObservation(center: center)
        pressureObservation = observation
        // 通知は圧迫源の utility キューで届くので MainActor へ跳び、跳んだ後に現在値を読む
        observation.setHandler({ [weak self] provider in
            Task { @MainActor in self?.applyMemoryPressure(provider.memoryPressureLevel) }
        }, provider: pressure)
    }

    /// 明示設定は設定上の上限を定めるだけで、圧迫中なら実効上限は引き続き下がる(設計書 §5)
    func setByteLimit(_ newLimit: Int) {
        configuredByteLimit = max(1, newLimit)
        byteLimit = MemoryBudgetPolicy.effectiveLimit(configured: configuredByteLimit, level: pressureLevel)
        evictIfNeeded()
    }

    /// 圧迫段階の変化: 実効上限を置き直し、下げたときはそこまで追い出す。
    /// normal への復帰は上限を戻すだけで埋め直さない(先読みが順次埋める。設計書 §5)
    func applyMemoryPressure(_ level: MemoryPressureLevel) {
        pressureLevel = level
        byteLimit = MemoryBudgetPolicy.effectiveLimit(configured: configuredByteLimit, level: level)
        if level != .normal { evictIfNeeded() }
    }

    func image(for id: Int, colorSpaceIdentity: String = "source") -> CGImage? {
        let id = Key(id: id, colorSpaceIdentity: colorSpaceIdentity)
        guard let image = storage[id] else { return nil }
        // ヒット時は MRU へ移動(仕様書 §4.5.1)
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
            order.append(id)
        }
        return image
    }

    func insert(_ image: CGImage, for id: Int, colorSpaceIdentity: String = "source") {
        let id = Key(id: id, colorSpaceIdentity: colorSpaceIdentity)
        removeEntry(id)
        let cost = image.bytesPerRow * image.height
        storage[id] = image
        costs[id] = cost
        totalCost += cost
        order.append(id)
        evictIfNeeded()
    }

    func removeAll() {
        storage.removeAll()
        costs.removeAll()
        order.removeAll()
        totalCost = 0
    }

    /// 設計書 §5: 距離判定の走査では LRU を温めず、完成画像で代替できる入力だけを解放する。
    func contains(_ id: Int, colorSpaceIdentity: String = "source") -> Bool {
        storage[Key(id: id, colorSpaceIdentity: colorSpaceIdentity)] != nil
    }

    func remove(_ id: Int, colorSpaceIdentity: String = "source") {
        removeEntry(Key(id: id, colorSpaceIdentity: colorSpaceIdentity))
    }

    var count: Int { storage.count }
    var currentCost: Int { totalCost }

    private func removeEntry(_ id: Key) {
        guard storage[id] != nil else { return }
        storage.removeValue(forKey: id)
        totalCost -= costs.removeValue(forKey: id) ?? 0
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
        }
    }

    /// 上限超過分を古い順に破棄。1 枚だけで超過する場合はその 1 枚は保持する
    /// (再デコードの繰り返しを防ぐ)。
    private func evictIfNeeded() {
        while totalCost > byteLimit, order.count > 1 {
            removeEntry(order[0])
        }
    }
}
