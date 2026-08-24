import Foundation

/// メディアオーバーレイ(EPUB 3 Media Overlays、SMIL サブセット)のモデル。
/// 現状はパースのみ提供し、再生エンジンは持たない(EPUB RS 3.3 §9 は
/// 音声再生能力のない RS に SMIL の無視を許している。将来の拡張点)
public struct MediaOverlay: Sendable {
    /// par: テキスト断片と音声クリップの同期対
    public struct Parallel: Sendable {
        /// 対応するコンテンツ文書の href(フラグメント込み・SMIL からの相対)
        public let textHref: String?
        /// 音声ファイルの href
        public let audioHref: String?
        /// クリップ開始秒(省略時 0)
        public let clipBegin: Double
        /// クリップ終了秒(省略時 = メディア末尾)
        public let clipEnd: Double?
        /// epub:type(skippability 判定用: footnote / pagebreak 等)
        public let epubType: String?
    }

    /// 再生順に平坦化した par 列
    public let parallels: [Parallel]
    /// SMIL 文書のコンテナ内パス(href 解決の基準)
    public let basePath: String
}

enum SMILParser {
    static func parse(data: Data, at containerPath: String) throws -> MediaOverlay {
        let document = try WashiXML.document(from: data)
        guard let root = document.rootElement() else {
            throw EPUBError.malformed("SMIL が壊れている: \(containerPath)")
        }
        var parallels: [MediaOverlay.Parallel] = []
        collectParallels(in: root, into: &parallels)
        return MediaOverlay(parallels: parallels, basePath: containerPath)
    }

    private static func collectParallels(
        in element: XMLElement, into result: inout [MediaOverlay.Parallel]) {
        for node in element.children ?? [] {
            guard let child = node as? XMLElement else { continue }
            if child.localName == "par" {
                let text = child.wsFirst("text", ns: XMLNamespace.smil)?.attr("src")
                let audio = child.wsFirst("audio", ns: XMLNamespace.smil)
                result.append(MediaOverlay.Parallel(
                    textHref: text,
                    audioHref: audio?.attr("src"),
                    clipBegin: audio?.attr("clipBegin")
                        .flatMap(parseClockValue) ?? 0,
                    clipEnd: audio?.attr("clipEnd").flatMap(parseClockValue),
                    epubType: child.attr("type", ns: XMLNamespace.epubOps,
                                         prefix: "epub")))
            } else {
                // seq(と body)は再帰的に順序どおり平坦化する
                collectParallels(in: child, into: &result)
            }
        }
    }

    /// SMIL クロック値("12.5s" / "1:02:03.5" / "02:03" / "1250ms")→ 秒
    static func parseClockValue(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("ms") {
            return Double(trimmed.dropLast(2)).map { $0 / 1000 }
        }
        if trimmed.hasSuffix("s") {
            return Double(trimmed.dropLast())
        }
        if trimmed.hasSuffix("min") {
            return Double(trimmed.dropLast(3)).map { $0 * 60 }
        }
        if trimmed.hasSuffix("h") {
            return Double(trimmed.dropLast()).map { $0 * 3600 }
        }
        let parts = trimmed.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        case 1:
            return Double(parts[0])
        default:
            return nil
        }
    }
}

extension EPUBPublication {
    /// spine 項目に紐付くメディアオーバーレイを読み込む(なければ nil)
    public func mediaOverlay(forSpineIndex index: Int) -> MediaOverlay? {
        guard readingOrder.indices.contains(index) else { return nil }
        let entry = readingOrder[index]
        guard let overlayID = entry.item.mediaOverlay,
              let overlayItem = package.manifestByID[overlayID],
              let path = containerPath(forHref: overlayItem.href,
                                       relativeTo: package.path),
              let data = try? resource(at: path).data else { return nil }
        return try? SMILParser.parse(data: data, at: path)
    }
}
