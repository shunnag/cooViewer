import CoreGraphics
import Foundation
import Washi

/// WebKit を起動せずキャッシュ更新を検証するためのアトラス差替口。
@MainActor
protocol EPUBScreenAtlasing: AnyObject, Sendable {
    var publication: EPUBPublication { get }
    func screenPlan(
        metrics: EPUBScreenMetrics
    ) async -> (counts: [Int], pagesPerScreen: Int)?
    func thumbnail(spineIndex: Int, pageInItem: Int,
                   metrics: EPUBScreenMetrics, isDark: Bool,
                   width: CGFloat) async -> CGImage?
    func invalidate()
}

extension EPUBScreenAtlas: EPUBScreenAtlasing {}

/// リーダー外で EPUB の画面計画・サムネイルを引くためのアトラス共有
/// (コレクションの一覧展開用。設計書 §2.4 EPUB 対応)。
/// 本の解析(EPUBPublication)と census は重いので、正規化パスをキーに
/// 少数を LRU 保持して同じフォルダの開き直しを速くする
@MainActor
final class EPUBAtlasStore {
    static let shared = EPUBAtlasStore()

    private struct FileIdentity: Equatable, Sendable {
        let modificationDate: Date
        let size: UInt64
    }

    private struct CachedAtlas: Sendable {
        let atlas: any EPUBScreenAtlasing
        let fileIdentity: FileIdentity?
        var lastIdentityCheck: TimeInterval
    }

    private let makeAtlas: @MainActor (EPUBPublication) -> any EPUBScreenAtlasing
    private let identityRecheckInterval: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private var atlases: [String: CachedAtlas] = [:]
    private var order: [String] = []
    private var loading: [String: Task<CachedAtlas?, Never>] = [:]
    /// 使用中のアトラス参照カウント(await 中に LRU 追い出しで invalidate されて
    /// 空セル+オフスクリーン蘇りを招かないよう、使っている間は退避しない)
    private var inUse: [String: Int] = [:]
    private let limit = 8

    /// cooViewer-oxr.66: 同名ファイル差替えと再検査間隔を WebKit 抜きで
    /// 検証できるよう、アトラス生成器と単調時計を差し替え可能にする。
    init(
        makeAtlas: @escaping @MainActor (EPUBPublication) -> any EPUBScreenAtlasing = {
            EPUBScreenAtlas(publication: $0)
        },
        identityRecheckInterval: TimeInterval = 5,
        now: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.makeAtlas = makeAtlas
        self.identityRecheckInterval = max(0, identityRecheckInterval)
        self.now = now
    }

    /// 項目別ページ数と本固有の画面内ページ数を一括取得する。
    /// アトラス参照は MainActor のこのストア内に留める
    func screenPlan(
        for url: URL, metrics: EPUBScreenMetrics,
        preparsed: EPUBPublication? = nil
    ) async -> (counts: [Int], pagesPerScreen: Int)? {
        guard let (key, atlas) = await atlas(for: url, preparsed: preparsed)
        else { return nil }
        defer { release(key) }
        return await atlas.screenPlan(metrics: metrics)
    }

    /// 画面サムネイル(同上。EPUBScreenAtlas は NSWindow/WKWebView を抱える
    /// ため、非分離文脈に参照を渡して保持・解放させない)
    func thumbnail(for url: URL, spineIndex: Int, pageInItem: Int,
                   metrics: EPUBScreenMetrics, isDark: Bool,
                   width: CGFloat,
                   preparsed: EPUBPublication? = nil) async -> CGImage? {
        guard let (key, atlas) = await atlas(for: url, preparsed: preparsed)
        else { return nil }
        defer { release(key) }
        return await atlas.thumbnail(
            spineIndex: spineIndex, pageInItem: pageInItem,
            metrics: metrics, isDark: isDark, width: width)
    }

