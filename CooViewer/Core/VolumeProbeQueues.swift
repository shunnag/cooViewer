import Foundation
import os

/// マウントテーブルの写し。パスを持つボリューム(マウントポイント)を**字句だけで**選ぶ
/// (設計書 §7.3)。選ぶ側が対象パスを stat / statfs / `resourceValues(.volumeURLKey)`
/// すると、死んだ SMB マウントの隔離が目的なのにその選択自体が SMB タイムアウトまで
/// 止まる。マウントポイント一覧との最長一致なら対象には触れない。
/// 字句正規化は `standardizedFileURL` / `stringByStandardizingPath` も使わない
/// ("/private" の除去で実在確認にファイルシステムを引く仕様)。
///
/// `/Users` は firmlink で物理的には `/System/Volumes/Data` 上にあるが、字句一致では
/// `/` に落ちる。ローカルの本の仕事を健全な 1 本のルートキューに集めるという望む結果
/// なので、意図どおり(Data 経由のパスは Data のキューになるだけで隔離は損なわれない)。
struct MountTable: Sendable, Equatable {
    private struct Entry: Equatable {
        let mountPoint: String
        let components: [String]
    }

    /// 正規化済みのマウントポイント。"/" を必ず含む
    let mountPoints: [String]
    private let entries: [Entry]

    init(mountPoints: [String]) {
        var seen = Set<String>()
        var entries: [Entry] = []
        for point in mountPoints + ["/"] {
            let components = Self.pathComponents(point)
            let normalized = "/" + components.joined(separator: "/")
            guard seen.insert(normalized).inserted else { continue }
            entries.append(Entry(mountPoint: normalized, components: components))
        }
        self.entries = entries
        self.mountPoints = entries.map(\.mountPoint)
    }

    /// パスを持つボリュームのマウントポイント。コンポーネント境界で最長一致し
    /// (`/Volumes/NAS2` は `/Volumes/NAS` に含まれない)、どこにも一致しなければ "/"
    func mountPoint(forPath path: String) -> String {
        let components = Self.pathComponents(path)
        var best = "/"
        var bestDepth = 0
        for entry in entries
        where entry.components.count > bestDepth && components.starts(with: entry.components) {
            best = entry.mountPoint
            bestDepth = entry.components.count
        }
        return best
    }

    /// 字句だけの正規化("//"・"."・".." を畳む。リンクは解決しない)
    static func pathComponents(_ path: String) -> [String] {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(String(component))
            }
        }
        return components
    }

    /// 現在のマウントテーブル。`MNT_NOWAIT` はカーネルが持つ写しを返すだけで各ファイル
    /// システムへ問い合わせないため、死んだマウントがあっても塞がらない(`MNT_WAIT` は
    /// 各 FS の statfs を更新しに行き、死んだ SMB で止まる)。`getmntinfo` は静的バッファで
    /// スレッド安全でないので `_r_np` 版を使い、返されたバッファは呼び出し側が free する
    static func readCurrent() -> MountTable {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return MountTable(mountPoints: []) }
        defer { free(buffer) }
        return MountTable(mountPoints: (0..<Int(count)).map { index in
            withUnsafeBytes(of: buffer[index].f_mntonname) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        })
    }
}

/// マウントテーブルの写しを一定時間だけ使い回す。取得は数十 µs の syscall なので
/// 要求のたびに読んでも困らないが、stat 1 回ごとに呼ばれる経路なので間引く。
/// NSWorkspace のマウント通知で無効化する案は AppKit を Core へ持ち込み、登録前の
/// 最初の呼び出しに穴ができ、テストでも差し替えにくい。間隔内に増えたマウントは
/// その間だけルートキューに乗る(隔離が一時的に粗くなるだけで誤動作はしない)。
/// プロセス全体で一つ(`live`)を probe と EPUB ステージングのキューが共有する
final class MountTableCache: Sendable {
    static let live = MountTableCache(read: MountTable.readCurrent, refreshInterval: .seconds(1))

    private let read: @Sendable () -> MountTable
    private let refreshInterval: Duration
    private let state: OSAllocatedUnfairLock<(table: MountTable, readAt: ContinuousClock.Instant)?>
        = OSAllocatedUnfairLock(initialState: nil)

