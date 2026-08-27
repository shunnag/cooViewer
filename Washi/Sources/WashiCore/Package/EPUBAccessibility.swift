import Foundation

/// The accessibility metadata of a publication (schema.org a11y vocabulary and
/// EPUB Accessibility conformance), surfaced as typed values.
///
/// Reading systems increasingly must display this (e.g. the EU Accessibility
/// Act). All fields default to empty when a book declares nothing; check
/// ``isEmpty`` to decide whether to show an accessibility section at all.
public struct EPUBAccessibility: Sendable, Equatable {
    /// `schema:accessMode` — the human sensory modes the content is in
    /// (e.g. "textual", "visual", "auditory").
    public let accessModes: [String]
    /// `schema:accessModeSufficient` — each inner array is one set of access
    /// modes sufficient to consume the whole publication.
    public let accessModesSufficient: [[String]]
    /// `schema:accessibilityFeature` — features that aid access
    /// (e.g. "structuralNavigation", "alternativeText", "displayTransformability").
    public let features: [String]
    /// `schema:accessibilityHazard` — known hazards
    /// (e.g. "flashing", "noFlashingHazard", "motionSimulation").
    public let hazards: [String]
    /// `schema:accessibilitySummary` — a human-readable summary, if provided.
    public let summary: String?
    /// `dcterms:conformsTo` — EPUB Accessibility conformance URLs, if any.
    public let conformsTo: [String]
    /// `a11y:certifiedBy` — the party that certified the conformance claim.
    public let certifiedBy: [String]

    /// True when the book declares no accessibility metadata at all.
    public var isEmpty: Bool {
        accessModes.isEmpty && accessModesSufficient.isEmpty && features.isEmpty
            && hazards.isEmpty && summary == nil && conformsTo.isEmpty
            && certifiedBy.isEmpty
    }
}

extension EPUBMetadata {
    /// The CSS class a reading system applies to the text currently being read
    /// during media-overlay playback (`media:active-class`), if declared.
    /// Returns nil when the declared value is empty or not a single CSS token
    /// (e.g. contains internal whitespace), so the caller falls back to a valid
    /// default — passing such a value to `classList.add` throws and would
    /// silently break page-following during narration.
    public var mediaOverlayActiveClass: String? {
        guard let value = metaItems.first(where: {
            $0.refines == nil && $0.property == "media:active-class"
        })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty,
        value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        return value
    }

    /// The publication's accessibility metadata, assembled from the document's
    /// schema.org / EPUB-a11y meta properties.
    public var accessibility: EPUBAccessibility {
        // 文書全体の meta(refines == nil)だけを対象にする
        func values(_ property: String) -> [String] {
            metaItems
                .filter { $0.refines == nil && $0.property == property }
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        // accessModeSufficient は 1 つの meta 値がカンマ区切りの「十分な集合」
        let sufficient = values("schema:accessModeSufficient").map { line in
            line.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.filter { !$0.isEmpty }
        return EPUBAccessibility(
            accessModes: values("schema:accessMode"),
            accessModesSufficient: sufficient,
            features: values("schema:accessibilityFeature"),
            hazards: values("schema:accessibilityHazard"),
            summary: values("schema:accessibilitySummary").first,
            conformsTo: values("dcterms:conformsTo"),
            certifiedBy: values("a11y:certifiedBy"))
    }

    /// The primary authors — creators whose MARC role is `aut`, or, when no
    /// creator is role-tagged, all creators. Ordered by `display-seq` when
    /// present, then by document order. Display names (not file-as).
    public var authors: [String] {
        let authored = creators.filter { $0.role == "aut" }
        let chosen = authored.isEmpty ? creators : authored
        return chosen
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.displaySeq ?? Int.max
                let r = rhs.element.displaySeq ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map { $0.element.value }
    }

    /// The series (collection) this publication belongs to, preferring one
    /// typed `series`, else the first declared collection. Nil if none.
    public var series: EPUBCollectionMembership? {
        collections.first { $0.type == "series" } ?? collections.first
    }
}