    /// リフロー EPUB のアトラス(解析失敗・FXL・DRM は nil)。同じ URL の並行
    /// 要求は解析に合流する。返す各経路で inUse を +1 する(呼び出し元での増分
    /// では atlas 取得〜使用開始の間に退避される窓が残るため、ここで増やす)。
    /// 呼び出し元は使い終えたら必ず release(key) すること
    private func atlas(
        for url: URL, preparsed: EPUBPublication?
    ) async -> (key: String, atlas: any EPUBScreenAtlasing)? {
        let key = CanonicalPath.normalize(url.path)
        var canUsePreparsed = true
        if var hit = atlases[key] {
            let checkTime = now()
            if checkTime - hit.lastIdentityCheck >= identityRecheckInterval {
                // cooViewer-oxr.66: NAS への stat はキーごとに最大 5 秒に 1 回。
                // 差替えを検知した古いアトラスは即座に止め、同じ要求で再構築する。
                hit.lastIdentityCheck = checkTime
                atlases[key] = hit
                if fileIdentity(for: url) != hit.fileIdentity {
                    invalidateCachedAtlas(for: key)
                    // 呼び出し元が古い代理 publication を握ったままでも、差替え後の
                    // identity と旧内容を結び付けないよう、この再構築だけは再解析する。
                    canUsePreparsed = false
                }
            }
            if let current = atlases[key] {
                touch(key)
                inUse[key, default: 0] += 1
                return (key, current.atlas)
            }
        }
        if let running = loading[key] {
            // タスクの戻り値を直接使う(atlases[key] を再読すると、生成側が
            // 公開する前にこちらの継続が先に走ったとき偽 nil になる)
            guard let loaded = await running.value else { return nil }
            atlases[key] = loaded
            touch(key)
            inUse[key, default: 0] += 1
            return (key, loaded.atlas)
        }
        // cooViewer-oxr.42 / 設計書 §2.4: 代理ソースが保持する解析済み
        // publication は同じ正規化パスに限って使い、EPUB の再解析を避ける。
        let supplied = canUsePreparsed ? preparsed.flatMap {
            CanonicalPath.normalize($0.url.path) == key ? $0 : nil
        } : nil
        let task = Task { () -> CachedAtlas? in
            let publication: EPUBPublication?
            if let supplied {
                publication = supplied
            } else {
                publication = await Task.detached(priority: .userInitiated) {
                    try? EPUBPublication(
                        url: url,
                        readStrategy: VolumeMappingPolicy.epubReadStrategy(for: url))
                }.value
            }
            guard let publication, !publication.isFixedLayout,
                  !publication.isDRMProtected else { return nil }
            return CachedAtlas(
                atlas: makeAtlas(publication),
                fileIdentity: fileIdentity(for: url),
                lastIdentityCheck: now())
        }
        loading[key] = task
        let loaded = await task.value
        loading[key] = nil
        guard let loaded else { return nil }
        atlases[key] = loaded
        touch(key)
        // 生成直後の自分を退避しないよう、増分を evict の前に置く
        inUse[key, default: 0] += 1
        evictIfNeeded()
        return (key, loaded.atlas)
    }

    private func fileIdentity(for url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        return FileIdentity(modificationDate: modificationDate, size: size)
    }

    private func invalidateCachedAtlas(for key: String) {
        atlases.removeValue(forKey: key)?.atlas.invalidate()
        order.removeAll { $0 == key }
    }

    private func release(_ key: String) {
        if let n = inUse[key] { inUse[key] = n > 1 ? n - 1 : nil }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        var i = 0
        while order.count > limit && i < order.count {
            let key = order[i]
            // 使用中のアトラスは退避しない(一時的な上限超過は許容)。await 中の
            // screenPlan/thumbnail が nil を掴む・オフスクリーンが蘇るのを防ぐ
            if (inUse[key] ?? 0) > 0 { i += 1; continue }
            order.remove(at: i)
            // 進行中の実測・レンダーを止め、オフスクリーンの不可視ウインドウと
            // WebContent プロセスを確実に畳んでから手放す(Washi の契約)
            atlases.removeValue(forKey: key)?.atlas.invalidate()
        }
    }
}
