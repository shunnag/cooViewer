import Foundation

/// メトリクスキーごとの census 実測失敗の台帳(2-strike + TTL)。
///
/// 一時的な WebContent プロセス死・15 秒タイムアウトが同一メトリクスで 2 回
/// 起きると、そのキーの再実測を止めて runSetup のたびに 15 秒待つのを防ぐ。
/// ただし恒久停止にはしない: 稀な一過性要因(メモリ逼迫等)で 2 回失敗した
/// キーがセッション中ずっと欠けたまま(N/M・ページバーが出ない)にならない
/// よう、TTL 経過で勘定ごと赦して再挑戦させる。壊れた spine は再び 2 回失敗して
/// 戻るだけで、期限内のタイムアウト・ループ護持は保たれる。
/// (サムネイル生成の失敗記録と同じ「2-strike + 有効期限」方針。Washi は依存
/// ゼロ設計のため外部の実装を import せず、この純値型として持つ。)
struct CensusFailureLedger {
    private struct Record {
        var count = 0
        /// 恒久記録(strikeLimit 回失敗)へ昇格した時刻。ttl 経過で赦す
        var permanentAt: ContinuousClock.Instant?
    }
    private var records: [String: Record] = [:]
    let ttl: Duration
    let strikeLimit = 2

    init(ttl: Duration = .seconds(300)) { self.ttl = ttl }

    /// 恒久記録済みで期限内なら true(再スケジュールしない)。期限切れは赦す
    mutating func shouldSkip(_ key: String,
                             now: ContinuousClock.Instant = .now) -> Bool {
        guard let record = records[key], let at = record.permanentAt else { return false }
        if now - at >= ttl {
            records[key] = nil
            return false
        }
        return true
    }

    mutating func recordFailure(_ key: String,
                                now: ContinuousClock.Instant = .now) {
        var record = records[key] ?? Record()
        record.count += 1
        if record.count >= strikeLimit, record.permanentAt == nil {
            record.permanentAt = now
        }
        records[key] = record
    }

    mutating func clear() { records.removeAll() }
}
