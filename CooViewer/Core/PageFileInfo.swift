import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「ファイル情報」パネルの表示行を組み立てる(旧実装に無い新規機能)。
/// 画像メタデータは ImageIO のプロパティから、実体ファイルの情報は
/// FileManager の属性から取る。表示(パネル)は UI 側の責務。
/// EN: Builds the rows of the File Info panel: image metadata via ImageIO,
/// EN: on-disk file facts via FileManager. Pure logic, unit-tested.
enum PageFileInfo {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// - Parameters:
    ///   - entryName: ページの表示名(拡張子付きファイル名)
    ///   - pathInBook: 本の中の相対パス(名前と同じなら行を省く)
    ///   - containerURL: ページの実体ファイル(単体画像はその画像、
    ///     書庫/PDF 内のページは書庫/PDF 本体)
    ///   - pageNumber: 表示用ページ番号(1 始まり)
    ///   - imageData: ページの元データ(取れないソースは nil)
    ///   - fallbackPixelSize: データが無いときの寸法(PDF のポイントサイズ等)
    static func rows(entryName: String, pathInBook: String, containerURL: URL,
                     pageNumber: Int, pageCount: Int,
                     imageData: Data?, fallbackPixelSize: CGSize?) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(label: String(localized: "File Name"), value: entryName))
        if pathInBook != entryName {
            rows.append(Row(label: String(localized: "Path in Book"),
                            value: pathInBook))
        }
        rows.append(Row(label: String(localized: "Page"),
                        value: "\(pageNumber) / \(pageCount)"))

        if let imageData {
            rows.append(contentsOf: imageRows(data: imageData))
            let formatted = ByteCountFormatter.string(
                fromByteCount: Int64(imageData.count), countStyle: .file)
            rows.append(Row(
                label: String(localized: "Data Size"),
                value: "\(formatted) (\(imageData.count.formatted()) B)"))
        } else if let size = fallbackPixelSize {
            rows.append(Row(label: String(localized: "Dimensions"),
                            value: "\(Int(size.width)) × \(Int(size.height))"))
        }

        rows.append(contentsOf: containerRows(url: containerURL))
        return rows
    }

    /// 画像データのメタデータ行(形式・寸法・フレーム数・深度・色・DPI)
    /// EN: Metadata rows decoded from the raw image data.
    private static func imageRows(data: Data) -> [Row] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return []
        }
        var rows: [Row] = []
        if let typeID = CGImageSourceGetType(source) as String? {
            let description = UTType(typeID)?.localizedDescription ?? typeID
            rows.append(Row(label: String(localized: "Format"), value: description))
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] ?? [:]
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            rows.append(Row(label: String(localized: "Dimensions"),
                            value: "\(width) × \(height)"))
        }
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            rows.append(Row(label: String(localized: "Frames"),
                            value: "\(frameCount)"))
        }
        if let depth = properties[kCGImagePropertyDepth] as? Int {
            rows.append(Row(label: String(localized: "Bit Depth"),
                            value: "\(depth)"))
        }
        if let model = properties[kCGImagePropertyColorModel] as? String {
            rows.append(Row(label: String(localized: "Color Model"), value: model))
        }
        if let profile = properties[kCGImagePropertyProfileName] as? String {
            rows.append(Row(label: String(localized: "Color Profile"),
                            value: profile))
        }
        if let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool {
            rows.append(Row(label: String(localized: "Alpha Channel"),
                            value: hasAlpha ? String(localized: "Yes")
                                            : String(localized: "No")))
        }
        if let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi > 0 {
            rows.append(Row(label: String(localized: "Resolution"),
                            value: "\(Int(dpi)) dpi"))
        }
        return rows
    }

    /// 実体ファイル(単体画像/書庫/PDF)のディスク上の情報行
    /// EN: On-disk facts for the containing file.
    private static func containerRows(url: URL) -> [Row] {
        var rows: [Row] = []
        rows.append(Row(label: String(localized: "Location"), value: url.path))
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path) else { return rows }
        if let size = attributes[.size] as? Int64 {
            let formatted = ByteCountFormatter.string(fromByteCount: size,
                                                      countStyle: .file)
            rows.append(Row(
                label: String(localized: "File Size"),
                value: "\(formatted) (\(size.formatted()) B)"))
        }
        if let created = attributes[.creationDate] as? Date {
            rows.append(Row(
                label: String(localized: "Created"),
                value: created.formatted(date: .abbreviated, time: .standard)))
        }
        if let modified = attributes[.modificationDate] as? Date {
            rows.append(Row(
                label: String(localized: "Modified"),
                value: modified.formatted(date: .abbreviated, time: .standard)))
        }
        return rows
    }
}
