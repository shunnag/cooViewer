import Foundation

/// A saved highlight (optionally with a note) anchored to a range of the
/// spine item's extracted plain text.
///
/// The anchor is the same UTF-16 range that `EPUBSearchHit.utf16Range` uses and
/// that `EPUBReaderView.go(to:textRange:)` resolves, so it survives font-size,
/// viewport and theme changes — unlike a position expressed as a progression.
/// The shape is deliberately close to a Readium annotation so a host can map
/// its own store onto it (cooViewer-oxr.46 C40).
public struct EPUBHighlight: Sendable, Codable, Equatable, Identifiable {
    /// Visual treatment. The reader draws these with the CSS Custom Highlight
    /// API, so they never modify the book's DOM.
    public enum Style: String, Sendable, Codable, CaseIterable {
        case yellow, green, blue, pink, underline
    }

    /// Stable identity, chosen by the host (a UUID string works well).
    public var id: String
    /// Reading-order index of the item the range belongs to.
    public var spineIndex: Int
    /// The idref of that item, so the highlight survives a revised edition
    /// the same way `EPUBLocator.idref` does.
    public var idref: String?
    /// Offset, in UTF-16 code units of the item's extracted text.
    public var utf16Offset: Int
    /// Length in UTF-16 code units. Always at least 1.
    public var utf16Length: Int
    public var style: Style
    /// The reader's own note, if any. Washi stores and returns it untouched.
    public var note: String?

    public init(id: String, spineIndex: Int, idref: String? = nil,
                utf16Offset: Int, utf16Length: Int,
                style: Style = .yellow, note: String? = nil) {
        self.id = id
        self.spineIndex = spineIndex
        self.idref = idref
        self.utf16Offset = max(0, utf16Offset)
        self.utf16Length = max(1, utf16Length)
        self.style = style
        self.note = note
    }

    /// The anchored range, in the form `go(to:textRange:)` takes.
    public var textRange: (utf16Offset: Int, utf16Length: Int) {
        (utf16Offset, utf16Length)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        spineIndex = try values.decode(Int.self, forKey: .spineIndex)
        idref = try values.decodeIfPresent(String.self, forKey: .idref)
        // 保存データの異常値を持ち込ませない(EPUBLocator と同じ方針)
        utf16Offset = max(0, try values.decode(Int.self, forKey: .utf16Offset))
        utf16Length = max(1, try values.decode(Int.self, forKey: .utf16Length))
        style = (try? values.decode(Style.self, forKey: .style)) ?? .yellow
        note = try values.decodeIfPresent(String.self, forKey: .note)
    }
}
