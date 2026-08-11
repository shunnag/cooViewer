import Darwin
import Foundation
import IOKit
import os

/// 本の置き場所の速度を判定するプローブ(設計書「キャッシュ・先読み設計」)。
/// 手順: statfs でネットワーク判定 → IOKit で物理特性(SSD/回転)→
/// 判別不能なら実測ベンチ(逐次読み。時間バジェット付き)。
/// 本を開くフローと並行に走らせられるよう、全体を async にしてある。
enum MediaSpeedProbe {
    private static let logger = Logger(subsystem: "jp.coo.cooViewer",
                                       category: "MediaSpeedProbe")

    /// ベンチの読み取り上限と時間バジェット
    private static let benchmarkMaxBytes = 16 << 20
    private static let benchmarkBudget: TimeInterval = 0.25
    private static let benchmarkChunkBytes = 1 << 20

    /// ボリューム(マウントポイント)単位の判定結果キャッシュ。
    /// ベンチを同じボリュームで何度も走らせない(セッション内有効)
    private static let cache = OSAllocatedUnfairLock(initialState: [String: MediaProfile]())

    /// url(本のファイル/フォルダ)が載るボリュームのプロファイルを返す。
    /// ブロッキング I/O を含むためワーカースレッドで実行する
    static func profile(for url: URL) async -> MediaProfile {
        let path = url.path
        return await Task.detached(priority: .userInitiated) {
            profileSync(path: path)
        }.value
    }

    private static func profileSync(path: String) -> MediaProfile {
        var fsInfo = statfs()
        guard statfs(path, &fsInfo) == 0 else {
            logger.info("statfs failed for \(path, privacy: .public); using unknown profile")
            return .unknown
        }
        let mountPoint = withUnsafeBytes(of: fsInfo.f_mntonname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        // キーはマウントポイントだけでなくデバイス名と fsid も含める:
        // 同じ /Volumes/名前 に別の物理デバイスがマウントし直されても
        // 古い判定を使い回さないように(レビュー指摘)
        let cacheKey = "\(mountPoint)|\(mountedFromName(fsInfo))|" +
            "\(fsInfo.f_fsid.val.0):\(fsInfo.f_fsid.val.1)"
        if let cached = cache.withLock({ $0[cacheKey] }) {
            return cached
        }
        let profile = classifyVolume(path: path, fsInfo: fsInfo)
        cache.withLock { $0[cacheKey] = profile }
        return profile
    }

    private static func classifyVolume(path: String, fsInfo: statfs) -> MediaProfile {
        let isLocal = (fsInfo.f_flags & UInt32(MNT_LOCAL)) != 0
        if !isLocal {
            let profile = MediaProfile.classify(
                isLocalVolume: false, mediumType: .unknown, measuredMBPerSec: nil)
            logger.info("media profile: network (\(fsTypeName(fsInfo), privacy: .public))")
            return profile
        }

        let medium = mediumType(mountedFrom: mountedFromName(fsInfo))
        if medium == .unknown {
            // USB エンクロージャ等は Medium Type が取れないことが多い → 実測
            let measured = benchmark(path: path)
            let profile = MediaProfile.classify(
                isLocalVolume: true, mediumType: .unknown, measuredMBPerSec: measured)
            logger.info("""
                media profile: \(profile.mediaClass.rawValue, privacy: .public) \
                (measured \(measured.map { String(format: "%.0f", $0) } ?? "n/a", privacy: .public) MB/s)
                """)
            return profile
        }
        let profile = MediaProfile.classify(
            isLocalVolume: true, mediumType: medium, measuredMBPerSec: nil)
        logger.info("media profile: \(profile.mediaClass.rawValue, privacy: .public) (IOKit medium type)")
        return profile
    }

    private static func fsTypeName(_ fsInfo: statfs) -> String {
        withUnsafeBytes(of: fsInfo.f_fstypename) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func mountedFromName(_ fsInfo: statfs) -> String {
        withUnsafeBytes(of: fsInfo.f_mntfromname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // MARK: - IOKit(物理特性)

    /// マウント元("/dev/disk3s1" 等)から IOKit の Medium Type を引く。
    /// パーティションから親へ遡り、Device Characteristics を探す
    private static func mediumType(mountedFrom: String) -> MediaProfile.MediumType {
        guard mountedFrom.hasPrefix("/dev/") else { return .unknown }
        let bsdName = String(mountedFrom.dropFirst("/dev/".count))
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            return .unknown
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return .unknown }
        defer { IOObjectRelease(service) }

        guard let characteristics = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane,
            "Device Characteristics" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? [String: Any],
            let medium = characteristics["Medium Type"] as? String else {
            return .unknown
        }
        switch medium {
        case "Solid State": return .solidState
        case "Rotational": return .rotational
        default: return .unknown
        }
    }

    // MARK: - 実測ベンチ

    /// path(フォルダなら中の最初の大きめファイル)を逐次読みして MB/s を測る。
    /// 上限 16MB / 250ms。サンプルが小さすぎる(< 2MB かつ一瞬)場合は
    /// 判定材料にしない(nil)
    private static func benchmark(path: String) -> Double? {
        guard let target = benchmarkTarget(path: path) else { return nil }
        guard let file = FileHandle(forReadingAtPath: target) else { return nil }
        defer { try? file.close() }
        // OS のファイルキャッシュに載っていると実測にならないため無効化する
        _ = fcntl(file.fileDescriptor, F_NOCACHE, 1)

        let start = DispatchTime.now()
        var totalBytes = 0
        while totalBytes < benchmarkMaxBytes {
            let elapsed = seconds(since: start)
            if elapsed > benchmarkBudget, totalBytes > 0 { break }
            guard let chunk = try? file.read(upToCount: benchmarkChunkBytes),
                  !chunk.isEmpty else { break }
            totalBytes += chunk.count
        }
        let elapsed = seconds(since: start)
        guard elapsed > 0.005, totalBytes >= 2 << 20 else { return nil }
        return Double(totalBytes) / Double(1 << 20) / elapsed
    }

    private static func seconds(since start: DispatchTime) -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    /// ベンチ対象: ファイルならそのまま、フォルダなら直下で最大のファイル
    /// (浅い走査のみ。見つからなければ nil)
    private static func benchmarkTarget(path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        guard isDirectory.boolValue else { return path }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return nil
        }
        var best: (path: String, size: Int)?
        for name in names.prefix(64) where !name.hasPrefix(".") {
            let candidate = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: candidate))?[.size]
                as? Int ?? 0
            if size > (best?.size ?? 0) {
                best = (candidate, size)
            }
        }
        return best?.path
    }
}
