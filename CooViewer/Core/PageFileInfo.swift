import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「ファイル情報」パネルの内容を組み立てる(旧実装に無い新規機能)。
/// 画像メタデータ(EXIF/GPS 含む)は ImageIO のプロパティから、実体ファイルの
/// 情報は FileManager の属性から取る。表示(パネル)は UI 側の責務。
/// EN: Builds the File Info panel content: image metadata (EXIF/GPS included)
/// EN: via ImageIO, on-disk file facts via FileManager. Pure logic, unit-tested.
enum PageFileInfo {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    /// 見出し付きの行グループ(先頭セクションのみ無題)
    /// EN: Titled group of rows; only the leading section is untitled.
    struct Section: Equatable {
        let title: String?
        let rows: [Row]
    }

    struct Details: Equatable {
        let sections: [Section]
        /// GPS 座標(EXIF に位置情報があるときのみ。地図表示用)
        /// EN: Signed GPS coordinate when present, for the map view.
        let latitude: Double?
        let longitude: Double?
    }

    /// - Parameters:
    ///   - entryName: ページの表示名(拡張子付きファイル名)
    ///   - pathInBook: 本の中の相対パス(名前と同じなら行を省く)
    ///   - containerURL: ページの実体ファイル(単体画像はその画像、
    ///     書庫/PDF 内のページは書庫/PDF 本体)
    ///   - pageNumber: 表示用ページ番号(1 始まり)
    ///   - imageData: ページの元データ(取れないソースは nil)
    ///   - fallbackPixelSize: データが無いときの寸法(PDF のポイントサイズ等)
    static func details(entryName: String, pathInBook: String, containerURL: URL,
                        pageNumber: Int, pageCount: Int,
                        imageData: Data?, fallbackPixelSize: CGSize?) -> Details {
        var sections: [Section] = []

        var pageRows: [Row] = [
            Row(label: String(localized: "File Name"), value: entryName)
        ]
        if pathInBook != entryName {
            pageRows.append(Row(label: String(localized: "Path in Book"),
                                value: pathInBook))
        }
        pageRows.append(Row(label: String(localized: "Page"),
                            value: "\(pageNumber) / \(pageCount)"))
        sections.append(Section(title: nil, rows: pageRows))

        var latitude: Double?
        var longitude: Double?
        if let imageData,
           let source = CGImageSourceCreateWithData(imageData as CFData, nil) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] ?? [:]
            sections.append(Section(
                title: String(localized: "Image"),
                rows: imageRows(source: source, properties: properties,
                                dataSize: imageData.count)))
            let exif = exifRows(properties: properties)
            if !exif.isEmpty {
                sections.append(Section(title: "EXIF", rows: exif))
            }
            if let gps = gpsSection(properties: properties) {
                sections.append(gps.section)
                latitude = gps.latitude
                longitude = gps.longitude
            }
        } else if let size = fallbackPixelSize {
            sections.append(Section(
                title: String(localized: "Image"),
                rows: [Row(label: String(localized: "Dimensions"),
                           value: "\(Int(size.width)) × \(Int(size.height))")]))
        }

        sections.append(Section(title: String(localized: "File"),
                                rows: containerRows(url: containerURL)))
        return Details(sections: sections, latitude: latitude,
                       longitude: longitude)
    }

    // MARK: - 画像メタデータ

    private static func imageRows(source: CGImageSource,
                                  properties: [CFString: Any],
                                  dataSize: Int) -> [Row] {
        var rows: [Row] = []
        if let typeID = CGImageSourceGetType(source) as String? {
            let description = UTType(typeID)?.localizedDescription ?? typeID
            rows.append(Row(label: String(localized: "Format"), value: description))
        }
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
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(dataSize),
                                                  countStyle: .file)
        rows.append(Row(label: String(localized: "Data Size"),
                        value: "\(formatted) (\(dataSize.formatted()) B)"))
        return rows
    }

    // MARK: - EXIF

    private static func exifRows(properties: [CFString: Any]) -> [Row] {
        let exif = properties[kCGImagePropertyExifDictionary]
            as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary]
            as? [CFString: Any] ?? [:]
        guard !exif.isEmpty || !tiff.isEmpty else { return [] }
        var rows: [Row] = []

        if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            rows.append(Row(label: String(localized: "Date Taken"),
                            value: formatExifDate(raw)))
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?
            .trimmingCharacters(in: .whitespaces)
        // 機種名にメーカー名が含まれる場合は重ねない(例: "Canon EOS R5")
        // EN: Skip the make when the model already starts with it.
        if let model {
            let camera: String
            if let make, !model.lowercased().hasPrefix(make.lowercased()) {
                camera = "\(make) \(model)"
            } else {
                camera = model
            }
            rows.append(Row(label: String(localized: "Camera"), value: camera))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String {
            rows.append(Row(label: String(localized: "Lens"), value: lens))
        }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            let value = time < 1
                ? "1/\(Int((1 / time).rounded())) s"
                : "\(formatNumber(time)) s"
            rows.append(Row(label: String(localized: "Exposure Time"), value: value))
        }
        if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double, fNumber > 0 {
            rows.append(Row(label: String(localized: "Aperture"),
                            value: "f/\(formatNumber(fNumber))"))
        }
        if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
           let iso = isoValues.first as? Int {
            rows.append(Row(label: String(localized: "ISO"), value: "\(iso)"))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double, focal > 0 {
            var value = "\(formatNumber(focal)) mm"
            if let film = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int,
               film > 0, Double(film) != focal {
                value += " (35mm: \(film) mm)"
            }
            rows.append(Row(label: String(localized: "Focal Length"), value: value))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
            rows.append(Row(label: String(localized: "Software"), value: software))
        }
        return rows
    }

    /// EXIF の "yyyy:MM:dd HH:mm:ss" をローカライズ表示に直す(失敗時は原文)
    /// EN: Reformat the EXIF timestamp; falls back to the raw string.
    private static func formatExifDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    // MARK: - GPS

    private static func gpsSection(properties: [CFString: Any])
        -> (section: Section, latitude: Double, longitude: Double)? {
        let gps = properties[kCGImagePropertyGPSDictionary]
            as? [CFString: Any] ?? [:]
        guard let rawLatitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let rawLongitude = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
        let latitude = latitudeRef == "S" ? -rawLatitude : rawLatitude
        let longitude = longitudeRef == "W" ? -rawLongitude : rawLongitude

        var rows: [Row] = [
            Row(label: String(localized: "Latitude"),
                value: latitude.formatted(.number.precision(.fractionLength(0...6)))),
            Row(label: String(localized: "Longitude"),
                value: longitude.formatted(.number.precision(.fractionLength(0...6)))),
        ]
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            let belowSea = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
            let signed = belowSea ? -altitude : altitude
            rows.append(Row(label: String(localized: "Altitude"),
                            value: "\(formatNumber(signed)) m"))
        }
        return (Section(title: String(localized: "GPS"), rows: rows),
                latitude, longitude)
    }

    // MARK: - 実体ファイル

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

    private static func formatNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
