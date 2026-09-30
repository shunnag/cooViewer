import Foundation

/// 開いている EPUB の実測 census を合本計画へ再利用する純粋な判定値
/// （cooViewer-oxr.65 / cooViewer-oxr.70、設計書 §2.4）。
struct EPUBOpenBookCensusSeed: Equatable, Sendable {
    let entryIndex: Int
    let counts: [Int]
    let pagesPerScreen: Int

    static func make(
        requestedMetricsKey: String,
        viewMetricsKey: String?,
        counts: [Int]?,
        pagesPerScreen: Int,
        entryIndex: Int?
    ) -> EPUBOpenBookCensusSeed? {
        guard viewMetricsKey == requestedMetricsKey,
              let counts, let entryIndex else { return nil }
        return EPUBOpenBookCensusSeed(
            entryIndex: entryIndex, counts: counts,
            pagesPerScreen: pagesPerScreen)
    }
}
