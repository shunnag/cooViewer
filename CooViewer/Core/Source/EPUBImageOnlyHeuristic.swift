import Foundation
import Washi

/// rendition:layout を持たない画像だけの EPUB を画像パイプラインへ振り分ける。
/// 判定時の XHTML 解析結果を Publication 単位で再利用し、EPUBSource が同じ
/// spine を読み直さないようにする(cooViewer-oxr.44、設計書 §2.4)。
enum EPUBImageOnlyHeuristic {
    private enum Classification: Sendable {
        case imageOnly([FixedLayoutPageInfo])
        case other
    }

    private final class CacheEntry {
        weak var publication: EPUBPublication?
        let classification: Classification

        init(publication: EPUBPublication, classification: Classification) {
            self.publication = publication
            self.classification = classification
        }
    }

    private final class ClassificationCache: @unchecked Sendable {
        private let lock = NSLock()
        private let capacity: Int
        private var entries: [ObjectIdentifier: CacheEntry] = [:]
        private var order: [ObjectIdentifier] = []

        init(capacity: Int) {
            self.capacity = capacity
        }

        func value(for publication: EPUBPublication) -> Classification? {
            let key = ObjectIdentifier(publication)
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[key], entry.publication === publication else {
                entries[key] = nil
                order.removeAll { $0 == key }
                return nil
            }
            order.removeAll { $0 == key }
            order.append(key)
            return entry.classification
        }

        func insert(_ classification: Classification,
                    for publication: EPUBPublication) {
            let key = ObjectIdentifier(publication)
            lock.lock()
            defer { lock.unlock() }
            entries[key] = CacheEntry(
                publication: publication, classification: classification)
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > capacity {
                entries[order.removeFirst()] = nil
            }
        }
    }

    private static let cache = ClassificationCache(capacity: 8)

    /// 全 spine が単一画像ページなら、解析済みページ情報を spine 順で返す。
    /// 通常の小説は最初の本文項目で打ち切る。
    static func imageOnlyPageInfos(
        _ publication: EPUBPublication
    ) -> [FixedLayoutPageInfo]? {
        switch classification(of: publication) {
        case .imageOnly(let infos): infos
        case .other: nil
        }
    }

    static func qualifies(_ publication: EPUBPublication) -> Bool {
        if case .imageOnly = classification(of: publication) { return true }
        return false
    }

    private static func classification(
        of publication: EPUBPublication
    ) -> Classification {
        if let cached = cache.value(for: publication) { return cached }
        if publication.isFixedLayout || publication.isDRMProtected
            || publication.readingOrder.isEmpty {
            let result = Classification.other
            cache.insert(result, for: publication)
            return result
        }
        var infos: [FixedLayoutPageInfo] = []
        infos.reserveCapacity(publication.readingOrder.count)
        for entry in publication.readingOrder {
            guard let info = try? publication.fixedLayoutInfo(
                forSpineIndex: entry.spineIndex),
                info.simpleImagePath != nil else {
                let result = Classification.other
                cache.insert(result, for: publication)
                return result
            }
            infos.append(info)
        }
        let result = Classification.imageOnly(infos)
        cache.insert(result, for: publication)
        return result
    }
}
