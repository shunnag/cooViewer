import Foundation

/// OCF 抽象コンテナ内のパス演算。
/// コンテナ内パスは「/ 区切り・先頭スラッシュなし・パーセントデコード済み」を
/// 正規形とする(ZIP エントリ名と直接比較できる形)。
/// href(URI 参照)からの解決時にフラグメント・クエリを外し、../ を折り畳む。
public enum ContainerPath {
    /// base(コンテナ内のファイルパス)から相対 href を解決する。
    /// 戻り値はコンテナ内正規形パス。コンテナ外(ルートより上)へ出る参照や
    /// 絶対 URL(http: 等)は nil。
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

    /// パスの正規化(パーセントデコード + ../ 折り畳み)。
    /// ルートを脱出する参照は空文字にする(「存在しないパス」として扱われ、
    /// FolderContainerReader 等でコンテナ外読み取りに使えない)
    public static func normalize(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        return collapse(decoded) ?? ""
    }

    /// デコード済みパスの正規化(折り畳みのみ)。コンテナ内パスは既に
    /// デコード済みが正規形なので、二重デコード(名前に % を含むファイルの
    /// 破壊)を避けるためこちらを使う
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
