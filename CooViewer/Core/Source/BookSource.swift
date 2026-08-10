import CoreGraphics
import Foundation

/// 本の中の 1 ページ(1 画像)を表す。
/// EN: One page (one image) of a book.
struct PageEntry: Sendable, Hashable, Identifiable {
    /// ソース内での安定 ID(書庫エントリ番号 / PDF ページ番号 / フォルダ列挙順)
    /// EN: Stable ID within the source (archive entry no. / PDF page no. / folder order).
    let id: Int
    /// 表示名(拡張子付きファイル名)
    let name: String
    /// 本の中の相対パス。ソート(名前順)とサブフォルダ移動の単位に使う。
    /// PDF はページ番号を 0 埋めした擬似パス。
    /// EN: Relative path inside the book; used as the sort key and subfolder unit.
    /// EN: PDFs use a zero-padded page number as a pseudo path.
    let pathInBook: String
    /// 実ファイルの URL(フォルダの本のみ。Finder 表示・ゴミ箱に使う)
    let fileURL: URL?
    let creationDate: Date?
    let modificationDate: Date?

    /// 本の中でこのページが属するフォルダ(サブフォルダ移動の判定単位。仕様書 §4.3.5)
    /// EN: Folder this page belongs to inside the book (subfolder-navigation unit).
    var containerPath: String {
        (pathInBook as NSString).deletingLastPathComponent
    }

    /// 表示用の名前。relativePath 指定時はサブフォルダ/書庫内の相対パスを含める。
    /// 擬似パスのソース(PDF: 0 埋めページ番号)は末尾がファイル名と一致しないため
    /// 末尾をページ名に置き換える: 最上位 PDF は名前のみ、ネストした PDF は
    /// 「書庫内パス/ページ名」(巻をまたいで同じ「ページ N」にならないように)。
    /// EN: Name for display; with relativePath, includes the in-book path.
    /// EN: Pseudo-path sources (PDF) swap the last component for the page name,
    /// EN: so nested PDFs keep their container path and stay distinguishable.
    func displayTitle(relativePath: Bool) -> String {
        guard relativePath, pathInBook != name else { return name }
        if (pathInBook as NSString).lastPathComponent == name { return pathInBook }
        let container = containerPath
        return container.isEmpty ? name : container + "/" + name
    }
}

enum BookSourceError: Error {
    case unreadable(URL)
    case unsupportedFormat(URL)
    case pageLoadFailed(String)
}

/// 「本」の供給源(フォルダ / 書庫 / PDF)。
/// 旧実装の COImageLoader(仕様書 §2.4)に相当するが、mode 整数ではなく型で区別する。
/// EN: Supplies a book's pages (folder / archive / PDF); a typed replacement
/// EN: for the legacy COImageLoader and its integer "mode".
protocol BookSource: Sendable {
    var url: URL { get }
    /// ウインドウタイトル等に使う表示名(旧実装同様、拡張子付き lastPathComponent)
    var displayName: String { get }
    /// 日付ソートが可能か(仕様書 §4.4.2: フォルダ系のみ)
    var supportsDateSort: Bool { get }

    /// 全ページをソース順(未ソート)で返す。
    /// EN: All pages in source order (unsorted).
    func entries() async throws -> [PageEntry]

    /// ページ画像をデコードして返す。maxPixelSize を指定すると長辺をその値以下に
    /// 縮小した画像を返す(サムネイル用)。
    /// EN: Decode one page; maxPixelSize caps the long side (used for thumbnails).
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage

    /// パスワード付き書庫か
    func isEncrypted() async -> Bool
    /// パスワードを設定し、正しければ true(仕様書 §4.1.3)
    func checkAndSetPassword(_ password: String) async -> Bool

    /// image(for:) を並列に呼んでよいか(actor 直列化が不要なソースのみ true)
    var supportsParallelPageLoads: Bool { get }

    /// いまの状態での並列可否(書庫: 全スプール済み or 非 solid 形式のみ true。
    /// solid 書庫の順不同展開によるストリーム巻き戻しを避ける)
    /// EN: Current parallel-load capability (archives: only when fully
    /// EN: spooled or a non-solid format, avoiding solid-stream restarts).
    func currentlySupportsParallelPageLoads() async -> Bool

    /// 開いた直後のバックグラウンド準備(書庫のローカルスプール等)。
    /// パスワード解除後に一度だけ呼ばれる。すぐ戻ること。
    /// spoolSizeLimit: ローカル一時展開に使ってよい合計バイト数
    /// EN: One-shot background warm-up after unlock (archive spooling); returns fast.
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async

    /// ルーペ用の高解像度画像。既定はフル解像度デコード(表示キャップで
    /// 縮小されたラスタ画像もルーペでは原寸になる)。ベクトルソースは
    /// pixelScale 連動でラスタライズし直す。
    /// EN: High-res image for the loupe; vector sources re-rasterize at pixelScale.
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage

    /// ページの元データ(アニメーション再生用)。提供できないソースは nil
    /// EN: Raw page data for animation playback; nil when unavailable.
    func imageData(for entry: PageEntry) async -> Data?

