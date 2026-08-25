import Foundation

/// A reading position (spine item + progression within that item). In
/// reflowable layout the page number shifts with window size and font
/// settings, so the position is persisted as a progression ratio (0..1).
public struct EPUBLocator: Sendable, Equatable, Codable {
    public var spineIndex: Int
    /// Progression within the item, from 0.0 (start) to 1.0 (end).
    public var progression: Double
    /// The idref of the spine itemref. When present, it lets the correct item
    /// be tracked across a revised edition of the book (spine reordering or
    /// added/removed items) (EPUBPublication.resolve). Decode-compatible with
    /// the old saved format (which stored only {spineIndex, progression}).
    public var idref: String?

    public init(spineIndex: Int, progression: Double = 0, idref: String? = nil) {
        self.spineIndex = spineIndex
        self.progression = min(1, max(0, progression))
        self.idref = idref
    }
}
