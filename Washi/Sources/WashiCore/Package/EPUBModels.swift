import Foundation

/// Page progression direction (EPUB 3.3 §5.5, spine's page-progression-direction).
/// Japanese vertical-writing books use rtl (right-bound; pages advance right → left).
public enum PageProgressionDirection: String, Sendable {
    case ltr
    case rtl
    /// Attribute omitted (the Reading System may decide from language and writing mode).
    case byDefault = "default"
}

/// The reading direction exposed by a publication.
///
/// This is an API-compatible name for ``PageProgressionDirection``. An
/// effective direction is always either ``PageProgressionDirection/ltr`` or
/// ``PageProgressionDirection/rtl``.
public typealias EPUBReadingDirection = PageProgressionDirection

/// Describes which publication signal determined the effective reading direction.
public enum EPUBReadingDirectionSource: Sendable {
    /// The package spine declares `page-progression-direction`.
    case declared
    /// Package metadata declares Amazon's `primary-writing-mode` value.
    case primaryWritingModeMeta
    /// CSS used by an early reading-order document declares vertical right-to-left writing.
    case verticalWritingCSS
    /// The primary Dublin Core language normally reads right-to-left.
    case rtlLanguage
    /// No directional signal was present, so left-to-right was selected.
    case fallback
}

/// Base text direction for human-readable package metadata.
public enum EPUBTextDirection: String, Sendable {
    case ltr
    case rtl
    case auto
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
    /// The effective base direction inherited from the title, metadata, or package element.
    public let direction: EPUBTextDirection?
    /// The effective BCP 47 language inherited from the title, metadata, or package element.
    public let language: String?

    /// Creates a title and its optional refinements and language context.
    public init(
        value: String,
        type: String? = nil,
        fileAs: String? = nil,
        displaySeq: Int? = nil,
        direction: EPUBTextDirection? = nil,
        language: String? = nil
    ) {
        self.value = value
        self.type = type
        self.fileAs = fileAs
        self.displaySeq = displaySeq
        self.direction = direction
        self.language = language
    }
}

/// Creator / contributor (with role refine).
public struct EPUBCreator: Sendable, Hashable {
    public let value: String
    /// MARC relator code (aut / ill / trl, etc.).
    public let role: String?
    public let fileAs: String?
    public let displaySeq: Int?
    /// The effective base direction inherited from the creator, metadata, or package element.
    public let direction: EPUBTextDirection?
    /// The effective BCP 47 language inherited from the creator, metadata, or package element.
    public let language: String?

    /// Creates a creator or contributor and its optional metadata refinements.
    public init(
        value: String,
        role: String? = nil,
        fileAs: String? = nil,
        displaySeq: Int? = nil,
        direction: EPUBTextDirection? = nil,
        language: String? = nil
    ) {
        self.value = value
        self.role = role
        self.fileAs = fileAs
        self.displaySeq = displaySeq
        self.direction = direction
        self.language = language
    }
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
    /// The effective base direction inherited from the metadata or package element.
    public let direction: EPUBTextDirection?
    /// The effective BCP 47 language inherited from the metadata or package element.
    public let language: String?
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
    // cooViewer-oxr.37: EPUB Accessibility 1.0 の link 形式を、公開する
    // accessibility 値へ統合するまで package 内部で保持する。
    var accessibilityConformanceLinks: [String] = []
    var accessibilityCertifierCredentialLinks: [String] = []

    /// Creates an initially empty metadata value with optional inherited language context.
    public init(
        direction: EPUBTextDirection? = nil,
        language: String? = nil
    ) {
        self.direction = direction
        self.language = language
    }

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
    /// Canonicalized properties in their original document order, including duplicates.
    public let propertyList: [String]
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
        // cooViewer-oxr.14: 重複指定は properties(Set) ではなく文書順に
        // 走査し、最初の rendition:layout-* だけを有効にする。
        for property in itemRef.propertyList {
            switch property {
            case "rendition:layout-pre-paginated": return .prePaginated
            case "rendition:layout-reflowable": return .reflowable
            default: continue
            }
        }
        return metadata.rendition.layout
    }

    /// Returns the effective spread preference for one spine item, honoring
    /// the first itemref override before the publication-wide default.
    public func effectiveSpread(for itemRef: SpineItemRef) -> RenditionSpread {
        // cooViewer-oxr.51: EPUB 3 の rendition:spread-* と EPUB 2 時代の
        // spread-* の双方を文書順で解決する。
        for property in itemRef.propertyList {
            switch property {
            case "rendition:spread-none", "spread-none": return .none
            case "rendition:spread-landscape", "spread-landscape":
                return .landscape
            case "rendition:spread-both", "spread-both": return .both
            case "rendition:spread-auto", "spread-auto": return .auto
            default: continue
            }
        }
        return metadata.rendition.spread
    }

    /// The effective page progression direction (default is inferred from language: even for
    /// Japanese vertical-writing cultures the spec default is ltr; only an explicit rtl becomes right-bound).
    public var readingDirection: PageProgressionDirection {
        spine.pageProgressionDirection
    }
}
