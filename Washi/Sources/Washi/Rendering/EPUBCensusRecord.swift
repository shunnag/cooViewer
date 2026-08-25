import Foundation

/// A persisted whole-book pagination census (per-spine-item page counts for a
/// specific set of display metrics). Export it with
/// ``EPUBReaderView/exportCensus()`` and re-inject it with
/// ``EPUBReaderView/importCensus(_:)`` on a later open to skip the offscreen
/// re-measure. Codable so a host can store it alongside its book state.
public struct EPUBCensusRecord: Sendable, Codable, Equatable {
    /// The display-metrics key the counts were measured for (font scale,
    /// viewport, margins, spread, …). Only reused when the current metrics match.
    public let metricsKey: String
    /// Page count of each spine item, in reading order.
    public let counts: [Int]
    /// The book's release identifier (unique-identifier + dcterms:modified) at
    /// measure time, used to reject counts from a different edition. Nil for
    /// books that declare no modified date.
    public let releaseIdentifier: String?

    public init(metricsKey: String, counts: [Int], releaseIdentifier: String?) {
        self.metricsKey = metricsKey
        self.counts = counts
        self.releaseIdentifier = releaseIdentifier
    }
}
