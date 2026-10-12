import Foundation
import Washi

/// 安全にメモリマップできないボリューム(NAS・外付け・ディスクイメージ)上の
/// EPUB を、アプリ所有のローカル一時ファイルへ一度だけコピーし、そのコピーを
/// マップして開く(設計書 §5 書庫スプール「EPUB のステージング」)。
/// Washi の `.alwaysCopy` は本全体を dirty な Data として publication の寿命の間
/// 抱えるため、合本の子・次巻の先読み・リーダー本体が同じ本を持つと RAM が
/// 冊数ぶん積み上がる(実測: 75 MB × 4 冊の合本でピーク 1,065-1,081 MB 対
/// ステージング後 約 500 MB、ローカルのマップ 625 MB)。ローカルコピーのマップは
/// ページキャッシュ上のクリーンなページで、OS が自由に追い出せる。切断・取り出しで
/// 消えるのは元ファイルだけなので SIGBUS の懸念も元のまま残らない。
///
/// publication の URL(表示・保存キー)は元ファイルのままにし、本の状態・最近の
/// 本・census・パスワードなどパスをキーにする全経路を変えない。
/// ファイルからの全オープン入口(EPUBSource・合本の子・代理ページ・次巻先読み・
/// リーダーの解析合流・ネスト EPUB の temp・サムネイルアトラス)がここを通るため、
/// 同じ実体は一度しかコピーされない(書庫内 EPUB の `EPUBPublication(data:)` は対象外)。
actor EPUBStagingArea {
    static let shared = EPUBStagingArea(environment: .live)

    /// 塞がる呼び出しとボリューム依存の判定の注入点(設計書 §7.3)。
    struct Environment: Sendable {
        /// ステージングファイルの置き場所。初回コピー時に 0700 で作る
        var directory: URL
        /// 元ファイルの存在・種別・同一性の確認(stat は専用キューへ)
        var probe: any FileSystemProbing
        /// マップ安全性(stat を伴うので呼び出し側がプローブキューで走らせる)
        var isSafeForMemoryMapping: @Sendable (URL) -> Bool
        /// ステージング先ボリュームの重要用途向け空き容量。nil は不明
        var availableCapacity: @Sendable (URL) -> Int64?
        /// 元 → ステージング先のストリーミングコピー(全体をメモリへ読まない)
        var copy: @Sendable (URL, URL) throws -> Void
        /// コピーのキューを元ファイルのボリュームで分けるためのマウントテーブル
        /// (テストは実マウントに依存しない偽物を注入する)
        var mountTable: MountTableCache = .live

        /// ディレクトリ名は書庫スプールと同じ <pid>-<uuid> 規則。起動時掃除が
        /// 生存しない pid の残骸として回収する(設計書 §5 後始末)
        static let live = Environment(
            directory: ArchiveSource.spoolRoot().appendingPathComponent(
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)-epub"),
            probe: FileManagerProbe(),
            isSafeForMemoryMapping: VolumeMappingPolicy.isSafeForMemoryMapping(url:),
            availableCapacity: { directory in
                (try? directory.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
            },
            copy: { try FileManager.default.copyItem(at: $0, to: $1) })
    }

    /// 元ファイルの実体(リンク解決済みの正規パス+サイズ+更新日時)。パスが
    /// 同じでも差し替えられた本は別の実体として扱う
    private struct Key: Hashable {
        let path: String
        let identity: BookFileIdentity
    }

    /// 生存中のコピーだけを見つける弱参照。寿命はコピーを掴む Data が決める
    private struct WeakCopy {
        weak var copy: StagedCopy?
    }

    /// コピー後もステージング先に残す空き(他のキャッシュと OS の作業領域)
    static let capacityHeadroom: Int64 = 256 << 20

    /// コピーは秒単位で塞がるため、ms 単位の stat を通す FileManagerProbe のキュー
    /// (幅 4)とは別のキューで走らせる。元ファイルのボリュームごとに分け、応答しない
    /// NAS のコピー 2 本が別ボリュームのステージングを止めないようにする
    /// (設計書 §7.3)。同じ NAS からの同時コピーは 2 本で十分
    nonisolated private let copyQueues: VolumeProbeQueues

    nonisolated private let environment: Environment
    private var copies: [Key: WeakCopy] = [:]
    private var inFlight: [Key: Task<StagedCopy?, Never>] = [:]

    init(environment: Environment) {
        self.environment = environment
        copyQueues = VolumeProbeQueues(label: "jp.coo.cooViewer.EPUBStaging", width: 2,
                                       mountTable: environment.mountTable)
    }

    /// 終了時にこのプロセスのステージングディレクトリを丸ごと消す(同期)。
    /// 終了時点ではリーダー・合本・先読みがまだ publication を掴んでいて
    /// StagedCopy の deinit は走らないため、放置すると本 1 冊ぶんのコピーが
    /// 次回起動の掃除まで(数百 MB)ディスクを占める。マップ中のファイルの
    /// unlink は Darwin では安全で、マッピングは munmap かプロセス終了まで有効。
    /// ローカル tmp の unlink は速いので終了シーケンスで同期に行える
    nonisolated func removeDirectoryAtTermination() {
        try? FileManager.default.removeItem(at: environment.directory)
    }

    /// 空き容量判定(純粋関数)。不明なら安全側でコピーしない
    static func hasRoom(forFileOfSize size: Int, availableCapacity: Int64?) -> Bool {
        guard let availableCapacity else { return false }
        return availableCapacity - Int64(size) >= capacityHeadroom
    }

    /// ファイルから EPUB を開く入口。安全なローカルボリュームは従来どおり直接
    /// マップし、それ以外はステージングしたコピーをマップする。ステージング
    /// できないとき(空き不足・コピー失敗・コピー中の差し替え・展開済み
    /// ディレクトリ)とコピーの解析に失敗したときは従来の `.alwaysCopy` に戻る
    /// (部分コピーを開くことはない)
    nonisolated func openPublication(at url: URL) async throws -> EPUBPublication {
        let environment = self.environment
        // シンボリックリンクは先に実体へ解決する。リンク自体をコピーすると
        // ステージング先が切断される媒体を参照し続け、chmod は元ファイルに届く。
        // ローカルのリンクが NAS の実体を指す場合も実体の方で安全性を判定する。
        // 2 段に分ける: 解決は入力パスのボリュームのキューで、安全性判定(実体の
        // statfs)は解決後の実体のボリュームのキューで。1 段で済ませると、死んだ NAS
        // を指すローカルのリンクが SMB タイムアウトの間ルートのキューの枠を塞ぐ
        let path = await FileManagerProbe.queue(for: url).run {
            CanonicalPath.normalize(url.path)
        }
        // isDirectory を明示して URL 生成の stat を避ける(ここは協調スレッド上)
        let source = URL(fileURLWithPath: path, isDirectory: false)
        let isSafe = await FileManagerProbe.queue(for: source).run {
            environment.isSafeForMemoryMapping(source)
        }
        if isSafe {
            return try EPUBPublication(url: url, readStrategy: .mappedIfSafe)
        }
        if let copy = await stagedCopy(forResolvedPath: path), let data = copy.mappedData() {
            do {
                return try EPUBPublication(data: data, displayURL: url)
            } catch {
                // 本当に壊れた EPUB は元を alwaysCopy で読み直すので 2 回読むことに
                // なるが、稀な失敗経路なので受け入れる
            }
        }
        return try await copyQueues.queue(forPath: path).run {
            try EPUBPublication(url: url, readStrategy: .alwaysCopy)
        }
    }

    /// 同じ実体の生存中コピー、または進行中のコピーに合流する。nil は
    /// ステージング不可(呼び出し側が `.alwaysCopy` へ)。path はリンク解決済み
    /// の正規パス(actor 内では塞がる I/O をしない)
    func stagedCopy(forResolvedPath path: String) async -> StagedCopy? {
        // isDirectory を明示して actor 内で stat しない(ディレクトリは直後の itemKind が弾く)
        let source = URL(fileURLWithPath: path, isDirectory: false)
        // 展開済み EPUB ディレクトリは Washi がフォルダとして読むのでコピーしない
        let kind = await environment.probe.itemKind(at: source)
        guard kind.exists, !kind.isDirectory else { return nil }
        let identity = await environment.probe.identity(at: source)
        guard identity.size > 0 else { return nil }
        let key = Key(path: path, identity: identity)
        if let live = copies[key]?.copy { return live }
        if let running = inFlight[key] { return await running.value }
        let environment = self.environment
        let copyQueue = copyQueues.queue(for: source)
        let task = Task.detached(priority: .userInitiated) {
            await Self.stage(source, identity: identity, environment: environment,
                             copyQueue: copyQueue)
        }
        inFlight[key] = task
        let copy = await task.value
        // 完了したタスクを残すと戻り値のコピーを掴み続けて寿命が切れない。
        // 自分のタスクのときだけ外す(合流窓の取り違え防止)
        if inFlight[key] == task { inFlight[key] = nil }
        copies = copies.filter { $0.value.copy != nil }
        if let copy { copies[key] = WeakCopy(copy: copy) }
        return copy
    }

    /// コピー本体。コピー前後で元ファイルの同一性が変わっていたら途中で
    /// 差し替えられた恐れがあるので捨てる(捨てたコピーは deinit が消す)
    private static func stage(_ source: URL, identity: BookFileIdentity,
                              environment: Environment,
                              copyQueue: BlockingProbeQueue) async -> StagedCopy? {
        guard let copy = try? await copyQueue.run({
            try blockingStage(source, identity: identity, environment: environment)
        }) else { return nil }
        guard await environment.probe.identity(at: source) == identity,
              copy.size == identity.size else { return nil }
        return copy
    }

    private static func blockingStage(_ source: URL, identity: BookFileIdentity,
                                      environment: Environment) throws -> StagedCopy? {
        let directory = environment.directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard hasRoom(forFileOfSize: identity.size,
                      availableCapacity: environment.availableCapacity(directory)) else {
            return nil
        }
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("epub")
        do {
            try environment.copy(source, destination)
            // 実体の通常ファイルだけを採用する。リンクが出来ていたら権限変更も
            // マップも元ファイルに届いてしまうので、触らずに捨てる
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            // 置き場所は 0700 なので権限変更の失敗で良いコピーを捨てない(nested temp と同じ)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: destination.path)
            return StagedCopy(url: destination, size: values.fileSize ?? 0)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// ステージングファイル 1 つの寿命。マップした Data の deallocator がこれを掴むので、
/// その本を開いた publication(= Data の保持者)が全て解放された時点で
/// deinit がファイルを消す。参照カウントの手管理も Washi 側の協力も要らない
final class StagedCopy: Sendable {
    let url: URL
    let size: Int

    init(url: URL, size: Int) {
        self.url = url
        self.size = size
    }

    deinit {
        // 最後の Data はメインアクター上で手放されることが多いので、unlink は
        // ArchiveSource.deinit と同じく detached の utility タスクへ逃がす
        let url = self.url
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 読み取り専用のプライベートマップ。利用者ごとに同じファイルをマップし直す
    /// (ページキャッシュは共有されるので実メモリは増えない)。失敗は nil
    func mappedData() -> Data? {
        // 長さ 0 の Data(bytesNoCopy:) は deallocator を即時に呼ぶ
        guard size > 0 else { return nil }
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let base = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
              base != MAP_FAILED else { return nil }
        let owner = self
        return Data(bytesNoCopy: base, count: size, deallocator: .custom { pointer, count in
            munmap(pointer, count)
            withExtendedLifetime(owner) {}
        })
    }
}
