import Foundation

/// Page progression direction (EPUB 3.3 §5.5, spine's page-progression-direction).
/// Japanese vertical-writing books use rtl (right-bound; pages advance right → left).
public enum PageProgressionDirection: String, Sendable {
    case ltr
    case rtl
    /// Attribute omitted (the Reading System may decide from language and writing mode).
    case byDefault = "default"
}

/// rendition:layout (EPUB 3.3 §D.3.2).
public enum RenditionLayout: String, Sendable {
    case reflowable
    case prePaginated = "pre-paginated"
}

/// rendition:orientation
public enum RenditionOrientation: String, Sendable {
    case auto, landscape, portrait
}

/// rendition:spread (whether to synthesize spreads; portrait was removed in 3.3 → treated as both).
public enum RenditionSpread: String, Sendable {
    case auto, none, landscape, both
}

/// rendition:flow (scrolling mode for reflowable content).
public enum RenditionFlow: String, Sendable {
    case auto, paginated
    case scrolledContinuous = "scrolled-continuous"
    case scrolledDoc = "scrolled-doc"
}

/// Title (with title-type refine).
public struct EPUBTitle: Sendable, Hashable {
    public let value: String
    /// main / subtitle / short / collection / edition / expanded
    public let type: String?
    public let fileAs: String?
    public let displaySeq: Int?
}

/// Creator / contributor (with role refine).
public struct EPUBCreator: Sendable, Hashable {
    public let value: String
    /// MARC relator code (aut / ill / trl, etc.).
    public let role: String?
    public let fileAs: String?
    public let displaySeq: Int?
}

/// dc:identifier
public struct EPUBIdentifier: Sendable, Hashable {
    public let value: String
    public let id: String?
    /// Refine value from identifier-type or scheme.
    public let scheme: String?
}

/// belongs-to-collection (series information; EPUB 3.3 §D.4.1).
public struct EPUBCollectionMembership: Sendable, Hashable {
    public let name: String
    /// collection-type refine (series / set, etc.).
    public let type: String?
    public let groupPosition: String?
}

/// Generic meta (stored under a canonicalized property name).
public struct EPUBMetaItem: Sendable, Hashable {
    /// Known vocabularies are normalized to a prefixed form such as "rendition:layout".
    public let property: String
    public let value: String
    /// The id of the element this refines (without #); nil for document-wide meta.
    public let refines: String?
    public let scheme: String?
}

/// The full set of rendition properties (document-wide defaults).
public struct RenditionProperties: Sendable {
    public var layout: RenditionLayout = .reflowable
    public var orientation: RenditionOrientation = .auto
    public var spread: RenditionSpread = .auto
    public var flow: RenditionFlow = .auto
    /// Deprecated rendition:viewport (a relic of 3.0; the default viewport for FXL).
    public var viewport: String?
}

/// Package document metadata (DCMES with refines resolved).
public struct EPUBMetadata: Sendable {
    public var titles: [EPUBTitle] = []
    public var creators: [EPUBCreator] = []
    public var contributors: [EPUBCreator] = []
    public var publishers: [String] = []
    public var languages: [String] = []
    public var identifiers: [EPUBIdentifier] = []
    /// The value of the dc:identifier referenced by the unique-identifier attribute.
    public var uniqueIdentifier: String?
    /// dcterms:modified (kept as the raw ISO 8601 string).
    public var modified: String?
    public var date: String?
    public var description: String?
    public var rights: String?
    public var subjects: [String] = []
    public var collections: [EPUBCollectionMembership] = []
    public var rendition = RenditionProperties()
    /// All meta entries, including unresolved ones (for extension use).
    public var metaItems: [EPUBMetaItem] = []

    /// Display title (prefers title-type=main, otherwise the first title).
    public var mainTitle: String? {
        titles.first { $0.type == "main" }?.value ?? titles.first?.value
    }

    /// Release identifier (unique-identifier + modified; EPUB 3.3 §5.2.3).
    /// The unique identifier also used for font-obfuscation key derivation is uniqueIdentifier, not this.
    public var releaseIdentifier: String? {
        guard let uniqueIdentifier else { return nil }
        guard let modified else { return uniqueIdentifier }
        return uniqueIdentifier + "@" + modified
    }
}

/// A manifest item.
public struct ManifestItem: Sendable, Hashable {
    public let id: String
    /// href relative to the package document (as written; the in-container path is resolved by Publication).
    public let href: String
    public let mediaType: String
    /// nav / cover-image / scripted / svg / mathml / remote-resources / switch
    public let properties: Set<String>
    /// The fallback item id (for items that are not a core media type; EPUB 3.3 §5.6).
    public let fallback: String?
    /// The item id of the media overlay (SMIL).
    public let mediaOverlay: String?
}

/// A single spine item.
public struct SpineItemRef: Sendable, Hashable {
    public let idref: String
    /// linear="no" marks auxiliary content (defaults to true).
    public let linear: Bool
    /// page-spread-left / page-spread-right / rendition:page-spread-center /
    /// per-item rendition:* overrides, etc. (canonicalized).
    public let properties: Set<String>
}

/// The whole spine.
public struct EPUBSpine: Sendable {
    public let itemRefs: [SpineItemRef]
    public let pageProgressionDirection: PageProgressionDirection
    /// The item id pointing to the EPUB 2-compatible NCX (toc attribute).
    public let tocItemID: String?
}

/// The parsed result of the package document (OPF).
public struct EPUBPackage: Sendable {
    /// version attribute ("3.0" / "2.0", etc., as written).
    public let version: String
    public let metadata: EPUBMetadata
    public let manifest: [ManifestItem]
    public let manifestByID: [String: ManifestItem]
    public let spine: EPUBSpine
    /// The in-container path of the package document itself (the base for href resolution).
    public let path: String

    /// The EPUB 3 navigation document (properties="nav").
    public var navItem: ManifestItem? {
        manifest.first { $0.properties.contains("nav") }
    }

    /// Cover image (EPUB 3 properties="cover-image" → EPUB 2 meta name="cover").
    public var coverImageItem: ManifestItem? {
        if let item = manifest.first(where: { $0.properties.contains("cover-image") }) {
            return item
        }
        // EPUB 2 互換: <meta name="cover" content="item-id">
        if let coverID = metadata.metaItems.first(where: { $0.property == "cover" })?.value {
            return manifestByID[coverID]
        }
        return nil
    }

    /// Whether the whole document is fixed-layout.
    public var isFixedLayout: Bool {
        metadata.rendition.layout == .prePaginated
    }

    /// The effective layout for a single spine item (the itemref's rendition:layout-* override).
    public func effectiveLayout(for itemRef: SpineItemRef) -> RenditionLayout {
        if itemRef.properties.contains("rendition:layout-pre-paginated") {
            return .prePaginated
        }
        if itemRef.properties.contains("rendition:layout-reflowable") {
            return .reflowable
        }
        return metadata.rendition.layout
    }

    /// The effective page progression direction (default is inferred from language: even for
    /// Japanese vertical-writing cultures the spec default is ltr; only an explicit rtl becomes right-bound).
    public var readingDirection: PageProgressionDirection {
        spine.pageProgressionDirection
    }
}
