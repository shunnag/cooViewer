import Foundation
import Washi

/// 同一 URL の並行 EPUB 解析を 1 本に合流させる(合本内の横断ジャンプや代理
/// ページの往復連打で、同じ巻を何度も無制限に解析しないため)。
/// 結果はキャッシュせず in-flight 合流のみ — EPUBScreenAtlas.measuring と同方針。
@MainActor
final class EPUBParseCoalescer {
    /// 正規化パス → 実行中のパース
    private var inFlight: [String: Task<EPUBPublication?, Never>] = [:]
    /// 実パース(テストは注入で差し替える)
    private let parse: @Sendable (URL) -> EPUBPublication?

    init(parse: @escaping @Sendable (URL) -> EPUBPublication? = {
        try? EPUBPublication(url: $0)
    }) {
        self.parse = parse
    }

    func publication(at url: URL) async -> EPUBPublication? {
        let key = CanonicalPath.normalize(url.path)
        if let running = inFlight[key] { return await running.value }
        let parse = self.parse
        let task = Task.detached(priority: .userInitiated) { parse(url) }
        inFlight[key] = task
        let result = await task.value
        // 完了したのが自分のタスクのときだけ外す(合流窓の取り違え防止)
        if inFlight[key] == task { inFlight[key] = nil }
        return result
    }
}
