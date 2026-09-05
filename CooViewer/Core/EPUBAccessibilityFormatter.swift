import Foundation
import Washi

/// EPUB Accessibility メタデータをファイル情報パネル用の行へ整形する。
enum EPUBAccessibilityFormatter {
    /// 存在する値だけを安定した順で並べる。conformsTo は短い
    /// 末尾要素を表示し、元 URL はツールチップに保つ
    /// (cooViewer-oxr.37、設計書 §2.4)。
    static func section(for accessibility: EPUBAccessibility)
        -> PageFileInfo.Section? {
        guard !accessibility.isEmpty else { return nil }

        var rows: [PageFileInfo.Row] = []
        if !accessibility.accessModes.isEmpty {
            rows.append(PageFileInfo.Row(
                label: String(localized: "Access Modes"),
                value: accessibility.accessModes.joined(separator: ", ")))
        }
        if !accessibility.accessModesSufficient.isEmpty {
            let sufficient = accessibility.accessModesSufficient
                .map { $0.joined(separator: " + ") }
                .joined(separator: "; ")
            rows.append(PageFileInfo.Row(
                label: String(localized: "Access Modes Sufficient"),
                value: sufficient))
        }
        if !accessibility.features.isEmpty {
            rows.append(PageFileInfo.Row(
                label: String(localized: "Accessibility Features"),
                value: accessibility.features.joined(separator: ", ")))
        }
        if !accessibility.hazards.isEmpty {
            rows.append(PageFileInfo.Row(
                label: String(localized: "Accessibility Hazards"),
                value: accessibility.hazards.joined(separator: ", ")))
        }
        if let summary = accessibility.summary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(PageFileInfo.Row(
                label: String(localized: "Accessibility Summary"),
                value: summary))
        }
        for conformance in accessibility.conformsTo {
            let component = URL(string: conformance)?.lastPathComponent
            let display = component.flatMap { $0.isEmpty ? nil : $0 }
                ?? conformance
            rows.append(PageFileInfo.Row(
                label: String(localized: "Conforms To"), value: display,
                tooltip: conformance))
        }
        if !accessibility.certifiedBy.isEmpty {
            rows.append(PageFileInfo.Row(
                label: String(localized: "Certified By"),
                value: accessibility.certifiedBy.joined(separator: ", ")))
        }
        if !accessibility.certifierCredentials.isEmpty {
            rows.append(PageFileInfo.Row(
                label: String(localized: "Certifier Credentials"),
                value: accessibility.certifierCredentials.joined(separator: ", ")))
        }

        return PageFileInfo.Section(
            title: String(localized: "Accessibility"), rows: rows)
    }
}
