import Foundation

/// パスワード検証の結果(仕様書 §4.1.3、cooViewer-3tfd)。
/// 旧実装の Bool では「読めなかった」が「誤パスワード」に潰れ、不安定なネットワーク
/// ボリュームで正しい保存パスワードがダイアログと試行回数の消費を招いていた。
enum PasswordCheck: Sendable, Equatable {
    /// 正しいパスワード。ソースは設定済みで以後の展開に使う
    case accepted
    /// 誤パスワード(従来の false)
    case rejected
    /// 環境要因でプローブを読めず、正否を判定できなかった。
    /// 呼び出し側は試行回数を消費せず、保存パスワードも消さない
    case unreadable
}

/// 保存パスワードの自動試行方針(設計書 §2.4、cooViewer-3tfd)。
enum SavedPasswordPolicy {
    /// 検証を一度行い、読み取り失敗なら一時的なものと見て一度だけやり直す。
    /// 二度続けて読めなければ unreadable のまま返し、呼び出し側はダイアログを出さずに
    /// 終える(正しい保存パスワードを「誤り」と誤認して試行回数を燃やさないため)
    static func verify(_ check: @Sendable () async -> PasswordCheck) async -> PasswordCheck {
        let first = await check()
        guard first == .unreadable else { return first }
        return await check()
    }
}
