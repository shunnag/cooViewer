import Foundation

/// ページ進行方向(仕様 EPUB 3.3 §5.5 spine の page-progression-direction)。
/// 日本語縦組み本は rtl(右綴じ・右→左へページが進む)
public enum PageProgressionDirection: String, Sendable {
    case ltr
    case rtl
    /// 属性省略時(言語・書字方向から RS が決めてよい)
    case byDefault = "default"
}

/// rendition:layout(EPUB 3.3 §D.3.2)
public enum RenditionLayout: String, Sendable {
    case reflowable
    case prePaginated = "pre-paginated"
}

/// rendition:orientation
public enum RenditionOrientation: String, Sendable {
    case auto, landscape, portrait
}

/// rendition:spread(見開き合成の可否。portrait は 3.3 で廃止 → both 扱い)
public enum RenditionSpread: String, Sendable {
    case auto, none, landscape, both
}

/// rendition:flow(リフロー時のスクロール方式)
public enum RenditionFlow: String, Sendable {
    case auto, paginated
    case scrolledContinuous = "scrolled-continuous"
    case scrolledDoc = "scrolled-doc"
}

/// 題名(title-type refine 付き)
public struct EPUBTitle: Sendable, Hashable {
    public let value: String
    /// main / subtitle / short / collection / edition / expanded
    public let type: String?
    public let fileAs: String?
    public let displaySeq: Int?
}

/// 著者・寄与者(role refine 付き)
public struct EPUBCreator: Sendable, Hashable {
    public let value: String
    /// MARC relator code(aut / ill / trl 等)
    public let role: String?
    public let fileAs: String?
    public let displaySeq: Int?
}

/// dc:identifier
public struct EPUBIdentifier: Sendable, Hashable {
    public let value: String
    public let id: String?
    /// identifier-type や scheme の refine 値
    public let scheme: String?
}

/// belongs-to-collection(シリーズ情報。EPUB 3.3 §D.4.1)
public struct EPUBCollectionMembership: Sendable, Hashable {
    public let name: String
    /// collection-type refine(series / set 等)
    public let type: String?
    public let groupPosition: String?
}

/// 一般 meta(canonical 化した property 名で保持)
public struct EPUBMetaItem: Sendable, Hashable {
    /// 既知 vocab は「rendition:layout」のような接頭辞形へ正規化済み
    public let property: String
    public let value: String
    /// refines 先の要素 id(# なし)。文書全体への meta は nil
    public let refines: String?
    public let scheme: String?
}

/// rendition プロパティ一式(文書全体のデフォルト)
public struct RenditionProperties: Sendable {
    public var layout: RenditionLayout = .reflowable
    public var orientation: RenditionOrientation = .auto
    public var spread: RenditionSpread = .auto
    public var flow: RenditionFlow = .auto
    /// 廃止済み rendition:viewport(3.0 の遺物。FXL の既定ビューポート)
    public var viewport: String?
}

/// パッケージ文書のメタデータ(DCMES + refines を解決済み)
public struct EPUBMetadata: Sendable {
    public var titles: [EPUBTitle] = []
    public var creators: [EPUBCreator] = []
    public var contributors: [EPUBCreator] = []
    public var publishers: [String] = []
    public var languages: [String] = []
    public var identifiers: [EPUBIdentifier] = []
    /// unique-identifier 属性が指す dc:identifier の値
    public var uniqueIdentifier: String?
    /// dcterms:modified(ISO 8601 文字列のまま保持)
    public var modified: String?
    public var date: String?
    public var description: String?
    public var rights: String?
    public var subjects: [String] = []
    public var collections: [EPUBCollectionMembership] = []
    public var rendition = RenditionProperties()
    /// 解決しきらなかったものも含む全 meta(拡張用)
    public var metaItems: [EPUBMetaItem] = []

    /// 表示用の主題名(title-type=main を優先、なければ最初の title)
    public var mainTitle: String? {
        titles.first { $0.type == "main" }?.value ?? titles.first?.value
    }

    /// リリース識別子(unique-identifier + modified。EPUB 3.3 §5.2.3)。
    /// フォント難読化の鍵導出にも使う一意識別子はこちらではなく uniqueIdentifier
    public var releaseIdentifier: String? {
        guard let uniqueIdentifier else { return nil }
        guard let modified else { return uniqueIdentifier }
        return uniqueIdentifier + "@" + modified
    }
}

/// マニフェスト項目
public struct ManifestItem: Sendable, Hashable {
    public let id: String
    /// パッケージ文書からの相対 href(記載どおり。コンテナ内パスは Publication が解決)
    public let href: String
    public let mediaType: String
    /// nav / cover-image / scripted / svg / mathml / remote-resources / switch
    public let properties: Set<String>
    /// フォールバック先の item id(コアメディア型でない項目用。EPUB 3.3 §5.6)
    public let fallback: String?
    /// メディアオーバーレイ(SMIL)の item id
    public let mediaOverlay: String?
}

/// spine の 1 項目
public struct SpineItemRef: Sendable, Hashable {
    public let idref: String
    /// linear="no" は補助コンテンツ(既定 true)
    public let linear: Bool
    /// page-spread-left / page-spread-right / rendition:page-spread-center /
    /// rendition:* の項目単位オーバーライド等(canonical 化済み)
    public let properties: Set<String>
}

/// spine 全体
public struct EPUBSpine: Sendable {
    public let itemRefs: [SpineItemRef]
    public let pageProgressionDirection: PageProgressionDirection
    /// EPUB 2 互換の NCX を指す item id(toc 属性)
    public let tocItemID: String?
}

/// パッケージ文書(OPF)の解析結果
public struct EPUBPackage: Sendable {
    /// version 属性("3.0" / "2.0" 等、記載のまま)
    public let version: String
    public let metadata: EPUBMetadata
    public let manifest: [ManifestItem]
    public let manifestByID: [String: ManifestItem]
    public let spine: EPUBSpine
    /// パッケージ文書自身のコンテナ内パス(href 解決の基準)
    public let path: String

    /// EPUB 3 ナビゲーション文書(properties="nav")
    public var navItem: ManifestItem? {
        manifest.first { $0.properties.contains("nav") }
    }

    /// カバー画像(EPUB 3 properties="cover-image" → EPUB 2 meta name="cover")
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

    /// 文書全体が固定レイアウトか
    public var isFixedLayout: Bool {
        metadata.rendition.layout == .prePaginated
    }

    /// spine 項目単位の実効レイアウト(itemref の rendition:layout-* オーバーライド)
    public func effectiveLayout(for itemRef: SpineItemRef) -> RenditionLayout {
        if itemRef.properties.contains("rendition:layout-pre-paginated") {
            return .prePaginated
        }
        if itemRef.properties.contains("rendition:layout-reflowable") {
            return .reflowable
        }
        return metadata.rendition.layout
    }

    /// 実効ページ進行方向(default は言語から推定: 日本語=縦書き文化圏でも
    /// 既定は ltr が仕様。明示 rtl のみ右綴じにする)
    public var readingDirection: PageProgressionDirection {
        spine.pageProgressionDirection
    }
}
