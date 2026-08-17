import CryptoKit
import Foundation
import Security

/// 超解像ディスクキャッシュ(SuperRes/)の暗号化(設計書 キャッシュ節・CWE-312 対策)。
/// パスワード付き書庫の復号済みページを平文で残さないため、キャッシュ実体を
/// ランダム鍵で AES-GCM(認証付き)暗号化して保存する。鍵はログインキーチェーンに
/// 置くので、保護境界は「そのユーザーでログイン中であること」になる — 書庫パスワードの
/// 強度(=低エントロピーになりがち)にキャッシュ安全性を縛られない設計。
enum SuperResCacheCrypto {
    /// data を AES-GCM でシールし、nonce+暗号文+タグをまとめた combined を返す。
    /// 失敗時は nil(呼び出し側は「書けなかった」として扱い、平文では絶対に残さない)
    nonisolated static func seal(_ data: Data, using key: SymmetricKey) -> Data? {
        guard let sealed = try? AES.GCM.seal(data, using: key) else { return nil }
        return sealed.combined
    }

    /// combined 形式のシール済みデータを復号する。鍵違い・改竄・破損・旧平文
    /// ファイルはいずれも復号に失敗するので nil(=キャッシュミス扱い)
    nonisolated static func open(_ combined: Data, using key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }
}

/// 超解像キャッシュ暗号化鍵の保管庫。ログインキーチェーンにランダムな 256bit 鍵を
/// 1 つ持ち、初回に生成して以降は読み出す。取得できない場合は nil を返し、呼び出し側は
/// ディスクキャッシュを諦めてメモリのみで動く(平文で書き出すことは絶対にしない)。
enum SuperResCacheKeyStore {
    private static let service = "jp.coo.cooViewer.superres-cache"
    private static let account = "superResDiskCacheKey"
    /// 鍵長(byte)。SymmetricKey(size: .bits256) と一致させる
    private static let keyByteCount = 32

    /// 既存鍵を読み出す。無ければランダム生成してキーチェーンへ保存し返す。
    /// キーチェーンにアクセスできない/生成に失敗した場合は nil
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
        // デバイス限定・初回アンロック後に利用可(iCloud 同期しない。キャッシュは
        // どのみち端末ローカルなので同期不要で、鍵の露出面も狭められる)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return key }
        // 別スレッド/別プロセスが先に作成していた場合は読み直す
        if status == errSecDuplicateItem { return load() }
        return nil
    }
}
