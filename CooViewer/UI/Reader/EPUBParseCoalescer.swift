import Foundation
import Washi

/// 同一 URL の並行 EPUB 解析を 1 本に合流させる(合本内の横断ジャンプや代理
/// ページの往復連打で、同じ巻を何度も無制限に解析しないため)。
/// 結果はキャッシュせず in-flight 合流のみ — EPUBScreenAtlas.measuring と同方針。
@MainActor
final class EPUBParseCoalescer {
    /// 正規化パス → 実行中のパース
    private var inFlight: [String: Task<Result<EPUBPublication, any Error>, Never>] = [:]
    /// 解析失敗を保持するため、テストから失敗を注入できる実パース
    /// (cooViewer-oxr.41)。
    private let parse: @Sendable (URL) throws -> EPUBPublication
    /// 合流成立を決定論的に観測するテスト用フック(cooViewer-oxr.41)。
    private let onCoalescedRequest: @Sendable () -> Void

    init(
        parse: @escaping @Sendable (URL) throws -> EPUBPublication = { url in
            try EPUBPublication(
                url: url,
                readStrategy: VolumeMappingPolicy.epubReadStrategy(for: url))
        },
        onCoalescedRequest: @escaping @Sendable () -> Void = {}
    ) {
        self.parse = parse
        self.onCoalescedRequest = onCoalescedRequest
    }

    func publication(
        at url: URL,
        preparsed: EPUBPublication? = nil
    ) async -> Result<EPUBPublication, any Error> {
        let key = CanonicalPath.normalize(url.path)
        // cooViewer-oxr.42: 設計書 §2.4 の合本代理ページは生成時の解析結果を
        // 保持する。同じ実体なら解析キューへ載せず、そのインスタンスを渡す。
        if let preparsed,
           CanonicalPath.normalize(preparsed.url.path) == key {
            return .success(preparsed)
        }
        if let running = inFlight[key] {
            onCoalescedRequest()
            return await running.value
        }
        let parse = self.parse
        let task = Task.detached(priority: .userInitiated) {
            () -> Result<EPUBPublication, any Error> in
            do {
                return .success(try parse(url))
            } catch {
                return .failure(error)
            }
        }
        inFlight[key] = task
        let result = await task.value
        // 完了したのが自分のタスクのときだけ外す(合流窓の取り違え防止)
        if inFlight[key] == task { inFlight[key] = nil }
        return result
    }

    /// cooViewer-oxr.41: エラー内容を必要としない従来経路向けの互換アクセサ。
    func publicationIfAvailable(
        at url: URL,
        preparsed: EPUBPublication? = nil
    ) async -> EPUBPublication? {
        switch await publication(at: url, preparsed: preparsed) {
        case .success(let publication):
            return publication
        case .failure:
            return nil
        }
    }
}
