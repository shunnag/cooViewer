import Foundation

/// An error raised while opening or reading an EPUB.
public enum EPUBError: Error, Sendable, Equatable, LocalizedError {
    /// The file is not a recognizable EPUB (not a ZIP, no container.xml, …).
    /// The associated string names what failed the check.
    case notAnEPUB(String)
    /// A required structural file could not be parsed. The associated string
    /// names the file or the specific defect.
    case malformed(String)
    /// The named resource does not exist in the container.
    case resourceNotFound(String)
    /// The content is DRM-protected with a scheme Washi cannot decrypt.
    /// `scheme` names the detected DRM (e.g. "Readium LCP").
    case drmProtected(scheme: String)

    public var errorDescription: String? {
        switch self {
        case .notAnEPUB(let detail):
            return "Not a valid EPUB: \(detail)"
        case .malformed(let detail):
            return "Malformed EPUB: \(detail)"
        case .resourceNotFound(let path):
            return "Resource not found in the EPUB: \(path)"
        case .drmProtected(let scheme):
            return "This book is DRM-protected (\(scheme)) and cannot be opened."
        }
    }
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
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            // シンボリックリンクは列挙しない(コンテナ外の実体を「コンテナ内
            // リソース」として晒さない。read 側の実体検証と対)
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                values.isSymbolicLink != true, values.isRegularFile == true
            else { continue }
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

    /// パス成分は安全でも、途中のシンボリックリンクが実体をコンテナ外へ
    /// 逃がしている場合を拒否する(~/.ssh 等をスキームハンドラ経由で
    /// 読ませない)。実体パスを解決してルート配下であることを検証する
    private func isInsideContainer(_ url: URL) -> Bool {
        let resolvedRoot = rootURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved == resolvedRoot
            || resolved.hasPrefix(resolvedRoot.hasSuffix("/")
                ? resolvedRoot : resolvedRoot + "/")
    }

    func exists(_ path: String) -> Bool {
        guard isSafeContainerPath(path) else { return false }
        var isDirectory: ObjCBool = false
        let url = rootURL.appendingPathComponent(path)
        return isInsideContainer(url)
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    func read(_ path: String) throws -> Data {
        guard isSafeContainerPath(path) else {
            throw EPUBError.resourceNotFound(path)
        }
        let url = rootURL.appendingPathComponent(path)
        guard isInsideContainer(url) else {
            throw EPUBError.resourceNotFound(path)
        }
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
