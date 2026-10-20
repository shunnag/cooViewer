import Darwin

/// GPU 内部が資源不足を Swift Error にせず落ちる OS に対する初期化前の安全弁。
/// 恒常的な余裕は KaitoKit の bounded ハンドル予算で保ち、ここは一時不足を検出する。
enum FileDescriptorHeadroom {
    static func isAvailable(minimum: Int = 16) -> Bool {
        guard minimum > 0 else { return true }
        let first = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard first >= 0 else { return false }
        var probes = [first]
        defer { for descriptor in probes { Darwin.close(descriptor) } }
        for _ in 1..<minimum {
            let descriptor = Darwin.fcntl(first, F_DUPFD_CLOEXEC, 0)
            guard descriptor >= 0 else { return false }
            probes.append(descriptor)
        }
        return true
    }
}
