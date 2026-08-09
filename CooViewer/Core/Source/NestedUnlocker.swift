import Foundation

/// ネスト書庫/PDF のパスワード入力を UI に求めるコールバック。
/// 引数は本の中での表示名と試行回数(1 始まり。2 回目以降は誤入力後の再試行)。
/// nil はキャンセル。
/// EN: Asks the UI for a nested book's password; attempt is 1-based (>= 2 means
/// EN: the previous entry was wrong); nil means the user cancelled.
typealias NestedPasswordProvider = @Sendable (_ name: String, _ attempt: Int) async -> String?

/// 書庫内書庫/PDF のロック解除係(仕様書 §4.1.3 のネスト版)。
/// 1 冊の本の全ネスト階層で 1 つを共有し、
/// - 既知のパスワード(外側書庫のもの・過去に入力されたもの)をまず試し、
/// - 駄目なら provider(パスワードダイアログ)へ最大 3 回問い合わせる。
/// キャンセルされたら以降この本では尋ねない(連続ダイアログの防止)。
/// EN: One unlocker is shared by every nesting level of a book: it retries
/// EN: known passwords first, then prompts (3 attempts); a cancel disables
/// EN: further prompting for this book.
actor NestedUnlocker {
    private var knownPasswords: [String]
    private var promptingDisabled = false
    private var provider: NestedPasswordProvider?
    /// 解除できず本から外した子があったか。バックグラウンド準備で組んだ
    /// ソース(provider なし)を開く時に使い回してよいかの判定に使う
    /// EN: Whether any child was skipped still-locked; used to decide if a
    /// EN: background-prepared source is safe to reuse on interactive open.
    private(set) var sawSkippedChild = false

    init(provider: NestedPasswordProvider? = nil, knownPasswords: [String] = []) {
        self.provider = provider
        self.knownPasswords = knownPasswords
    }

    /// provider を後付けする(バックグラウンド準備で作ったソースを
    /// 対話的に開き直すとき用)。キャンセル状態は変えない
    /// EN: Attach a provider after the fact (background-prepared sources).
    func setProvider(_ provider: NestedPasswordProvider?) {
        self.provider = provider
    }

    /// 解除に成功したパスワードを記録する(他のネスト本で再利用)
    /// EN: Remember a working password for reuse on sibling nested books.
    func addKnown(_ password: String) {
        guard !knownPasswords.contains(password) else { return }
        knownPasswords.append(password)
    }

    /// 直列化用の末尾タスク(並列の子構築から呼ばれても、解錠処理と
    /// ダイアログは 1 つずつ順番に行う。actor 再入での多重プロンプト防止)
    /// EN: Serialization tail so concurrent child builds never interleave
    /// EN: unlock bodies or show overlapping prompts (actor reentrancy guard).
    private var serialTail: Task<Bool, Never>?

    /// child のロック解除を試みる。成功で true、失敗/キャンセルで false
    /// (呼び出し側はその子を本から外す。仕様書 §4.17 の黙殺方針)。
    /// 呼び出しは到着順に直列実行される
    /// EN: Try to unlock the child; calls run strictly one at a time.
    func unlock(_ child: any BookSource, name: String) async -> Bool {
        let previous = serialTail
        let task = Task { [previous] in
            _ = await previous?.value
            return await self.performUnlock(child, name: name)
        }
        serialTail = task
        return await task.value
    }

    private func performUnlock(_ child: any BookSource, name: String) async -> Bool {
        for password in knownPasswords {
            if await child.checkAndSetPassword(password) { return true }
        }
        guard let provider, !promptingDisabled else {
            sawSkippedChild = true
            return false
        }
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            guard let entered = await provider(name, attempt) else {
                promptingDisabled = true  // キャンセル=この本ではもう尋ねない
                sawSkippedChild = true
                return false
            }
            if await child.checkAndSetPassword(entered) {
                addKnown(entered)
                return true
            }
        }
        sawSkippedChild = true
        return false
    }
}