    /// `refreshInterval` が 0 なら毎回読み直す(テストでテーブルを差し替える用)
    init(read: @escaping @Sendable () -> MountTable, refreshInterval: Duration) {
        self.read = read
        self.refreshInterval = refreshInterval
    }

    func current() -> MountTable {
        let now = ContinuousClock.now
        if let cached = state.withLock({ $0 }), now - cached.readAt < refreshInterval {
            return cached.table
        }
        // 読み直しはロックの外(read は差し替え可能で、ロック中に呼ぶ理由がない)
        let table = read()
        state.withLock { $0 = (table, now) }
        return table
    }
}

/// ボリュームごとの `BlockingProbeQueue`(設計書 §7.3)。プロセス全体で 1 本のキューだと、
/// 死んだ SMB マウントにぶら下がった幅ぶんの呼び出しが全スロットを占め、ローカルの本を
/// 開く stat・兄弟走査・最近の一覧の実在確認までその後ろで待つ。パスの属するボリューム
/// でキューを分ければ別ボリュームの呼び出しは互いに待たず、死んだマウントが無駄にする
/// スレッドもボリュームあたり幅ぶんに収まる。
///
/// 寿命と上限: キューはそのボリュームへの最初の要求で作り(Preboot/VM 等の常駐システム
/// マウントのために先に作らない)、マウントテーブルの写しが変わったときに、消えた
/// ボリュームのキューを暇なら(操作が残っていなければ)捨てる。進行中の `run` は自分の
/// 構造体コピーで OperationQueue を掴んでいるので、辞書から外しても結果は届く。
/// ルート以外のキューは `maximumVolumeQueues` 本まで。上限で新顔のボリュームが来たら
/// 暇なキューを 1 本捨てて譲り、全部が塞がっているときだけルートのキューを共有する
/// (隔離が粗くなるだけ。(16 + ルート 1) × 幅 4 = 最悪 68 スレッド)。
/// 一致しないパスと相対パスもルートのキュー。
final class VolumeProbeQueues: Sendable {
    private struct State {
        var table: MountTable
        var queues: [String: BlockingProbeQueue]
    }

    private let label: String
    private let width: Int
    private let maximumVolumeQueues: Int
    private let mountTable: MountTableCache
    private let state: OSAllocatedUnfairLock<State>

    init(label: String, width: Int, mountTable: MountTableCache = .live,
         maximumVolumeQueues: Int = 16) {
        self.label = label
        self.width = width
        self.maximumVolumeQueues = maximumVolumeQueues
        self.mountTable = mountTable
        let root = BlockingProbeQueue(label: label, width: width)
        state = OSAllocatedUnfairLock(initialState: State(
            table: MountTable(mountPoints: []), queues: ["/": root]))
    }

    func queue(for url: URL) -> BlockingProbeQueue {
        queue(forPath: url.path)
    }

    func queue(forPath path: String) -> BlockingProbeQueue {
        let table = mountTable.current()
        return state.withLock { state in
            if state.table != table {
                state.table = table
                let mounted = Set(table.mountPoints)
                state.queues = state.queues.filter { point, queue in
                    point == "/" || mounted.contains(point) || !queue.isIdle
                }
            }
            let point = table.mountPoint(forPath: path)
            if let queue = state.queues[point] { return queue }
            // 上限に達していたら、まだマウントされていても暇なキューを 1 本捨てて
            // 新顔に枠を譲る。全部が塞がっているときだけルートを共有する
            if state.queues.count > maximumVolumeQueues,
               let idle = state.queues.first(where: { $0.key != "/" && $0.value.isIdle }) {
                state.queues[idle.key] = nil
            }
            guard state.queues.count <= maximumVolumeQueues else { return state.queues["/"]! }
            let queue = BlockingProbeQueue(label: "\(label).\(point)", width: width)
            state.queues[point] = queue
            return queue
        }
    }

    /// 現在生きているキューのマウントポイント(テスト用)
    var mountPoints: Set<String> {
        state.withLock { Set($0.queues.keys) }
    }
}
