import Foundation

/// Model of a media overlay (EPUB 3 Media Overlays, a SMIL subset).
/// Currently offers parsing only, with no playback engine (EPUB RS 3.3 §9
/// allows a RS without audio-playback capability to ignore SMIL; a future
/// extension point).
public struct MediaOverlay: Sendable {
    /// par: a synchronization pair of a text fragment and an audio clip.
    public struct Parallel: Sendable {
        /// href of the corresponding content document (fragment included, relative to the SMIL).
        public let textHref: String?
        /// href of the audio file.
        public let audioHref: String?
        /// Clip start in seconds (0 when omitted).
        public let clipBegin: Double
        /// Clip end in seconds (end of media when omitted).
        public let clipEnd: Double?
        /// epub:type (used to decide skippability: footnote / pagebreak, etc.).
        public let epubType: String?
    }

    /// The par entries flattened into playback order.
    public let parallels: [Parallel]
    /// Container-internal path of the SMIL document (the base for href resolution).
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

    /// SMIL クロック値("12.5s" / "1:02:03.5" / "02:03" / "1250ms")→ 秒。
    /// NaN・Inf・負値(細工/雑な SMIL の "nan"・"1e999s"・"-5s" 等)は nil を返し
    /// 省略扱いにする — AVAudioPlayer.currentTime へ不正値を渡すとシーク破綻・
    /// クリップ終端判定の恒偽化(ティッカーの空回り)を招くため
    static func parseClockValue(_ text: String) -> Double? {
        // NaN は `>= 0` が false になるので、この 1 つの検査で NaN/Inf/負を弾ける
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return value
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("ms") {
            return valid(Double(trimmed.dropLast(2)).map { $0 / 1000 })
        }
        if trimmed.hasSuffix("s") {
            return valid(Double(trimmed.dropLast()))
        }
        if trimmed.hasSuffix("min") {
            return valid(Double(trimmed.dropLast(3)).map { $0 * 60 })
        }
        if trimmed.hasSuffix("h") {
            return valid(Double(trimmed.dropLast()).map { $0 * 3600 })
        }
        let parts = trimmed.split(separator: ":").map(String.init)
        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return valid(hours * 3600 + minutes * 60 + seconds)
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return valid(minutes * 60 + seconds)
        case 1:
            return valid(Double(parts[0]))
        default:
            return nil
        }
    }
}

extension EPUBPublication {
    /// Loads the media overlay associated with a spine item (nil if none).
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
