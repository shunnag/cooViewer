import CryptoKit
import Foundation
import Security

/// 書庫/PDF パスワードの保管庫(設計書 §2.4 パスワードマネージャー)。
///
/// Keychain にはランダムなマスターキーを 1 つだけ置き、パスワード本体は
/// Application Support/jp.coo.cooViewer/Passwords/vault.enc へ AES-GCM で
/// 暗号化して保存する。per-item の Keychain 保存は ad-hoc 署名の Debug
/// ビルドでビルド毎×書庫毎に許可ダイアログが出て開発が成り立たないため
/// 不採用(マスターキー方式ならリビルド後の初回 1 回で済む)。
///
/// 規律: 平文は絶対にディスクへ書かない(seal 失敗=保存しない)。復号失敗
/// (鍵喪失・破損)は空の保管庫として扱う(fail-closed)。パスワード・鍵は
/// ログに出さない。XCTest ではキーチェーンに一切触れない。
actor PasswordVault {
    static let shared = PasswordVault()

    /// 保存キー。実ファイルは正規化パス 1 要素、書庫内書庫(一時展開される
    /// ネスト)は親キー+書庫内パスを要素として積む。文字列化は JSON 配列 —
    /// 区切り文字の連結はパスやエントリ名に同じ文字が合法に現れて衝突する
    /// ため使わない(非単射の回避)
    struct Key: Sendable, Hashable {
        let components: [String]

        /// ディスク上の実ファイル(単体の書庫/PDF・コレクション内の子)。
        /// コレクション内と単体オープンの共有はこの正規化に依存する
        static func file(path: String) -> Key {
            Key(components: [CanonicalPath.normalize(path)])
        }

        /// 親書庫の中のエントリ(zip 内 zip 等)。深さ 2 以上も要素を積むだけ
        func nested(entryPath: String) -> Key {
            Key(components: components + [entryPath])
        }

        /// 保管庫内の辞書キー(JSON 配列文字列)
        var storageString: String {
            guard let data = try? JSONEncoder().encode(components),
                  let text = String(data: data, encoding: .utf8) else {
                // JSONEncoder が [String] で失敗することは実際にはない
                return components.joined(separator: "\u{1F}")
            }
            return text
        }
    }

    private struct Entry: Codable {
        var password: String
        var createdAt: Double
        var lastUsedAt: Double
    }

    private struct VaultFile: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private enum Backing {
        case uninitialized
        /// 鍵が得られない(Keychain 拒否・XCTest)— 保存も照会も静かに諦める
        case unavailable
        case ready(key: SymmetricKey, entries: [String: Entry])
    }

    private var backing: Backing = .uninitialized
    private let injectedKey: SymmetricKey?
    private let directory: URL

    /// 通常運用: 遅延初期化でマスターキーを 1 回だけ取得する
    init() {
        // 検証用の鍵・保存先注入(development-guide §2)。Debug ビルド限定 —
        // Release で環境変数を受けると、同一ユーザーの悪性プロセスが環境を
        // 仕込むだけで既知鍵での封緘に格下げできてしまう。実運用の vault.enc を
        // 誤って壊さないよう、鍵と保存先は必ずセットで要求する
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let hex = env["COOVIEWER_TEST_VAULT_KEY"],
           let dir = env["COOVIEWER_TEST_VAULT_DIR"],
           let keyData = Data(hexString: hex), keyData.count == 32 {
            injectedKey = SymmetricKey(data: keyData)
            directory = URL(fileURLWithPath: dir, isDirectory: true)
            return
        }
        #endif
        injectedKey = nil
        directory = FileManager.default
            .userDomainDirectory(.applicationSupportDirectory)
            .appendingPathComponent("jp.coo.cooViewer/Passwords", isDirectory: true)
    }

    /// テスト用: Keychain 非依存(SuperResCacheCryptoTests と同じ分離方針)
    init(key: SymmetricKey, directory: URL) {
        injectedKey = key
        self.directory = directory
    }

    /// 自動解錠が有効なときだけ shared を返す(呼び出し側の配線を 1 行にする)
    nonisolated static func sharedIfEnabled() -> PasswordVault? {
        UserDefaults.standard.bool(forKey: "PasswordVaultEnabled") ? shared : nil
    }

    // MARK: - 公開 API

    /// 自動解錠トグルの即時反映: 注入鍵(テスト)以外は毎回 defaults を見る。
    /// 準備済みソース等、構築時に配線された vault にも OFF が即座に効く
    private var isEnabledNow: Bool {
        injectedKey != nil || UserDefaults.standard.bool(forKey: "PasswordVaultEnabled")
    }

    /// 保存済みパスワード。ヒット時は lastUsedAt を更新する(書き戻しは保存時
    /// にまとめる — 照会のたびにディスクへ書かない)
    func password(for key: Key) -> String? {
        guard isEnabledNow else { return nil }
        guard case .ready(_, var entries) = loadedBacking() else { return nil }
        let storageKey = key.storageString
        guard var entry = entries[storageKey] else { return nil }
        entry.lastUsedAt = Date().timeIntervalSince1970
        entries[storageKey] = entry
        if case .ready(let cryptoKey, _) = backing {
            backing = .ready(key: cryptoKey, entries: entries)
        }
        return entry.password
    }

    /// 保存(同キーは上書き=パスワード変更対応)。seal できない場合は書かない
    func save(_ password: String, for key: Key) {
        guard isEnabledNow else { return }
        guard case .ready(let cryptoKey, var entries) = loadedBacking() else { return }
        let now = Date().timeIntervalSince1970
        let storageKey = key.storageString
        let createdAt = entries[storageKey]?.createdAt ?? now
        entries[storageKey] = Entry(password: password, createdAt: createdAt,
                                    lastUsedAt: now)
        backing = .ready(key: cryptoKey, entries: entries)
        persist(entries: entries, using: cryptoKey)
    }

    func deleteAll() {
        if case .ready(let cryptoKey, _) = loadedBacking() {
            backing = .ready(key: cryptoKey, entries: [:])
        }
        // マスターキーは残す(再保存時の Keychain プロンプト再発を防ぐ)
        try? FileManager.default.removeItem(at: vaultURL)
    }

    func count() -> Int {
        guard case .ready(_, let entries) = loadedBacking() else { return 0 }
        return entries.count
    }

    /// 設定 UI 用: 保管庫が使える状態か(Keychain 拒否時は false)
    func isAvailable() -> Bool {
        if case .ready = loadedBacking() { return true }
        return false
    }

    // MARK: - 読み書き

    private var vaultURL: URL { directory.appendingPathComponent("vault.enc") }

    private func loadedBacking() -> Backing {
        if case .uninitialized = backing {
            backing = loadBacking()
        }
        return backing
    }

    private func loadBacking() -> Backing {
        let key: SymmetricKey
        if let injectedKey {
            key = injectedKey
        } else if AutomatedRun.isXCTest || AutomatedRun.isSnapshot {
            // テスト・スナップショット検証では Keychain に一切触れない
            // (検証は COOVIEWER_TEST_VAULT_KEY の注入鍵で行う)
            return .unavailable
        } else if let loaded = VaultKeyStore.loadOrCreateKey() {
            key = loaded
        } else {
            return .unavailable  // 拒否・失敗はセッション内で静かに無効
        }
        guard let combined = try? Data(contentsOf: vaultURL),
              let plain = SuperResCacheCrypto.open(combined, using: key),
              let file = try? JSONDecoder().decode(VaultFile.self, from: plain) else {
            // ファイル無し・鍵違い・破損はいずれも空の保管庫(fail-closed)
            return .ready(key: key, entries: [:])
        }
        return .ready(key: key, entries: file.entries)
    }

    /// メモリ内 JSON → seal → tmp → rename の原子的置換。0600・平文を残さない
    private func persist(entries: [String: Entry], using key: SymmetricKey) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        guard let plain = try? JSONEncoder().encode(
                VaultFile(version: 1, entries: entries)),
              let sealed = SuperResCacheCrypto.seal(plain, using: key) else { return }
        let tmpURL = directory.appendingPathComponent("vault.enc.tmp")
        do {
            try sealed.write(to: tmpURL)
            try manager.setAttributes([.posixPermissions: 0o600],
                                      ofItemAtPath: tmpURL.path)
            _ = try manager.replaceItemAt(vaultURL, withItemAt: tmpURL)
        } catch {
            try? manager.removeItem(at: tmpURL)
        }
    }
}

/// PasswordVault のマスターキー保管庫(SuperResCacheKeyStore と同型。
/// ログインキーチェーンにランダム 256bit 鍵を 1 つ、デバイス限定・iCloud 非同期)
enum VaultKeyStore {
    private static let service = "jp.coo.cooViewer.password-vault"
    private static let account = "vaultKey"
    private static let keyByteCount = 32

    nonisolated static func loadOrCreateKey() -> SymmetricKey? {
        if let existing = load() { return existing }
        return create()
    }

    private nonisolated static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private nonisolated static func load() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == keyByteCount else { return nil }
        return SymmetricKey(data: data)
    }

    private nonisolated static func create() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = keyData
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return key }
        if status == errSecDuplicateItem { return load() }
        return nil
    }
}

private extension Data {
    /// 16 進文字列(64 桁=32byte)からの変換。スナップショット検証の鍵注入用
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        self = data
    }
}
