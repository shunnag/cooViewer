import Foundation

/// 永続化ファイルの三態読み取り。BookHistoryStore と PasswordVault が
/// 「読めない ≠ 存在しない」を同じ規則で判定するための共通プリミティブ。
///
/// 一過性の読み取り失敗を「ファイルが無い」と同一視すると、直後の書き込みが
/// 既存の中身を破壊的に上書き/削除してしまう(しおり全消失・保存パスワード
/// 全消去)。`absent` と `unreadable` を区別することで、在るのに読めない間は
/// 上書きを止め、読めるようになったら中身を保てるようにする(CanonicalPath と
/// 同じ「両ストア共有の nonisolated static ユーティリティ」の位置づけ)。
enum FileBytes: Sendable {
    /// 無い(または 0 バイト)= 未作成同等。新規作成してよい
    case absent
    /// 在るが読めない(I/O エラー・復号/デコード不能)= 中身を壊さないこと
    case unreadable
    /// 非空の内容
    case data(Data)
}

enum PersistedFile {
    /// url を三態で読む。0 バイトは absent 扱い(中断作成の残骸で失う中身が
    /// 無いため新規化を許す)。fileExists→read の間に削除が挟まれば unreadable に
    /// 倒れるが、これは安全側(潰さない)への誤りで次回の照会で自己回復する
    nonisolated static func readBytes(at url: URL) -> FileBytes {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return data.isEmpty ? .absent : .data(data)
    }
}
