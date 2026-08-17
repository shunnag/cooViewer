import Foundation

extension FileManager {
    /// `urls(for:in:).first` のトラップ安全版。
    ///
    /// 起動時のキャッシュ/本の状態ディレクトリ解決は
    /// `urls(for:in:.userDomainMask)[0]` で先頭を取り出していたが、検索パスが空配列
    /// を返すと `[0]` がトラップしてプロセスごとクラッシュする。通常のユーザー環境では
    /// 空になることはまずないものの、権限・プロファイル異常時の「本を開く前の
    /// ランダムクラッシュ」を招きうる唯一の強制添字だったため、空なら NSHomeDirectory
    /// 基準の既定パスへフォールバックする(以後の実ファイル操作は従来どおり `try?` で
    /// 失敗を握るので、異常環境でもクラッシュせず degrade する)。
    func userDomainDirectory(_ directory: SearchPathDirectory) -> URL {
        if let url = urls(for: directory, in: .userDomainMask).first {
            return url
        }
        let library = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        switch directory {
        case .applicationSupportDirectory:
            return library.appendingPathComponent("Application Support", isDirectory: true)
        case .cachesDirectory:
            return library.appendingPathComponent("Caches", isDirectory: true)
        default:
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
    }
}
