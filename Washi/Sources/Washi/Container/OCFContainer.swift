import Foundation

/// EPUB を開く際のエラー
public enum EPUBError: Error, Sendable {
    /// EPUB として認識できない(ZIP でない・container.xml がない等)
    case notAnEPUB(String)
    /// 必須構成ファイルの解析に失敗
    case malformed(String)
    /// コンテナ内に指定リソースがない
    case resourceNotFound(String)
    /// DRM(鍵を持たない暗号化)で保護されており読めない
    case drmProtected(scheme: String)
}

/// OCF 抽象コンテナ(仕様 EPUB 3.3 OCF §3)。
/// ZIP(.epub)と展開済みフォルダの両方を同じ読み取り API で扱う。
/// パスは「/ 区切り・ルート相対・デコード済み」の正規形。
protocol ContainerReader: Sendable {
    func exists(_ path: String) -> Bool
    func read(_ path: String) throws -> Data
    /// コンテナ内の全ファイルパス(ディレクトリ除く)
    var allPaths: [String] { get }
}

/// ZIP(.epub ファイル)のコンテナ
struct ZipContainerReader: ContainerReader {
    let archive: ZipArchive

    var allPaths: [String] {
        archive.entries.filter { !$0.isDirectory }.map(\.name)
    }

    func exists(_ path: String) -> Bool { archive.contains(path) }

    func read(_ path: String) throws -> Data {
        do {
            return try archive.data(forEntry: path)
        } catch ZipError.entryNotFound {
            throw EPUBError.resourceNotFound(path)
        }
    }
}

/// 展開済みフォルダのコンテナ(開発時・解凍済み配布物向け)
struct FolderContainerReader: ContainerReader {
    let rootURL: URL

    var allPaths: [String] {
        let root = rootURL.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if full.hasPrefix(prefix) {
                paths.append(String(full.dropFirst(prefix.count)))
            }
        }
        return paths.sorted()
    }

    /// コンテナ外への脱出参照でないことの検証(フォルダ実装だけが実 FS に
    /// 触れるため、".." 成分・絶対パス・空を明示的に拒否する。
    /// normalize の同値比較では ".." が残った脱出パスを見逃す)
    private func isSafeContainerPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/")
        return !components.isEmpty
            && !components.contains("..") && !components.contains(".")
    }

    func exists(_ path: String) -> Bool {
        guard isSafeContainerPath(path) else { return false }
        var isDirectory: ObjCBool = false
        let url = rootURL.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    func read(_ path: String) throws -> Data {
        guard isSafeContainerPath(path) else {
            throw EPUBError.resourceNotFound(path)
        }
        let url = rootURL.appendingPathComponent(path)
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw EPUBError.resourceNotFound(path)
        }
    }
}

/// OCF コンテナのルート構成(mimetype / META-INF/container.xml)を検証・解析する
struct OCFContainer: Sendable {
    let reader: any ContainerReader
    /// container.xml の rootfile(先頭がデフォルトのパッケージ文書。OCF §3.5.2.1)
    let packageDocumentPaths: [String]

    init(reader: any ContainerReader) throws {
        self.reader = reader

        // mimetype はあれば検証する(なくても開く: RS には寛容さが許される。
        // ZIP 圧縮済みでも中身が正しければ受け入れる)
        if reader.exists("mimetype") {
            let mimetype = (try? reader.read("mimetype")).flatMap {
                String(data: $0, encoding: .utf8)
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mimetype, mimetype != EPUBMediaType.epub {
                throw EPUBError.notAnEPUB("mimetype が \(mimetype)")
            }
        }

        let containerXMLPath = "META-INF/container.xml"
        guard reader.exists(containerXMLPath) else {
            throw EPUBError.notAnEPUB("META-INF/container.xml がない")
        }
        let document = try WashiXML.document(from: reader.read(containerXMLPath))
        guard let root = document.rootElement() else {
            throw EPUBError.malformed(containerXMLPath)
        }
        let rootfiles = root
            .wsFirst("rootfiles", ns: XMLNamespace.container)?
            .wsChildren("rootfile", ns: XMLNamespace.container) ?? []
        let paths = rootfiles.compactMap { element -> String? in
            guard element.attr("media-type") == EPUBMediaType.opf
                    || element.attr("media-type") == nil else { return nil }
            return element.attr("full-path").map(ContainerPath.normalize)
        }
        guard !paths.isEmpty else {
            throw EPUBError.malformed("container.xml に rootfile がない")
        }
        self.packageDocumentPaths = paths
    }
}
