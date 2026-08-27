import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// サムネイルのメモリ+ディスクキャッシュ(設計書「キャッシュ・先読み設計」)。
/// ディスク側は Caches/jp.coo.cooViewer/Thumbnails-v2/<bookKey>/<entryID>.heic。
/// v2: PNG → HEIC(Apple Silicon のハードウェアエンコード)で 1 枚あたり
/// 約 1/5 のサイズになり、ディスク I/O と使用量を抑える。旧 Thumbnails/ は
/// 起動時に丸ごと削除して作り直す(キャッシュは使い捨て可能なため)。
/// bookKey は本のパス+更新日時+サイズ由来のため、本が更新されればキーごと変わる
/// (旧キーのフォルダは起動時の trimDiskCache で回収する)。
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    static let maxPixelSize = 200

    private var memory: [String: CGImage] = [:]
    private var order: [String] = []
    /// 200px サムネイル(1 枚 ≈ 160KB)換算で 64MB 相当
    private let memoryCountLimit = 400

    /// 生成に失敗したページ(壊れ画像・パスワード付きネスト書庫等)の記録。
    /// これがないと画面に入るたびに毎回展開し直してしまい、solid 書庫や
    /// ネットワークボリュームでは失敗ページ 1 つが延々と CPU/IO を食い続ける。
    /// メモリのみ(セッション内)。本が更新されれば bookKey ごと変わるので解ける。
    /// 恒久記録は **2 回完走失敗**から: 多数の PDF を並列で開いた直後などは
    /// PDFKit が一時的に失敗することがあり、1 回で打ち止めると縮小が
    /// 出ないまま恒久プレースホルダになる。壊れページは決定的に失敗するので
    /// 2 回で従来どおり止まる(CPU/IO 護持の趣旨は維持)。
    /// カウントは生成タスク側で行う = 1 生成 1 カウント(複数の待ち手が同じ
    /// 失敗生成を待っていても二重に数えない)。
    /// 恒久記録にも有効期限(failureTTL)を設ける: 稀な一時要因(メモリ逼迫等)で
    /// 2 回失敗したページがセッション中ずっと欠けたままにならないよう、期限が
    /// 切れたら勘定ごと赦して再挑戦させる。壊れページは再び 2 回失敗して
    /// 戻るだけで、期限内の失敗ループ護持は保たれる
    private struct FailureRecord {
        var count = 0
        /// 恒久記録(2 回完走失敗)へ昇格した時刻。failureTTL 経過で赦す
        var permanentAt: ContinuousClock.Instant?
    }
    private var failures: [String: FailureRecord] = [:]
    /// 恒久記録の追い出し順(failures のうち permanentAt 非 nil のもの)
    private var failedOrder: [String] = []
    private let failedCountLimit = 4096
    private let failureTTL: Duration

    /// 生成(ソース展開・PDF レンダリング)の同時実行ゲート。セルの .task は
    /// 可視セル数ぶん一斉に生成要求するため(自動グリッドで最大 60 超)、
    /// 絞らないと多数の PDF 文書の並列レンダリングが暴走して一時失敗や
    /// チラつきの churn を招く。ディスクキャッシュ命中は生成ではないので
    /// ゲートを通らない。表示中ページの読み込みは本ゲートと無関係(不飢餓)
    private let generationGate = SourceReadGate(limit: 4)

    private let diskRoot: URL

    init(diskRoot: URL? = nil, failureTTL: Duration = .seconds(300)) {
        self.diskRoot = diskRoot ?? FileManager.default
            .userDomainDirectory(.cachesDirectory)
            .appendingPathComponent("jp.coo.cooViewer/Thumbnails-v2")
        self.failureTTL = failureTTL
    }

    /// 生成中の共有タスクと待ち手数(重複要求は同じ生成を待つ)。
    ///
    /// 正しさの要は**生成タスクの完了時自己退去**(generationFinished、
    /// generationID 照合)。task.value は生成クロージャ(markFailed →
    /// generationFinished を含む)の完了後にしか再開しないため、
    /// 「エントリが inFlight に現存する ⇒ タスクは未完了」が不変条件になり、
    /// 完了済みタスク(特に失敗の nil)へ後続要求が合流し続ける残留は
    /// 構造的に起きない。旧実装はこの保証がなく、withTaskCancellationHandler が
    /// ハンドラを外した直後にキャンセルが着地すると解放が双方スキップされ、
    /// 完了済みタスクが waiters>0 のまま残留するレースがあった(「開き直しても
    /// 欠けたまま」として実地で顕在化。cooViewer-dq9/yhl)。
    ///
    /// waiters の減算は onCancel(非構造化 Task)による退場だけが実質担い、
    /// 完了後の waiterDeparted 呼び出しは上記不変条件により常に no-op
    /// (エントリは既に自己退去済み)。departed トークンは通知の交錯・重複に
    /// 対する多重防御で、waiters が負に振れないことを保証する。旧世代の
    /// 遅延通知は task 同一性 / generationID 照合で無害化される(キー再利用後の
    /// 新世代を壊さない)。generationFinished を「冗長」とみなして外すと
    /// 旧バグが再発するので注意。変更時はこの説明を更新すること
    private struct InFlight {
        let task: Task<CGImage?, Never>
        /// 完了時の自己退去の照合用(タスク自身はクロージャ内から参照できない)
        let generationID: UUID
        var waiters: Int
        /// 退場済み待ち手のトークン(重複退場の防止。エントリと共に消える)
        var departed: Set<UUID> = []
    }

    private var inFlight: [String: InFlight] = [:]

    /// メモリ → ディスク → 生成の順で取得する。
    /// urgent: 可視セル・ホバープレビューなど「いま画面に見えている」要求。
    /// 生成タスク自体を userInitiated で起動し、1 段目 generationGate の優先
    /// レーンと 2 段目 FolderSource.readGate(currentPriority 推論)の双方で
    /// 対話レーンに入る。先読み(±3 画面)の行列を追い越す — 自動グリッドでは
    /// 1 画面のセル数が大きく、FIFO だけだと可視セルが見えない画面の先読みの
    /// 後ろに並ばされ、収束まで欠けて見えるため。既存生成への合流はレーンを
    /// 変えない(作成時のみ有効)
    func thumbnail(for entry: PageEntry, in source: any BookSource,
                   bookKey: String, urgent: Bool = false) async -> CGImage? {
        let key = bookKey + "/" + String(entry.id)
        if let hit = memory[key] {
            touch(key)
            return hit
        }
        // 恒久記録済みのページは期限内なら再挑戦しない(プレースホルダのまま)。
        // 期限切れは勘定ごと赦して再挑戦させる
        if let record = failures[key], let at = record.permanentAt {
            guard ContinuousClock.now - at >= failureTTL else { return nil }
            failures.removeValue(forKey: key)
            if let index = failedOrder.firstIndex(of: key) {
                failedOrder.remove(at: index)
            }
        }

        let waiterID = UUID()
        let task: Task<CGImage?, Never>
        if let running = inFlight[key], !running.task.isCancelled {
            // 進行中の生成に合流(キャンセル済みには合流せず作り直す)
            task = running.task
            inFlight[key]?.waiters += 1
        } else {
            let fileURL = diskRoot.appendingPathComponent(bookKey)
                .appendingPathComponent("\(entry.id).heic")
            // detached: セル側(SwiftUI .task)のキャンセルにもこの actor の
            // 文脈にも縛られない独立タスクとして生成する。先読み(非 urgent)は
            // utility に落とし、ソースの読み取りゲートで表示中ページの読み込み
            // (userInitiated)に道を譲る(低速媒体でのページ表示停滞の防止)。
            // 可視セル(urgent)は生成タスク自体を userInitiated で起動する:
            // 内側 source.image() が通る 2 段目 = FolderSource.readGate は
            // currentPriority を推論するため、タスクが utility のままだと
            // urgent でも背面レーンに落ち Book 先読みの後ろで飢餓する。基底
            // 優先度は床でエスカレーションは下げないので、対話レーンへ確定する
            let gate = generationGate
            let generationID = UUID()
            let generation = Task.detached(
                priority: urgent ? .userInitiated : .utility) {
                let image = await Self.loadOrGenerate(
                    entry: entry, source: source, fileURL: fileURL, gate: gate,
                    urgent: urgent)
                // 失敗の記録は生成タスク自身が行う = 1 生成 1 カウント。
                // 待ち手側で数えると、同じ失敗生成を待つ待ち手の数だけ
                // 二重カウントされ、1 回の失敗で恒久記録へ昇格してしまう。
                // キャンセルされた生成は数えない(次の要求で作り直される)
                if image == nil, !Task.isCancelled {
                    await self.markFailed(key)
                }
                // 完了したタスクは合流先から必ず外す(InFlight のコメント参照)
                await self.generationFinished(key: key, generationID: generationID)
                return image
            }
            task = generation
            inFlight[key] = InFlight(task: generation, generationID: generationID,
                                     waiters: 1)
        }

        let image = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.waiterDeparted(key: key, task: task, id: waiterID,
                                          cancelGeneration: true)
            }
        }
        // キャンセルの有無に関わらず必ず一度呼ぶ(トークンで冪等)
        waiterDeparted(key: key, task: task, id: waiterID, cancelGeneration: false)
        if let image {
            store(image, for: key)
        }
        return image
    }

    /// 待ち手の退場(キャンセル通知 or 完了後)。トークンで一度だけ数え、
    /// 生成中(キャンセル通知経路)に全員去っていたら生成をキャンセルする
    /// (実行前ならソース側の checkCancellation で脱落し、実行中なら完走して
    /// キャッシュに残る)。完了後経路では生成は既に終わっているので
    /// キャンセルせず登録だけ整理する
    private func waiterDeparted(key: String, task: Task<CGImage?, Never>,
                                id: UUID, cancelGeneration: Bool) {
        guard var entry = inFlight[key], entry.task == task,
              !entry.departed.contains(id) else { return }
        entry.departed.insert(id)
        entry.waiters -= 1
        if entry.waiters <= 0 {
            if cancelGeneration { task.cancel() }
            inFlight[key] = nil
        } else {
            inFlight[key] = entry
        }
    }

    /// 生成完了時の自己退去。完了済みタスクが inFlight に残って、以後の要求が
    /// 古い結果(特に失敗の nil)へ合流し続けるのを構造的に防ぐ
    private func generationFinished(key: String, generationID: UUID) {
        guard inFlight[key]?.generationID == generationID else { return }
        inFlight[key] = nil
    }

    /// 旧形式(PNG)のキャッシュディレクトリを丸ごと削除する(起動時に一度)。
    /// キャッシュは使い捨て可能なので変換はせず作り直す
    nonisolated static func removeLegacyCacheDirectory() {
        let legacy = FileManager.default
            .userDomainDirectory(.cachesDirectory)
            .appendingPathComponent("jp.coo.cooViewer/Thumbnails")
        try? FileManager.default.removeItem(at: legacy)
    }

    /// 古い本のディスクキャッシュを回収する(起動時に呼ぶ)。
    func trimDiskCache(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: diskRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for child in children {
            let values = try? child.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    /// 検証用: 内部状態の要約(--dump-thumbnail-stats。欠けセルの原因判別)
    func debugStats() async -> String {
        let gate = await generationGate.debugCounts()
        let promoted = failures.filter { $0.value.permanentAt != nil }
        let counting = failures.filter { $0.value.permanentAt == nil }
        var lines = [
            "memory=\(memory.count) inFlight=\(inFlight.count)",
            "failures: counting=\(counting.count) promoted=\(promoted.count)",
            "gate: active=\(gate.active) queued=\(gate.queued)",
        ]
        for (key, record) in promoted.sorted(by: { $0.key < $1.key }).prefix(40) {
            lines.append("  promoted \(key) count=\(record.count)")
        }
        for (key, record) in counting.sorted(by: { $0.key < $1.key }).prefix(40) {
            lines.append("  counting \(key) count=\(record.count)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 内部

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
    }

    private func markFailed(_ key: String) {
        var record = failures[key] ?? FailureRecord()
        record.count += 1
        // 失敗記録そのものの肥大も防ぐ(精度より安全側: あふれたら未昇格の
        // 勘定がリセットされるだけで、恒久記録側は保たれる)
        if failures.count > failedCountLimit * 2 {
            failures = failures.filter { $0.value.permanentAt != nil }
        }
        if record.count >= 2, record.permanentAt == nil {
            record.permanentAt = ContinuousClock.now
            failedOrder.append(key)
            while failedOrder.count > failedCountLimit {
                failures.removeValue(forKey: failedOrder.removeFirst())
            }
        }
        failures[key] = record
    }

    private func store(_ image: CGImage, for key: String) {
        // 成功したページの失敗勘定は消す(一時失敗→成功→また一時失敗の
        // 積み上がりで恒久記録に達しないように。保護コンテンツはディスク
        // キャッシュを持たず再生成が起こり得るため)。恒久記録済みのまま
        // 成功が届く経路は通常ないが、あっても failedOrder の残骸は追い出しの
        // removeValue が no-op で吸収する
        failures.removeValue(forKey: key)
        if memory[key] == nil {
            order.append(key)
        } else {
            touch(key)
        }
        memory[key] = image
        while order.count > memoryCountLimit {
            memory.removeValue(forKey: order.removeFirst())
        }
    }

    /// ディスク読取 → ソース生成 → ディスク保存(actor 状態に触れない)。
    /// パスワード付き書庫はディスク層を素通りしメモリのみで扱う(下記)。
    private static func loadOrGenerate(entry: PageEntry, source: any BookSource,
                                       fileURL: URL, gate: SourceReadGate,
                                       urgent: Bool) async -> CGImage? {
        // 実行に入る前にキャンセル済みなら何もしない(遠いページの早期破棄)。
        // ソース呼び出しが始まった後は完走させてキャッシュに残す
        guard !Task.isCancelled else { return nil }
        // パスワード付き書庫の復号済みページを平文でディスクに残さない(CWE-312)。
        // 保護コンテンツを含むソースはディスク層(読み取りも書き込みも)を素通り
        // させ、生成物は呼び出し元のメモリキャッシュにだけ載せる。判定は
        // isEncrypted ではなく containsProtectedContent — コレクション内の
        // 暗号化 zip・非暗号化書庫内の暗号化ネスト・解錠後の PDF は最上位の
        // isEncrypted が false になるため(SuperRes キャッシュと同じ判定に揃える)。
        // キャンセル判定の後に一度だけ await するので、キャンセル意味論も
        // ホットパスの await 回数も変えない。
        let protected = await source.containsProtectedContent()
        if !protected,
           let data = try? Data(contentsOf: fileURL),
           let image = try? ImageDecoding.decode(data) {
            return image
        }
        // 実生成(ソース展開・レンダリング)だけを全体ゲートで絞る。
        // ゲートはキャンセルで抜けられないので、行列に入る前にもう一度
        // キャンセル済みを弾く(キャンセル嵐が生きた生成を待たせないように)
        guard !Task.isCancelled else { return nil }
        // 可視セル要求は優先レーン。1 段目(このゲート)は明示レーンで指定し、
        // 2 段目(source 内の FolderSource.readGate、currentPriority 推論)は
        // 生成タスクを urgent 時 userInitiated で起動することで対話レーンへ寄せる
        // (:131 参照。ここで明示レーンにするだけでは 2 段目で背面に落ちる)
        await gate.acquire(interactive: urgent)
        let image: CGImage?
        if Task.isCancelled {
            image = nil
        } else {
            image = try? await source.image(for: entry, maxPixelSize: maxPixelSize)
        }
        await gate.release()
        guard let image else { return nil }
        if !protected {
            writeToDisk(image, at: fileURL)
        }
        return image
    }

    private static func writeToDisk(_ image: CGImage, at fileURL: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 一時ファイルへ書いて原子的に差し替える(中断・満杯で切り詰めた HEIC を
        // 最終パスに残さない。他の永続化 3 箇所と同じ tmp+replace 方針)。UUID
        // サフィックスで同一 fileURL への並行書込み衝突を避ける
        let tmpURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).heic.tmp")
        // HEIC(ハードウェアエンコード)。サムネイル画質は 0.75 で十分
        guard let destination = CGImageDestinationCreateWithURL(
            tmpURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else { return }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            try? manager.removeItem(at: tmpURL)  // 失敗は最終パスを触らない
            return
        }
        do {
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                try manager.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            try? manager.removeItem(at: tmpURL)
        }
    }
}
