import Foundation

/// ディレクトリ直下の 1 項目(名前と「ディレクトリか」)。
struct DirectoryItem: Sendable, Hashable {
    let name: String
    let isDirectory: Bool
}

/// 本ファイルの同一性(サムネイルキャッシュキーと EPUB ステージングの合流キーの
/// 材料)。stat できなければ 0
struct BookFileIdentity: Sendable, Hashable {
    var modified: TimeInterval = 0
    var size: Int = 0
}

/// ディレクトリ列挙・存在判定・ファイル属性取得の注入点。SMB/NAS では stat 1 回が数 ms、
/// 応答しないマウントでは SMB タイムアウトまで止まるため、呼び出し側は
/// これをメインアクター外で使い、既定実装は塞がる本体を専用キューへ逃がして
/// 協調スレッドは await だけで済ませる。テストは遅延する偽物へ差し替える
/// (設計書 §7.3。PowerStateProviding と同じ差し替え方式。同期の偽物も
/// そのまま async 要件を満たす)。
protocol FileSystemProbing: Sendable {
    /// 直下の項目。隠しファイルの除外は呼び出し側が名前で行う
    /// (`.skipsHiddenFiles` は hidden フラグ付きの項目も落とし、旧来の
    /// ドット始まり判定と結果がずれる)。列挙できなければ throw
    func directoryItems(at directory: URL) async throws -> [DirectoryItem]
    func fileExists(atPath path: String) async -> Bool
    /// 開く対象の存在と種別を 1 回の stat で返す(旧来の fileExists(isDirectory:) と同じ。
    /// リンクは辿る)
    func itemKind(at url: URL) async -> (exists: Bool, isDirectory: Bool)
    func identity(at url: URL) async -> BookFileIdentity
}

/// 塞がる呼び出しを Swift 並行性の協調プールの外で走らせる固定幅のキュー(設計書 §7.3)。
/// 死んだ SMB マウントでは FileManager 呼び出し 1 回がタイムアウト(30-60 秒)まで
/// 戻らず、detached task で直接呼ぶと協調スレッドを 1 本ずつ奪って書庫 actor や
/// デコードまで止めてしまう。OperationQueue は幅を超えた要求をスレッドを持たずに
/// 待たせるため(セマフォ待ちのように待機者がスレッドを塞がない)、ぶら下がる
/// 呼び出しが占めるスレッドは最大でも幅ぶんに収まる。
struct BlockingProbeQueue: Sendable {
    let label: String
    private let queue: OperationQueue
    /// underlyingQueue は unowned(unsafe) なので、ここで保持する
    private let dispatchQueue: DispatchQueue

    /// 操作が残っていない(VolumeProbeQueues が消えたボリュームのキューを捨てる目安。
    /// 同期には使わない: 直後に加わる操作は呼び出し側のコピーがキューを生かす)
    var isIdle: Bool { queue.operationCount == 0 }

    init(label: String, width: Int) {
        self.label = label
        dispatchQueue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        queue = OperationQueue()
        queue.name = label
        queue.maxConcurrentOperationCount = width
        // 待っているのは本を開く・めくる操作なので、awaiting 側の優先度は引き継がれず
        // ここで明示する
        queue.qualityOfService = .userInitiated
        queue.underlyingQueue = dispatchQueue
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation { continuation.resume(with: Result(catching: work)) }
        }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: work()) }
        }
    }
}

/// FileManager 直結の既定実装。ディレクトリ判定は一括列挙で先読みした
/// リソース値を使い、項目ごとの stat を避ける。塞がる本体は全インスタンスで
/// 共通の、パスのボリュームごとに分かれたキューを通す(幅の上限はボリューム単位で
/// プロセス全体に意味を持つ)。
struct FileManagerProbe: FileSystemProbing {
    /// 同時に走る呼び出しは兄弟走査・開く本の stat・最近の一覧の実在確認(逐次)・
    /// 復元ゲートの数件で、健全な媒体では各 ms 単位の I/O 待ちに過ぎない。幅 4 は
    /// その典型的な同時要求を待たせず、死んだマウントにぶら下がったときに
    /// 無駄になるスレッドもそのボリュームで 4 本までに抑える。
    static let queues = VolumeProbeQueues(label: "jp.coo.cooViewer.FileSystemProbe", width: 4)

    /// パスのボリュームのキュー。塞がる FileManager 呼び出しは(本体がどこにあっても)
    /// 触るパスのこれで走らせる。再帰走査のように内側で別の塞がる呼び出しを直接する
    /// 本体は、丸ごと 1 回の `run` に載せる(キューの上から同じキューを待つと幅が
    /// 埋まったときに詰まる)
    static func queue(for url: URL) -> BlockingProbeQueue {
        queues.queue(for: url)
    }

    static func queue(forPath path: String) -> BlockingProbeQueue {
        queues.queue(forPath: path)
    }

    /// インスタンスの呼び出しが通すキュー群。テストは実マウントに依存しない
    /// (ルートだけの)キュー群を注入する
    private let queues: VolumeProbeQueues

    init(queues: VolumeProbeQueues = Self.queues) {
        self.queues = queues
    }

    func directoryItems(at directory: URL) async throws -> [DirectoryItem] {
        try await queues.queue(for: directory).run { try Self.blockingDirectoryItems(at: directory) }
    }

    func fileExists(atPath path: String) async -> Bool {
        await queues.queue(forPath: path).run { FileManager.default.fileExists(atPath: path) }
    }

    func itemKind(at url: URL) async -> (exists: Bool, isDirectory: Bool) {
        await queues.queue(for: url).run {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return (exists, isDirectory.boolValue)
        }
    }

    func identity(at url: URL) async -> BookFileIdentity {
        await queues.queue(for: url).run { Self.blockingIdentity(at: url) }
    }

    /// 塞がる本体。専用キューの上で呼ぶ(テストの同期ヘルパだけが直接使う)
    static func blockingDirectoryItems(at directory: URL) throws -> [DirectoryItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // リソース値はシンボリックリンクを辿らないが、旧来の
            // fileExists(isDirectory:) は辿っていた。リンクだけ従来どおり stat する
            if values?.isSymbolicLink == true {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return DirectoryItem(name: url.lastPathComponent,
                                     isDirectory: isDirectory.boolValue)
            }
            return DirectoryItem(name: url.lastPathComponent,
                                 isDirectory: values?.isDirectory == true)
        }
    }

    static func blockingIdentity(at url: URL) -> BookFileIdentity {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return BookFileIdentity(
            modified: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            size: attributes?[.size] as? Int ?? 0)
    }
}
