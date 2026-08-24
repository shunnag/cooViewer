import Foundation

/// Path arithmetic within an OCF abstract container.
/// A container-internal path is canonical when it is "/-separated, has no
/// leading slash, and is percent-decoded" (a form that can be compared directly
/// against ZIP entry names).
/// When resolving from an href (a URI reference), the fragment and query are
/// stripped and `../` segments are collapsed.
public enum ContainerPath {
    /// Resolves a relative href against `base` (a file path inside the container).
    /// Returns the canonical container-internal path, or nil for references that
    /// escape the container (above the root) or for absolute URLs (http:, etc.).
    public static func resolve(base: String, href: String) -> String? {
        // フラグメント・クエリを除去
        var reference = href
        if let hash = reference.firstIndex(of: "#") {
            reference = String(reference[..<hash])
        }
        if let query = reference.firstIndex(of: "?") {
            reference = String(reference[..<query])
        }
        guard !reference.isEmpty else { return normalize(base) }
        // スキーム付き(http: 等)はコンテナ内リソースではない
        if reference.contains(":") { return nil }
        let decoded = reference.removingPercentEncoding ?? reference

        let joined: String
        if decoded.hasPrefix("/") {
            // ルート相対(仕様外だが実在する)はコンテナルートからの絶対とみなす
            joined = String(decoded.dropFirst())
        } else {
            let baseDir = directory(of: normalize(base))
            joined = baseDir.isEmpty ? decoded : baseDir + "/" + decoded
        }
        return collapse(joined)
    }

    /// Normalizes a path (percent-decode plus `../` collapse).
    /// A reference that escapes the root becomes the empty string (treated as a
    /// "nonexistent path", so it cannot be used for out-of-container reads in
    /// ``FolderContainerReader`` and the like).
    public static func normalize(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        return collapse(decoded) ?? ""
    }

    /// Normalizes an already-decoded path (collapse only). A container-internal
    /// path is canonical in its already-decoded form, so use this to avoid a
    /// double decode, which would corrupt files whose names contain a `%`.
    public static func sanitize(_ path: String) -> String {
        collapse(path) ?? ""
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// "a/./b/../c" → "a/c"。ルートより上へ出たら nil
    private static func collapse(_ path: String) -> String? {
        var stack: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            default:
                stack.append(component)
            }
        }
        return stack.joined(separator: "/")
    }
}
