import Foundation

/// 親フォルダの改名を切断と誤認せず、消えた外付けだけは別のディスクまで遡らない(設計書 §2.3、§7.4)。
enum OpenFailureStorage {
    struct Result: Sendable {
        let isReachable: Bool
        let canonicalPath: String
        let timedOut: Bool
    }

    static func isReachable(at bookURL: URL, policy: AssemblyRetryPolicy,
                            mountPointExists: @escaping @Sendable (URL) async -> Bool) async throws -> Bool {
        try await probe(at: bookURL, policy: policy, mountPointExists: mountPointExists).isReachable
    }

    static func probe(at bookURL: URL, policy: AssemblyRetryPolicy,
                      mountPointExists: @escaping @Sendable (URL) async -> Bool) async throws -> Result {
        let probe = policy.reachabilityProbe
        let resolution = ResolvedPath()
        var bounded = policy
        bounded.reachabilityProbe = { url in
            let original = url.standardizedFileURL.path
            let resolved = await FileManagerProbe.queue(for: url).run { resolvedPath(for: original) }
            await resolution.set(resolved)
            for path in Set([original, resolved]) {
                if let mount = mountPoint(for: path), !(await mountPointExists(mount)) {
                    return false
                }
            }
            var ancestor = URL(fileURLWithPath: resolved, isDirectory: false)
            while true {
                if Task.isCancelled { return false }
                if await probe(ancestor) {
                    return true
                }
                if ancestor.path == "/" {
                    return false
                }
                ancestor.deleteLastPathComponent()
            }
        }
        // 祖先探索とマウント確認を合わせて二秒に制限し、応答しない保存先を待ち続けない(設計書 §7.4)。
        let reachability = try await AssemblyRetry.sourceReachability(bookURL, policy: bounded)
        // 期限後に同じ保存先を再照会せず、その時点で分かったパスだけを表示側へ渡す(設計書 §7.4)。
        // 応答期限切れでは復帰通知だけで回復を検知できないため、自動再読込の約束を表示しない(設計書 §7.4)。
        return Result(isReachable: reachability.isReachable,
            canonicalPath: await resolution.value ?? bookURL.standardizedFileURL.path,
            timedOut: reachability.timedOut)
    }

    static func resolvedPath(for path: String) -> String {
        let normalized = CanonicalPath.normalize(path)
        if FileManager.default.fileExists(atPath: normalized) { return normalized }
        // Foundation はリンク先が不在だと元パスを返すため、保存先の切断中もリンク先を辿っておく(設計書 §7.4)。
        var pending = components(of: normalized)
        var resolved: [String] = []
        // 循環するリンクでも有限回で止め、存在しない保存先の照会を増やし続けない(設計書 §7.4)。
        var followed = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            if followed < 40, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                followed += 1
                let target = destination.hasPrefix("/") ? destination
                    : "/" + (resolved + [destination]).joined(separator: "/")
                // URL 標準化が /private/tmp を /tmp に戻すため、中間経路ではリンクを含まない字句処理だけを行う(設計書 §7.4)。
                pending = components(of: target) + pending
                resolved.removeAll()
            } else {
                resolved.append(component)
            }
        }
        return CanonicalPath.normalize("/" + resolved.joined(separator: "/"))
    }

    private static func components(of path: String) -> [String] {
        var result: [String] = []
        for component in (path as NSString).pathComponents {
            switch component {
            case "/", ".": break
            case "..": if !result.isEmpty { result.removeLast() }
            default: result.append(component)
            }
        }
        return result
    }

    private static func mountPoint(for path: String) -> URL? {
        let parts = (path as NSString).pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(parts[2])", isDirectory: true)
    }

    private actor ResolvedPath {
        private(set) var value: String?
        func set(_ value: String) { self.value = value }
    }
}
