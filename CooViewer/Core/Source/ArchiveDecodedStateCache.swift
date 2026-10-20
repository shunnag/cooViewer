import Foundation

/// 実行中の読み取りを止めず、アイドルの復号状態だけを解放する所有者。
protocol ArchiveDecodedStateOwner: AnyObject, Sendable {
    func releaseIdleDecodedState() async -> Bool
}

/// FD と別に、solid 辞書・展開係の保持を冊数から独立させる。
/// 最近の本は維持してページめくりを速くし、実行中のスプール・貸出中の係は触らない。
actor ArchiveDecodedStateCache {
    static let maximumIdleBooks = max(1, min(16,
        Int(ProcessInfo.processInfo.physicalMemory / (8 << 30))))
    static let shared = ArchiveDecodedStateCache(limit: maximumIdleBooks)

    private final class Reference: @unchecked Sendable {
        weak var owner: (any ArchiveDecodedStateOwner)?
        init(_ owner: any ArchiveDecodedStateOwner) { self.owner = owner }
    }
    private let limit: Int
    private var owners: [ObjectIdentifier: Reference] = [:]
    private var order: [ObjectIdentifier] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func recordUse(_ owner: any ArchiveDecodedStateOwner) async {
        order.removeAll { key in
            guard owners[key]?.owner == nil else { return false }
            owners[key] = nil
            return true
        }
        let key = ObjectIdentifier(owner)
        order.removeAll { $0 == key }
        owners[key] = Reference(owner)
        order.append(key)
        // 忙しい本しかないときも一巡で戻る。次の利用完了で再び解放を試す。
        var attempts = order.count
        while order.count > limit, attempts > 0 {
            attempts -= 1
            let candidate = order.removeFirst()
            guard let reference = owners.removeValue(forKey: candidate),
                  let old = reference.owner else { continue }
            if !(await old.releaseIdleDecodedState()), owners[candidate] == nil {
                // await 中の新しい利用を古い順序で上書きしない。
                owners[candidate] = reference
                order.append(candidate)
            }
        }
    }
}
