import PDFKit

/// PDF 自身のネイティブ・メタデータ(文書属性 + アウトライン)から ComicInfo を
/// 合成する(cooViewer-oo6)。archive の ComicInfo.xml と同じ下流(タイトル/情報窓/
/// 章メニュー)を PDF でも再利用するための橋渡し。read-only・常にヒント。
/// PDFKit 依存をこのファイルに隔離し、ComicInfo モデル本体は Foundation のみに保つ。
extension ComicInfo {
    /// 何も得られなければ nil。文書タイトルは documentTitle へ入れる
    /// (ウインドウには出さず情報窓のみ = ユーザー決定)
    static func from(pdf document: PDFDocument) -> ComicInfo? {
        let attrs = document.documentAttributes ?? [:]
        func attr(_ key: PDFDocumentAttribute) -> String? {
            let value = (attrs[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }

        // Title/Author/Subject だけを写す。Producer/Creator は「出版社」ではなく
        // 生成ソフト名(例 "Skia/PDF"、"Microsoft Word")なので publisher に流用
        // しない。Keywords は NSArray の自由記述タグで genre とは意味が異なるため
        // 写さない(レビュー wf_c680e2ec-0af。誤ラベルを避け情報窓の正確性を保つ)
        var info = ComicInfo()
        info.documentTitle = attr(.titleAttribute)
        info.writer = attr(.authorAttribute)
        info.summary = attr(.subjectAttribute)
        info.pages = chapterPages(from: document)

        let hasContent = info.documentTitle != nil || info.writer != nil
            || info.summary != nil || !info.pages.isEmpty
        return hasContent ? info : nil
    }

    /// アウトライン訪問数の上限(循環/過大アウトライン対策。実在の目次には十分)
    private static let maxOutlineItems = 5000

    /// アウトライン(目次)を文書順に平坦化して pages[bookmark] へ写像する。
    /// 空ラベル・宛先なしは除外。循環/過大アウトライン対策で訪問数を上限で打ち切る
    private static func chapterPages(from document: PDFDocument) -> [PageInfo] {
        guard let root = document.outlineRoot else { return [] }
        // 深さ優先・文書順(pre-order)。子を逆順に積んで pop 時に先頭から出す
        func children(of node: PDFOutline) -> [PDFOutline] {
            (0..<node.numberOfChildren).reversed().compactMap { node.child(at: $0) }
        }
        var stack = children(of: root)
        var pages: [PageInfo] = []
        var visited = 0
        while let node = stack.popLast(), visited < maxOutlineItems {
            visited += 1
            if let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty, let page = node.destination?.page {
                let index = document.index(for: page)
                if index >= 0, index < document.pageCount {
                    pages.append(PageInfo(image: index, bookmark: label))
                }
            }
            stack.append(contentsOf: children(of: node))
        }
        return pages
    }
}
