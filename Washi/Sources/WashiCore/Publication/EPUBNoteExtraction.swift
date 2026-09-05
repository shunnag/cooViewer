import Foundation

extension EPUBPublication {
    // cooViewer-oxr.32: 表示層から別 spine の注釈を WebKit なしで読めるよう、
    // XML の id 探索と可読テキスト規則を Core 側へ閉じ込める。
    package func noteText(at containerPath: String, fragment: String) -> String? {
        guard let data = try? resource(at: containerPath).data,
              let document = try? WashiXML.document(from: data),
              let root = document.rootElement(),
              let target = Self.noteElement(withID: fragment, in: root)
        else { return nil }

        let selected = Self.noteContainer(for: target) ?? target
        guard let copy = selected.copy() as? XMLElement else {
            return selected.readableText
        }
        // cooViewer-oxr.32: 戻り矢印は注釈本文ではないため、複製側だけから除く。
        Self.removeNoteBacklinks(from: copy)
        return copy.readableText
    }

    private static func noteElement(
        withID id: String, in element: XMLElement
    ) -> XMLElement? {
        if element.attr("id") == id { return element }
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if let found = noteElement(withID: id, in: child) { return found }
        }
        return nil
    }

    private static func noteContainer(for target: XMLElement) -> XMLElement? {
        let name = target.localName?.lowercased()
        guard name == "li" || name == "p" else { return nil }
        var ancestor = target.parent as? XMLElement
        while let candidate = ancestor {
            let candidateName = candidate.localName?.lowercased()
            if candidateName == "aside" || candidateName == "section" {
                let types = (candidate.attr(
                    "type", ns: XMLNamespace.epubOps, prefix: "epub") ?? "")
                    .lowercased().split(whereSeparator: { $0.isWhitespace })
                let role = candidate.attr("role")?.lowercased()
                if types.contains("footnote") || types.contains("endnote")
                    || types.contains("rearnote")
                    || role == "doc-footnote" || role == "doc-endnote"
                {
                    return candidate
                }
            }
            ancestor = candidate.parent as? XMLElement
        }
        return nil
    }

    private static func removeNoteBacklinks(from element: XMLElement) {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName?.lowercased() == "a",
               let href = child.attr("href")
                    ?? child.attr("href", ns: XMLNamespace.xlink, prefix: "xlink"),
               href.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("#") {
                child.detach()
            } else {
                removeNoteBacklinks(from: child)
            }
        }
    }
}
