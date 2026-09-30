import Foundation

/// 全体ページ対応表の構築要求と再試行予算。対応表は画像/EPUB の表示をまたいで
/// 使うためウインドウに属し、サムネイルの表示・非表示には依存しない。
@MainActor
final class CollectionPageMapState {
    struct Key: Hashable {
        let folderPath: String
        let metricsKey: String
    }

    @MainActor
    final class Request {
        let key: Key
        let entries: [PageEntry]
        var task: Task<Void, Never>?

        init(key: Key, entries: [PageEntry]) {
            self.key = key
            self.entries = entries
        }
    }

    private struct Attempts {
        let entries: [PageEntry]
        var count: Int
    }

    static let maximumAttempts = 3
    private(set) var current: CollectionPageMap?
    private(set) var request: Request?
    private var attempts: [Key: Attempts] = [:]

    func attemptCount(for key: Key, entries: [PageEntry]) -> Int {
        guard let value = attempts[key], value.entries == entries else { return 0 }
        return value.count
    }

    /// 同じ対象の並行構築は束ねる。並びが変わった場合は同じ版面キーでも旧要求を
    /// 取り消し、新しいエントリ列を構築する。参照同一性で A→B→A の旧完了も捨てる。
    func begin(key: Key, entries: [PageEntry]) -> Request? {
        if let request, request.key == key, request.entries == entries { return nil }
        cancel()
        let request = Request(key: key, entries: entries)
        self.request = request
        return request
    }

    func owns(_ request: Request) -> Bool { self.request === request }

    func abandon(_ request: Request) {
        if owns(request) { self.request = nil }
    }

    /// 公開できた未完マップだけを試行として数える。取消・対象変更では消費しない。
    @discardableResult
    func publish(_ map: CollectionPageMap, for request: Request) -> Bool {
        guard owns(request), request.task?.isCancelled != true,
              map.folderPath == request.key.folderPath,
              map.metricsKey == request.key.metricsKey, map.entries == request.entries
        else { return false }
        current = map
        self.request = nil
        if map.isComplete {
            attempts[request.key] = nil
        } else {
            attempts[request.key] = Attempts(
                entries: request.entries,
                count: attemptCount(for: request.key, entries: request.entries) + 1)
        }
        return true
    }

    /// 閉窓では現在のマップを保持する。pending を残さず、再表示後に同じ対象の
    /// 再構築を始められるようにする。
    func cancel(resetAttempts: Bool = false) {
        request?.task?.cancel()
        request = nil
        if resetAttempts { attempts.removeAll() }
    }

    func reset() {
        cancel(resetAttempts: true)
        current = nil
    }
}
