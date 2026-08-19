import Foundation

/// cbz ルートの `ComicInfo.xml`(ComicRack/Komga/Kavita 系の事実上標準メタデータ)を
/// **read-only** で表す値型(設計書 §2.4・cooViewer-4fi)。全フィールド任意で、
/// 欠損・壊れは nil / 既定へ fail-soft。取得したメタデータは常に「ヒント」であり、
/// ユーザー設定を上書きしない(適用側の責務)。
struct ComicInfo: Sendable, Equatable {
    var title: String?
    var series: String?
    var number: String?        // "1" / "1.5" 等があるため文字列で保持
    var count: Int?            // シリーズ総数
    var volume: Int?
    var summary: String?
    var writer: String?
    var penciller: String?
    var inker: String?
    var colorist: String?
    var letterer: String?
    var coverArtist: String?
    var publisher: String?
    var genre: String?
    var web: String?
    var pageCount: Int?        // 参考値。実ページ数を正とする
    var languageISO: String?
    var ageRating: String?
    var manga: Manga = .unknown
    var pages: [PageInfo] = []

    /// 読み方向のヒント(§2.4)。標準に明確な LTR フラグは無く No を LTR 寄せに使う
    enum Manga: Sendable, Equatable {
        case unknown, no, yes, yesAndRightToLeft

        /// 右→左 なら true、明示 LTR(No)なら false、不明は nil
        var readsRightToLeft: Bool? {
            switch self {
            case .yesAndRightToLeft: true
            case .no: false
            case .yes, .unknown: nil
            }
        }

        static func from(_ raw: String) -> Manga {
            switch raw.lowercased() {
            case "yesandrighttoleft": .yesAndRightToLeft
            case "yes": .yes
            case "no": .no
            default: .unknown
            }
        }
    }

    /// `<Page Type="...">` の種別(見開き判定の補助に使う。Phase 2 で FrontCover→
    /// 表紙単ページ化など)
    enum PageType: Sendable, Equatable {
        case frontCover, innerCover, roundup, story, advertisement,
             editorial, letters, preview, backCover, other, deleted

        static func from(_ raw: String) -> PageType? {
            switch raw.lowercased() {
            case "frontcover": .frontCover
            case "innercover": .innerCover
            case "roundup": .roundup
            case "story": .story
            case "advertisement": .advertisement
            case "editorial": .editorial
            case "letters": .letters
            case "preview": .preview
            case "backcover": .backCover
            case "other": .other
            case "deleted": .deleted
            default: nil
            }
        }
    }

    /// `<Pages><Page .../></Pages>` の 1 要素。image は 0 始まりのページ番号
    struct PageInfo: Sendable, Equatable {
        var image: Int
        var type: PageType? = nil
        var doublePage: Bool = false
        var bookmark: String? = nil    // 章名(目次ナビに使う。cooViewer-4fi.6)
    }

    /// ウインドウ表示用のタイトル(Series 優先、無ければ Title、両方無ければ nil)。
    /// 例: "シリーズ名 Vol.2 – 章タイトル" / "シリーズ名 #3"。ファイル名への
    /// フォールバックは呼び出し側の既定(cooViewer-4fi.3)
    var displayTitle: String? {
        func trimmed(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let series = trimmed(series)
        let title = trimmed(title)
        var head: [String] = []
        if let series { head.append(series) }
        if let volume {
            head.append("Vol.\(volume)")
        } else if let number = trimmed(number) {
            head.append("#\(number)")
        }
        let headText = head.joined(separator: " ")
        if let title, title != series {
            return headText.isEmpty ? title : headText + " – " + title
        }
        return headText.isEmpty ? nil : headText
    }

    /// 章/目次(Pages の Bookmark が付いたページ)。image 昇順・空名は除く。
    /// 実ページへの写像・PageCount ズレ耐性は消費側(§4fi.6)で担保する
    var chapters: [(image: Int, name: String)] {
        pages.compactMap { page in
            guard let name = page.bookmark, !name.isEmpty else { return nil }
            return (page.image, name)
        }
        .sorted { $0.image < $1.image }
    }
}

extension ComicInfo {
    /// `ComicInfo.xml` のバイト列を解析する。壊れている / ルートが ComicInfo でない /
    /// 意味のあるフィールドが 1 つも無いときは nil を返す。
    /// Foundation の XMLParser は **ObjC 例外を投げず** false を返すため Swift で
    /// 安全に扱える(旧 NSUnarchiver の捕捉不能例外による起動クラッシュ=b19 の
    /// 教訓に沿い、パーサは fail-soft を厳守する)。
    static func parse(_ data: Data) -> ComicInfo? {
        let delegate = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot, delegate.anySet else { return nil }
        return delegate.info
    }
}

/// XMLParser デリゲート。単一の同期解析内でのみ使う(actor 境界を越えない)。
/// 既知の上位要素はテキスト、`<Page>` は属性から読む。未知要素は無視する
private final class Reader: NSObject, XMLParserDelegate {
    var info = ComicInfo()
    var sawRoot = false
    var anySet = false
    private var buffer = ""
    private var depthInsidePages = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        buffer = ""
        switch elementName.lowercased() {
        case "comicinfo":
            sawRoot = true
        case "pages":
            depthInsidePages += 1
        case "page" where depthInsidePages > 0:
            if let page = Self.page(from: attributeDict) {
                info.pages.append(page)
                anySet = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "pages" {
            depthInsidePages = max(0, depthInsidePages - 1)
            return
        }
        // Page の中身は属性で処理済み。Pages 内の要素本文は無視する
        if depthInsidePages > 0 { return }

        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !text.isEmpty else { return }

        switch name {
        case "title": info.title = text
        case "series": info.series = text
        case "number": info.number = text
        case "count": info.count = Int(text)
        case "volume": info.volume = Int(text)
        case "summary": info.summary = text
        case "writer": info.writer = text
        case "penciller": info.penciller = text
        case "inker": info.inker = text
        case "colorist": info.colorist = text
        case "letterer": info.letterer = text
        case "coverartist": info.coverArtist = text
        case "publisher": info.publisher = text
        case "genre": info.genre = text
        case "web": info.web = text
        case "pagecount": info.pageCount = Int(text)
        case "languageiso": info.languageISO = text
        case "agerating": info.ageRating = text
        case "manga": info.manga = ComicInfo.Manga.from(text)
        default:
            return  // 未知要素は anySet を立てない
        }
        anySet = true
    }

    /// `<Page>` 属性から PageInfo を組む。属性名は大小無視。Image 必須(無ければ skip)
    private static func page(from attrs: [String: String]) -> ComicInfo.PageInfo? {
        var lower: [String: String] = [:]
        for (key, value) in attrs { lower[key.lowercased()] = value }
        guard let imageRaw = lower["image"], let image = Int(imageRaw) else { return nil }
        let doublePage: Bool = {
            guard let raw = lower["doublepage"]?.lowercased() else { return false }
            return raw == "true" || raw == "1"
        }()
        let bookmark = lower["bookmark"].flatMap { $0.isEmpty ? nil : $0 }
        let type = lower["type"].flatMap(ComicInfo.PageType.from)
        return ComicInfo.PageInfo(image: image, type: type,
                                  doublePage: doublePage, bookmark: bookmark)
    }
}
