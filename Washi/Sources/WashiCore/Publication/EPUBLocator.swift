import Foundation

/// A reading position (spine item + progression within that item). In
/// reflowable layout the page number shifts with window size and font
/// settings, so the position is persisted as a progression ratio (0..1).
public struct EPUBLocator: Sendable, Equatable, Codable {
    public var spineIndex: Int
    /// Progression within the item, from 0.0 (start) to 1.0 (end).
    public var progression: Double {
        get { storedProgression }
        set { storedProgression = Self.clampedProgression(newValue) }
    }
    private var storedProgression: Double
    /// The idref of the spine itemref. When present, it lets the correct item
    /// be tracked across a revised edition of the book (spine reordering or
    /// added/removed items) (EPUBPublication.resolve). Decode-compatible with
    /// the old saved format (which stored only {spineIndex, progression}).
    public var idref: String?

    public init(spineIndex: Int, progression: Double = 0, idref: String? = nil) {
        self.spineIndex = spineIndex
        self.storedProgression = Self.clampedProgression(progression)
        self.idref = idref
    }

    private enum CodingKeys: String, CodingKey {
        case spineIndex
        case progression
        case idref
    }

    /// Decodes a persisted locator while enforcing the same progression bounds
    /// as the public initializer and setter.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        spineIndex = try values.decode(Int.self, forKey: .spineIndex)
        let decoded = try values.decode(Double.self, forKey: .progression)
        // cooViewer-oxr.73: 合成 Codable は init のクランプを通らないため、
        // 永続化データから巨大値や NaN を持ち込ませない。
        storedProgression = Self.clampedProgression(decoded)
        idref = try values.decodeIfPresent(String.self, forKey: .idref)
    }

    /// Encodes the stable, public locator representation.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(spineIndex, forKey: .spineIndex)
        try values.encode(storedProgression, forKey: .progression)
        try values.encodeIfPresent(idref, forKey: .idref)
    }

    private static func clampedProgression(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(1, max(0, value))
    }
}