    /// 解除できずに本から外したネスト書庫/PDF があるか(バックグラウンド準備で
    /// 組んだソースを対話的に開くときの使い回し判定。ネスト対応ソースのみ実装)
    /// EN: Whether locked nested children were skipped during assembly.
    func hasSkippedLockedContent() async -> Bool

    /// ページのピクセル寸法をヘッダ情報だけから返す(EXIF 回転適用後)。
    /// デコードなしで見開き判定(縦横比)を行うため。取れないソースは nil を
    /// 返し、呼び出し側は従来のデコード判定へフォールバックする
    /// EN: Pixel size from header metadata only (EXIF rotation applied), so
    /// EN: spread pairing needs no decode; nil falls back to decoding.
    func imageSize(for entry: PageEntry) async -> CGSize?

    /// ネストのパスワード入力コールバックを後付けする(準備済みソースの再利用時)
    /// EN: Attach a nested-password provider to a prepared source.
    func attachNestedPasswordProvider(_ provider: NestedPasswordProvider?) async

    /// 統合ソースの組み立て進捗(完了した子の数, 子の総数)の通知先を設定する。
    /// 子の本を持たないソースは何もしない
    /// EN: Set the assembly-progress callback (children done, total);
    /// EN: no-op for sources without child books.
    func setAssemblyProgressHandler(_ handler: (@Sendable (Int, Int) -> Void)?) async

    /// このページをディスク上で代表する実体ファイル(仕様書 §4.13 Finder 表示、
    /// ファイル情報)。フォルダの単体画像はその画像ファイル、書庫/PDF 内の
    /// ページは書庫/PDF 本体
    /// EN: The on-disk file representing this page: the image file itself for
    /// EN: folder pages, the containing archive/PDF for nested pages.
    func containerFileURL(for entry: PageEntry) async -> URL

    /// 本の置き場所の速度プロファイルを適用する(読み取り並列度・スプール方針)。
    /// beginBackgroundPreparation より前に呼ぶこと
    /// EN: Apply the volume-speed profile (read concurrency, spool policy);
    /// EN: call before beginBackgroundPreparation.
    func applyMediaProfile(_ profile: MediaProfile) async
}

extension BookSource {
    var displayName: String { url.lastPathComponent }
    func isEncrypted() async -> Bool { false }
    func checkAndSetPassword(_ password: String) async -> Bool { true }
    var supportsParallelPageLoads: Bool { false }
    func currentlySupportsParallelPageLoads() async -> Bool { supportsParallelPageLoads }
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {}
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        try await image(for: entry, maxPixelSize: nil)
    }
    func imageData(for entry: PageEntry) async -> Data? { nil }
    func imageSize(for entry: PageEntry) async -> CGSize? { nil }
    func hasSkippedLockedContent() async -> Bool { false }
    func attachNestedPasswordProvider(_ provider: NestedPasswordProvider?) async {}
    func setAssemblyProgressHandler(
        _ handler: (@Sendable (Int, Int) -> Void)?) async {}
    func containerFileURL(for entry: PageEntry) async -> URL {
        entry.fileURL ?? url
    }
    func applyMediaProfile(_ profile: MediaProfile) async {}
}

enum BookSourceFactory {
    /// URL から適切な BookSource を生成する。
    /// 単一画像ファイル → 親フォルダの読み替え(仕様書 §4.1.2 手順 2)は呼び出し側で
    /// 済ませておくこと。
    /// EN: Pick the right BookSource for a URL; the "single image opens its parent
    /// EN: folder" rewrite must be done by the caller.
    /// nestedPasswordProvider: 暗号化されたネスト書庫/PDF のパスワードを UI に
    /// 求めるコールバック(nil なら既知パスワードのみ試して黙って飛ばす)
    /// EN: nestedPasswordProvider asks the UI for nested books' passwords;
    /// EN: nil silently skips still-locked children.
    static func make(for url: URL, readSubFolders: Bool,
                     nestedPasswordProvider: NestedPasswordProvider? = nil)
        async throws -> any BookSource {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw BookSourceError.unreadable(url)
        }
        let unlocker = NestedUnlocker(provider: nestedPasswordProvider)
        if isDirectory.boolValue {
            let folder = try FolderSource(url: url, readSubFolders: readSubFolders)
            // 書庫/PDF を含むフォルダは統合ソースで包む(旧ネストローダー §2.4)。
            // 画像だけなら従来どおり(並列ロード・日付ソート可を維持)
            // EN: Wrap only folders that contain books; plain image folders
            // EN: keep the parallel, date-sortable FolderSource.
            if folder.nestedBookCandidates.isEmpty {
                return folder
            }
            return NestedFolderSource(folder: folder, unlocker: unlocker)
        }
        if SupportedTypes.isPDF(url) {
            return try PDFSource(url: url)
        }
        if SupportedTypes.isArchive(url) {
            return try ArchiveSource(url: url, unlocker: unlocker)
        }
        throw BookSourceError.unsupportedFormat(url)
    }
}
