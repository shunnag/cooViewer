import CoreGraphics
import Foundation

/// デコード済みページ画像の LRU キャッシュ(仕様書 §4.5.1 の cacheArray に相当)。
/// 旧実装の「設定値 +4」という暗黙の容量補正は行わない(設計書 §13.4)。
actor PageCache {
    private var storage: [Int: CGImage] = [:]
    private var order: [Int] = []  // 末尾が最新(MRU)
    private var capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func setCapacity(_ newCapacity: Int) {
        capacity = max(1, newCapacity)
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
        if storage[id] != nil, let index = order.firstIndex(of: id) {
            order.remove(at: index)
        }
        storage[id] = image
        order.append(id)
        evictIfNeeded()
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    var count: Int { storage.count }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
