import CoreGraphics
import Dispatch
import Foundation

/// デコード済みページ画像の LRU キャッシュ(仕様書 §4.5.1 の cacheArray に相当)。
/// 旧実装の「枚数基準(設定値+4)」を廃し、バイト基準で管理する
/// (設計書「キャッシュ・先読み設計」)。メモリ圧迫通知で自動トリムする。
actor PageCache {
    private var storage: [Int: CGImage] = [:]
    private var order: [Int] = []  // 末尾が最新(MRU)
    private var costs: [Int: Int] = [:]
    private var totalCost = 0
    private var byteLimit: Int
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    init(byteLimit: Int) {
        self.byteLimit = max(1, byteLimit)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .global(qos: .utility))
        self.pressureSource = source  // self を閉包に渡す前に全プロパティを初期化する
        source.setEventHandler { [weak self] in
            Task { await self?.trimToHalf() }
        }
        source.activate()
    }

    deinit {
        pressureSource?.cancel()
    }

    func setByteLimit(_ newLimit: Int) {
        byteLimit = max(1, newLimit)
        evictIfNeeded()
    }

    func image(for id: Int) -> CGImage? {
        guard let image = storage[id] else { return nil }
        // ヒット時は MRU へ移動(仕様書 §4.5.1)
        if let index = order.firstIndex(of: id) {
            order.remove(at: index)
            order.append(id)
        }
        return image
    }

    func insert(_ image: CGImage, for id: Int) {
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

    var count: Int { storage.count }
    var currentCost: Int { totalCost }

    /// メモリ圧迫時: 使用量を半分まで削る
    func trimToHalf() {
        let target = totalCost / 2
        while totalCost > target, order.count > 1 {
            removeEntry(order[0])
        }
    }

    private func removeEntry(_ id: Int) {
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
