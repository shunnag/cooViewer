import CoreGraphics
import Foundation

/// 本の中の 1 ページ(1 画像)を表す。
struct PageEntry: Sendable, Hashable, Identifiable {
    /// ソース内での安定 ID(書庫エントリ番号 / PDF ページ番号 / フォルダ列挙順)
    let id: Int
    /// 表示名(拡張子付きファイル名)
    let name: String
    /// 本の中の相対パス。ソート(名前順)とサブフォルダ移動の単位に使う。
    /// PDF はページ番号を 0 埋めした擬似パス。
    let pathInBook: String
    /// 実ファイルの URL(フォルダの本のみ。Finder 表示・ゴミ箱に使う)
    let fileURL: URL?
    let creationDate: Date?
    let modificationDate: Date?

    /// 本の中でこのページが属するフォルダ(サブフォルダ移動の判定単位。仕様書 §4.3.5)
    var containerPath: String {
        (pathInBook as NSString).deletingLastPathComponent
    }
}

enum BookSourceError: Error {
    case unreadable(URL)
    case unsupportedFormat(URL)
    case pageLoadFailed(String)
}

/// 「本」の供給源(フォルダ / 書庫 / PDF)。
/// 旧実装の COImageLoader(仕様書 §2.4)に相当するが、mode 整数ではなく型で区別する。
protocol BookSource: Sendable {
    var url: URL { get }
    /// ウインドウタイトル等に使う表示名(旧実装同様、拡張子付き lastPathComponent)
    var displayName: String { get }
    /// 日付ソートが可能か(仕様書 §4.4.2: フォルダ系のみ)
    var supportsDateSort: Bool { get }

    /// 全ページをソース順(未ソート)で返す。
    func entries() async throws -> [PageEntry]

    /// ページ画像をデコードして返す。maxPixelSize を指定すると長辺をその値以下に
    /// 縮小した画像を返す(サムネイル用)。
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage

    /// パスワード付き書庫か
    func isEncrypted() async -> Bool
    /// パスワードを設定し、正しければ true(仕様書 §4.1.3)
    func checkAndSetPassword(_ password: String) async -> Bool

    /// image(for:) を並列に呼んでよいか(actor 直列化が不要なソースのみ true)
    var supportsParallelPageLoads: Bool { get }

    /// 開いた直後のバックグラウンド準備(書庫のローカルスプール等)。
    /// パスワード解除後に一度だけ呼ばれる。すぐ戻ること。
    func beginBackgroundPreparation() async

    /// ルーペ用の高解像度画像。既定はフル解像度デコード(表示キャップで
    /// 縮小されたラスタ画像もルーペでは原寸になる)。ベクトルソースは
    /// pixelScale 連動でラスタライズし直す。
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage

    /// ページの元データ(アニメーション再生用)。提供できないソースは nil
    func imageData(for entry: PageEntry) async -> Data?
}

extension BookSource {
    var displayName: String { url.lastPathComponent }
    func isEncrypted() async -> Bool { false }
    func checkAndSetPassword(_ password: String) async -> Bool { true }
    var supportsParallelPageLoads: Bool { false }
    func beginBackgroundPreparation() async {}
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        try await image(for: entry, maxPixelSize: nil)
    }
    func imageData(for entry: PageEntry) async -> Data? { nil }
}

enum BookSourceFactory {
    /// URL から適切な BookSource を生成する。
    /// 単一画像ファイル → 親フォルダの読み替え(仕様書 §4.1.2 手順 2)は呼び出し側で
    /// 済ませておくこと。
    static func make(for url: URL, readSubFolders: Bool) async throws -> any BookSource {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BookSourceError.unreadable(url)
        }
        if isDirectory.boolValue {
            return try FolderSource(url: url, readSubFolders: readSubFolders)
        }
        if SupportedTypes.isPDF(url) {
            return try PDFSource(url: url)
        }
        if SupportedTypes.isArchive(url) {
            return try ArchiveSource(url: url)
        }
        throw BookSourceError.unsupportedFormat(url)
    }
}
