import Foundation

/// パスワードダイアログの回答。saveRequested はダイアログの
/// 「このパスワードを保存」チェックボックスの状態(設計書 §2.4)
struct NestedPasswordAnswer: Sendable {
    let password: String
    let saveRequested: Bool
}

/// ネスト書庫/PDF のパスワード入力を UI に求めるコールバック。
/// 引数は本の中での表示名と試行回数(1 始まり。2 回目以降は誤入力後の再試行)。
/// nil はキャンセル。
typealias NestedPasswordProvider =
    @Sendable (_ name: String, _ attempt: Int) async -> NestedPasswordAnswer?

/// 書庫内書庫/PDF のロック解除係(仕様書 §4.1.3 のネスト版)。
/// 1 冊の本の全ネスト階層で 1 つを共有し、
/// - 保存済みパスワード(PasswordVault)を子の保存キーでまず引き、
/// - 次に既知のパスワード(外側書庫のもの・過去に入力されたもの)を試し、
/// - 駄目なら provider(パスワードダイアログ)へ最大 3 回問い合わせる。
/// キャンセルされたら以降この本では尋ねない(連続ダイアログの防止)。
/// 保存はユーザーが同意したパスワードのみ: 同意済み集合にあるパスワードが
/// 子で成功したら子のキーへも保存する(コレクション内の同一パスワード群を
/// 1 回の同意で展延)。同意のないパスワードは絶対に永続化しない。
actor NestedUnlocker {
    private var knownPasswords: [String]
    private var promptingDisabled = false
    private var provider: NestedPasswordProvider?
    private let vault: PasswordVault?
    /// ユーザーが「保存」に同意したパスワード(ダイアログのチェックボックス、
    /// または保存済み=過去に同意済みだったもの)
    private var consentedPasswords: Set<String> = []
    /// 解除できず本から外した子があったか。バックグラウンド準備で組んだ
    /// ソース(provider なし)を開く時に使い回してよいかの判定に使う
    private(set) var sawSkippedChild = false
    /// 解除に成功した(=暗号化されていた)子があったか。復号済み保護コンテンツを
    /// 含む本かの判定に使う(超解像ディスクキャッシュの暗号化要否。CWE-312)。
    /// unlock() は暗号化された子に対してのみ呼ばれる(呼び出し側で isEncrypted 判定済み)
    private(set) var sawUnlockedChild = false

    init(provider: NestedPasswordProvider? = nil, knownPasswords: [String] = [],
         vault: PasswordVault? = nil) {
        self.provider = provider
        self.knownPasswords = knownPasswords
        self.vault = vault
    }

    /// provider を後付けする(バックグラウンド準備で作ったソースを
    /// 対話的に開き直すとき用)。キャンセル状態は変えない
    func setProvider(_ provider: NestedPasswordProvider?) {
        self.provider = provider
    }

    /// 解除に成功したパスワードを記録する(他のネスト本で再利用)
    func addKnown(_ password: String) {
        guard !knownPasswords.contains(password) else { return }
        knownPasswords.append(password)
    }

    /// 最上位ダイアログでの保存同意を子へ引き継ぐ(BookSource 経由で呼ばれる)
    func noteSaveConsent(_ password: String) {
        consentedPasswords.insert(password)
    }

    /// 直列化用の末尾タスク(並列の子構築から呼ばれても、解錠処理と
    /// ダイアログは 1 つずつ順番に行う。actor 再入での多重プロンプト防止)
    private var serialTail: Task<Bool, Never>?

    /// child のロック解除を試みる。成功で true、失敗/キャンセルで false
    /// (呼び出し側はその子を本から外す。仕様書 §4.17 の黙殺方針)。
    /// persistenceKey は保存パスワードの照会・保存キー(呼び出し側が必ず
    /// 実ファイル/親キー由来で組む — 一時展開パスから作らないこと)。
    /// 呼び出しは到着順に直列実行される
    func unlock(_ child: any BookSource, name: String,
                persistenceKey: PasswordVault.Key) async -> Bool {
        let previous = serialTail
        let task = Task { [previous] in
            _ = await previous?.value
            return await self.performUnlock(child, name: name,
                                            persistenceKey: persistenceKey)
        }
        serialTail = task
        return await task.value
    }

    private func performUnlock(_ child: any BookSource, name: String,
                               persistenceKey: PasswordVault.Key) async -> Bool {
        // 保存済みパスワード(照会・失敗とも完全無言 = §4.17 の黙殺と整合)。
        // vault 由来は過去に同意済みなので同意集合に入れる
        if let vault, let saved = await vault.password(for: persistenceKey),
           await child.checkAndSetPassword(saved) {
            consentedPasswords.insert(saved)
            // 兄弟の子(特に PDF は checkAndSetPassword が addKnown を呼ばない)
            // にも展延できるよう既知パスワードとしても記録する
            addKnown(saved)
            sawUnlockedChild = true
            return true
        }
        for password in knownPasswords {
            if await child.checkAndSetPassword(password) {
                if consentedPasswords.contains(password) {
                    await vault?.save(password, for: persistenceKey)
                }
                sawUnlockedChild = true
                return true
            }
        }
        guard let provider, !promptingDisabled else {
            sawSkippedChild = true
            return false
        }
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            guard let answer = await provider(name, attempt) else {
                promptingDisabled = true  // キャンセル=この本ではもう尋ねない
                sawSkippedChild = true
                return false
            }
            if await child.checkAndSetPassword(answer.password) {
                addKnown(answer.password)
                if answer.saveRequested {
                    consentedPasswords.insert(answer.password)
                    await vault?.save(answer.password, for: persistenceKey)
                }
                sawUnlockedChild = true
                return true
            }
        }
        sawSkippedChild = true
        return false
    }
}
