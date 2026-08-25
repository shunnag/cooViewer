import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import XADMaster

/// 書庫(zip/rar/7z 等)を本として読む(仕様書 §2.4, §4.17)。
/// XADArchive はスレッド安全でないため actor で直列化する。
/// ファイル名エンコーディングは XADMaster + UniversalDetector が自動判定する。
///
/// ネットワークドライブや solid 書庫でも快適に読めるよう、開いた後に
/// バックグラウンドで全ページをローカル一時領域へ逐次展開する(スプール。
/// 設計書「キャッシュ・先読み設計」)。スプール済みページはローカル読みになる。
///
/// 書庫内の書庫/PDF は一時領域へ展開して**子ソース**(ArchiveSource/PDFSource)
/// を生成し、そのページを同じ本に取り込む(仕様書 §2.4 のネスト COImageLoader
/// 相当)。ページの相対パスは「書庫内パス/子の相対パス」になる。
actor ArchiveSource: BookSource {
    nonisolated let url: URL
    private let archive: XADArchive
    /// メモリ背景(暗号化親のネスト子)。非 nil のとき disk を読まず、
    /// 展開プールもこの共有 NSData から再オープンする(平文を temp に置かない)
    private let sourceData: Data?
    /// この本の内容が暗号化された祖先由来か(nest 子の平文 temp 回避を子孫へ伝播)
    private let contentIsSensitive: Bool
    /// ルートの ComicInfo.xml エントリ(あれば。cooViewer-4fi.2)
    private let comicInfoEntryIndex: Int32?
    /// ネスト段数(0=最上位)。zip 爆弾対策で 3 段目以降は展開しない
    private let nestingDepth: Int

    /// 最上位書庫の画像エントリ(id=書庫エントリ番号。init で確定)
    private let outerImages: [PageEntry]
    /// ネスト候補(書庫/PDF エントリ。entries() で展開する)
    private let nestedCandidates: [(index: Int32, path: String)]

    /// ページの所在: 最上位書庫のエントリ番号、または子ソースのページ
    private enum PageLocation {
        case outer(entryIndex: Int32)
        case child(sourceIndex: Int, entry: PageEntry)
    }

    /// entries() の組み立て結果(actor 再入で二重構築しないよう Task で共有)
    private var buildTask: Task<[PageEntry], Never>?
    private var locations: [Int: PageLocation] = [:]
    private var children: [any BookSource] = []
    private var nestedRoot: URL?
    private var password: String?
    /// ネスト書庫/PDF のロック解除係(本の全ネスト階層で共有)
    private let unlocker: NestedUnlocker
    /// 保存パスワードのキー(実ファイルの正規化パス、ネストは親キー+書庫内パス)
    private let persistenceKey: PasswordVault.Key
    /// 置き場所の速度プロファイル(スプール方針に使う。既定=従来動作)
    private var mediaProfile: MediaProfile = .unknown

    private var spoolDirectory: URL?
    private var spooledIDs: Set<Int> = []
    /// 暗号化書庫のスプールを暗号化するか(beginSpooling 時に確定)
    private var spoolEncrypted = false
    /// スプール暗号鍵(メモリのみの使い捨て。CWE-312 対策のプロセス限定鍵)
    private let spoolKey = SymmetricKey(size: .bits256)
    private var spoolTask: Task<Void, Never>?

    /// スプールする合計展開サイズの上限(これを超える書庫はオンデマンドのみ)
    static let defaultSpoolSizeLimit: Int64 = 4 << 30

    /// ネスト展開 1 エントリの展開後サイズ上限(zip 爆弾対策)。
    /// build() → appendNestedPages() → nestedChildData() は開いた瞬間に
    /// 自動展開される経路なので、展開後サイズが判るエントリは全展開する前に
    /// ここで弾く。実在するネスト書庫/PDF は数十〜数百 MB、極端な長編でも
    /// ~1GB 程度なので、2GiB を天井にすれば正規のコンテナは通しつつ多 GB の
    /// 展開爆弾を拒否できる。判定は 64bit の uncompressedSizeOfEntry: を使う
    /// (32bit の sizeOfEntry: は ~2.1GB 超で桁溢れし、爆弾が申告する巨大サイズを
    /// 検出できないため上限判定には使えない)。off_t の上限は ~9.2EB なので
    /// この 2GiB は実効的な閾値として働く(超過は確実に弾かれる)
    private static let nestedEntrySizeLimit: Int64 = 2 << 30

    /// 暗号化祖先由来のネスト子をメモリで開く上限(cooViewer-6ax)。超えると
    /// 平文 temp にフォールバックし RAM 常駐(展開プールで共有/複製される
    /// 復号済み NSData)の肥大を防ぐ。実在するネスト書庫/PDF の大半はこの
    /// 256MiB 以下でメモリ経由=平文を disk に置かずに開ける
    static let nestedInMemoryLimit: Int64 = 256 << 20

    /// ComicInfo.xml の展開後サイズ上限(zip 爆弾対策)。標準のメタデータは
    /// 数 KB〜、巨大な Pages 列でも 1MB 未満。16MiB を天井にする(cooViewer-4fi.2)
    private static let comicInfoSizeLimit: Int64 = 16 << 20

    /// ネストページの id 基数(最上位のエントリ番号と衝突しない大きさ)
    private static let nestedIDStride = 1_000_000

    nonisolated var supportsDateSort: Bool { false }
    /// エントリ独立圧縮の形式(並列展開しても solid ストリームの巻き戻しがない)
    private static let nonSolidExtensions: Set<String> = ["zip", "cbz"]

    /// 展開プール(エントリ独立圧縮の形式のみ。PDFSource のレンダラープールと
    /// 同型)。XADArchive は非スレッド安全なので actor 毎に独立の書庫を開き、
    /// 未スプールのページ展開をエントリ間で並列化する(最大 3)。
    /// 空きの再利用が最優先で、**全員使用中のときだけ**成長する:
    /// 直列読み(HDD プロファイル等)では 1 つのままで余計に開かない。
    /// 作成失敗(差し替え・削除)やエントリ数不一致は成長を恒久停止して
    /// メイン書庫の直列展開に戻す(従来と同じ挙動)
    private var extractors: [ArchiveEntryExtractor] = []
    private var extractorBusyCounts: [Int] = []
    private var extractorGrowthDisabled = false
    /// 展開係プールの上限。従来は固定 3。各係は独立した XADArchive の再オープン
    /// (ファイルハンドル + 中央ディレクトリ解析)を伴うので、コア数に応じて
    /// 控えめに増やす(3〜6)。deflate 書庫の並列展開と高速めくりで効く。
    static var extractorPoolSize: Int {  // テスト参照のため internal
        min(max(3, ProcessInfo.processInfo.activeProcessorCount / 2), 6)
    }

    /// いまの状態での並列可否: 全ページスプール済み(ローカル読みのみ)か、
    /// エントリ独立圧縮の形式のみ true。solid 書庫(rar/7z 等)は順不同展開で
    /// ストリームが巻き戻るため、未スプールの間は従来どおり直列
    /// 宣言は要件と同じ async(同期宣言だと async 文脈の直接呼び出しが
    /// プロトコル拡張の既定実装に解決される罠がある。PDFSource 参照)
    func currentlySupportsParallelPageLoads() async -> Bool {
        if !outerImages.isEmpty, spooledIDs.count >= outerImages.count {
            return true
        }
        return Self.nonSolidExtensions.contains(url.pathExtension.lowercased())
    }

    /// スプールの置き場所。<pid>-<uuid> のサブディレクトリを掘る
    /// (起動時掃除で生存プロセスのものを残すため。仕様書 §4.17 の残骸問題への対策)。
    nonisolated static func spoolRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cooViewer-spool")
    }

    /// persistenceKey: 保存パスワードのキー(必ず実ファイルの正規化パス、
    /// またはネストなら親キー由来で組む。デフォルト値を持たせないのは、
    /// 一時展開パス(url が temp)から作った無意味なキーが静かに紛れ込むのを
    /// コンパイル時に防ぐため)
    init(url: URL, nestingDepth: Int = 0, unlocker: NestedUnlocker? = nil,
         persistenceKey: PasswordVault.Key, sensitive: Bool = false) throws {
        self.url = url
        self.sourceData = nil
        self.contentIsSensitive = sensitive
        self.nestingDepth = nestingDepth
        self.unlocker = unlocker ?? NestedUnlocker()
        self.persistenceKey = persistenceKey
        guard let archive = XADArchive(file: url.path) else {
            throw BookSourceError.unreadable(url)
        }
        self.archive = archive
        let enumerated = Self.enumerateEntries(archive, nestingDepth: nestingDepth)
        self.outerImages = enumerated.images
        self.nestedCandidates = enumerated.candidates
        self.comicInfoEntryIndex = enumerated.comicInfo
    }

    /// 暗号化親のネスト子をメモリから開く(復号済みバイトを disk に置かない。
    /// cooViewer-6ax)。name は書庫内パス: 合成 url の拡張子がプール判定/型判定に
    /// 使われる(disk は決して読まない)。sensitive は常に true(暗号化祖先由来)
    init(data: Data, name: String, nestingDepth: Int, unlocker: NestedUnlocker,
         persistenceKey: PasswordVault.Key, sensitive: Bool = true) throws {
        self.url = URL(fileURLWithPath: name)
        self.sourceData = data
        self.contentIsSensitive = sensitive
        self.nestingDepth = nestingDepth
        self.unlocker = unlocker
        self.persistenceKey = persistenceKey
        guard let archive = XADArchive(data: data) else {
            throw BookSourceError.unreadable(url)
        }
        self.archive = archive
        let enumerated = Self.enumerateEntries(archive, nestingDepth: nestingDepth)
        self.outerImages = enumerated.images
        self.nestedCandidates = enumerated.candidates
        self.comicInfoEntryIndex = enumerated.comicInfo
    }

    /// 書庫のエントリを画像/ネスト候補へ振り分ける(両 init 共通)。
    /// 旧実装(XADWrapper)同様、ディレクトリとサイズ 0 のエントリを除外し、
    /// 画像以外のファイルと macOS メタデータ(__MACOSX/、._*)も除外する。
    private static func enumerateEntries(_ archive: XADArchive, nestingDepth: Int)
        -> (images: [PageEntry], candidates: [(index: Int32, path: String)],
            comicInfo: Int32?) {
        var images: [PageEntry] = []
        var candidates: [(index: Int32, path: String)] = []
        var comicInfo: Int32?
        for index in 0..<archive.numberOfEntries() {
            guard let name = archive.name(ofEntry: index) else { continue }
            guard !archive.entryIsDirectory(index), archive.size(ofEntry: index) != 0 else {
                continue
            }
            let lastComponent = (name as NSString).lastPathComponent
            guard !lastComponent.hasPrefix("."), !name.hasPrefix("__MACOSX") else {
                continue
            }
            // ルート直下の ComicInfo.xml(標準メタデータ)を控える(cooViewer-4fi.2)
            if comicInfo == nil, name.lowercased() == "comicinfo.xml" {
                comicInfo = index
                continue
            }
            // ネスト id 域(1M 刻み)との衝突を防ぐ。100 万エントリ超の書庫は
            // 病的ケースなので以降を切り捨てる
            guard index < Int32(Self.nestedIDStride) else { break }
            if SupportedTypes.isImageFile(lastComponent) {
                images.append(PageEntry(
                    id: Int(index),
                    name: lastComponent,
                    pathInBook: name,
                    fileURL: nil,
                    creationDate: nil,
                    modificationDate: nil
                ))
            } else if nestingDepth < 2,
                      SupportedTypes.isBookFile(URL(fileURLWithPath: lastComponent)),
                      !SupportedTypes.isEPUB(URL(fileURLWithPath: lastComponent)) {
                // 書庫内 EPUB は未対応のまま従来どおり無視する(メモリ展開経路が
                // PDF/書庫前提のため。フォルダ内 EPUB は NestedFolderSource が扱う)
                candidates.append((index: index, path: name))
            }
        }
        return (images, candidates, comicInfo)
    }

    deinit {
        spoolTask?.cancel()
        let directories = [spoolDirectory, nestedRoot].compactMap(\.self)
        if !directories.isEmpty {
            Task.detached(priority: .utility) {
                for directory in directories {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
    }

    func entries() async throws -> [PageEntry] {
        await buildIfNeeded()
    }

    @discardableResult
    private func buildIfNeeded() async -> [PageEntry] {
        if let buildTask { return await buildTask.value }
        let task = Task { await build() }
        buildTask = task
        return await task.value
    }

    /// 最上位の画像とネスト展開したページを、書庫の列挙順で 1 つの本に組む
    private func build() async -> [PageEntry] {
        var result: [PageEntry] = []
        var imageIterator = outerImages.makeIterator()
        var pendingImage = imageIterator.next()
        var candidateOrdinal = 0
        for index in 0..<archive.numberOfEntries() {
            if let image = pendingImage, image.id == Int(index) {
                locations[image.id] = .outer(entryIndex: index)
                result.append(image)
                pendingImage = imageIterator.next()
                continue
            }
            guard candidateOrdinal < nestedCandidates.count,
                  nestedCandidates[candidateOrdinal].index == index else { continue }
            let candidate = nestedCandidates[candidateOrdinal]
            candidateOrdinal += 1
            await appendNestedPages(of: candidate, ordinal: candidateOrdinal, into: &result)
        }
        return result
    }

    /// ネスト候補 1 つを一時領域へ展開し、子ソースのページを取り込む。
    /// 失敗(壊れた書庫等)はそのエントリを黙って飛ばす(§4.17 の方針)
    private func appendNestedPages(of candidate: (index: Int32, path: String),
                                   ordinal: Int, into result: inout [PageEntry]) async {
        guard let data = nestedChildData(candidate) else { return }
        // 子のキーは一時展開パス(fileURL)ではなく親キー+書庫内パスで組む
        // (temp パスは起動ごとに変わり保存キーとして無意味になるため)
        let childKey = persistenceKey.nested(entryPath: candidate.path)
        // 暗号化祖先由来の子は復号済み平文を disk に置かずメモリから開く。ただし
        // RAM 常駐(プールで共有/複製)が重い大きな子は現行の平文 temp へフォール
        // バック(上限 nestedInMemoryLimit)。非機微(非暗号化親)は従来どおり
        // temp 経由で挙動・性能を変えない。子の機微性は子孫へ伝播する。cooViewer-6ax
        let sensitive = contentIsSensitive || archive.isEncrypted()
        let useMemory = sensitive && Int64(data.count) <= Self.nestedInMemoryLimit
        let isPDF = SupportedTypes.isPDF(URL(fileURLWithPath: candidate.path))
        let child: any BookSource
        if isPDF {
            if useMemory {
                guard let pdf = try? PDFSource(data: data) else { return }
                child = pdf
            } else {
                guard let fileURL = writeNestedTemp(candidate, data: data),
                      let pdf = try? PDFSource(url: fileURL) else { return }
                child = pdf
            }
        } else if useMemory {
            guard let nested = try? ArchiveSource(
                data: data, name: candidate.path, nestingDepth: nestingDepth + 1,
                unlocker: unlocker, persistenceKey: childKey, sensitive: true)
            else { return }
            child = nested
        } else {
            guard let fileURL = writeNestedTemp(candidate, data: data),
                  let nested = try? ArchiveSource(
                    url: fileURL, nestingDepth: nestingDepth + 1,
                    unlocker: unlocker, persistenceKey: childKey, sensitive: sensitive)
            else { return }
            child = nested
        }
        // 暗号化された子は共有アンロッカーで解除する(保存済み→既知→入力依頼)。
        // 解除できない/キャンセルされた子は本から外す(§4.17 の黙殺方針。
        // 恒久的な空セルとして残すより一覧が正直になる)
        if await child.isEncrypted() {
            let name = (candidate.path as NSString).lastPathComponent
            guard await unlocker.unlock(child, name: name,
                                        persistenceKey: childKey) else { return }
        }
        guard let childEntries = try? await child.entries(), !childEntries.isEmpty else {
            return
        }
        children.append(child)
        let sourceIndex = children.count - 1
        let idBase = ordinal * Self.nestedIDStride
        for (offset, childEntry) in childEntries.enumerated() {
            // 子のページ数が id 域(1M)を超えたら以降を切り捨てる。
            // 溢れると次のネスト候補の id と衝突し、locations の上書きで
            // 別ページの画像が表示されてしまう(外側の 1M ガードと同じ方針)
            guard offset < Self.nestedIDStride else { break }
            let id = idBase + offset
            locations[id] = .child(sourceIndex: sourceIndex, entry: childEntry)
            result.append(PageEntry(
                id: id,
                name: childEntry.name,
                pathInBook: candidate.path + "/" + childEntry.pathInBook,
                fileURL: nil,
                creationDate: nil,
                modificationDate: nil
            ))
        }
    }

    /// ネスト候補の展開後バイト(zip 爆弾ガード付き、temp には書かない)。
    /// zip 爆弾対策: この経路は開いた瞬間に自動展開されるため、展開後サイズが
    /// 判るエントリは contents(ofEntry:) で全展開する前に上限で弾く。判定は
    /// 64bit の uncompressedSizeOfEntry: を使う(sizeOfEntry: は 32bit で桁溢れ
    /// するため爆弾検出に使えない)。サイズ不明(entryHasSize: が false)の形式は
    /// ストリーミング展開 API が無く事前判定できないので通す — 既知の残存リスク。
    /// サイズ未申告で 0 等が返っても上限以下として通し、正規エントリは弾かない
    private func nestedChildData(_ candidate: (index: Int32, path: String)) -> Data? {
        if archive.entryHasSize(candidate.index) {
            let uncompressedSize = archive.uncompressedSize(ofEntry: candidate.index)
            guard uncompressedSize <= Self.nestedEntrySizeLimit else { return nil }
        }
        return archive.contents(ofEntry: candidate.index)
    }

    /// ネスト子を一時領域へ書き出す(<pid>-<uuid>-nested/)。非機微な子、または
    /// 上限超でメモリ経由を諦めた機微な子に使う。暗号化祖先由来の平文がここに
    /// 残る場合があるため(XADMaster/PDFKit がパスを直読みするため暗号化不可 —
    /// 設計書 §2.4 の残余リスク)、ディレクトリ/ファイル権限を所有者限定にする
    private func writeNestedTemp(_ candidate: (index: Int32, path: String),
                                 data: Data) -> URL? {
        if nestedRoot == nil {
            let directory = Self.spoolRoot().appendingPathComponent(
                "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)-nested")
            guard (try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil else { return nil }
            nestedRoot = directory
        }
        guard let root = nestedRoot else { return nil }
        let fileURL = root.appendingPathComponent(
            "\(candidate.index)-\((candidate.path as NSString).lastPathComponent)")
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
        return fileURL
    }

    func imageData(for entry: PageEntry) async -> Data? {
        switch locations[entry.id] {
        case .child(let sourceIndex, let childEntry):
            return await children[sourceIndex].imageData(for: childEntry)
        case .outer(let index):
            if let spooled = spooledData(for: entry.id) { return spooled }
            // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない
            guard !exceedsPerPageDecodeLimit(index) else { return nil }
            return archive.contents(ofEntry: index)
        case nil:
            // 一覧構築(build)前に呼ばれた場合の逃げ道。最上位書庫の
            // エントリ番号としてそのまま解釈する(ネスト id 域は 1M 以上
            // なので Int32 変換の失敗で自然に弾かれる)
            guard let index = Int32(exactly: entry.id) else { return nil }
            if let spooled = spooledData(for: entry.id) { return spooled }
            // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない
            guard !exceedsPerPageDecodeLimit(index) else { return nil }
            return archive.contents(ofEntry: index)
        }
    }

    nonisolated func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        try Task.checkCancellation()  // 待ち手が消えた要求はここで脱落
        switch try await pageContent(for: entry) {
        case .child(let child, let childEntry):
            return try await child.image(for: childEntry, maxPixelSize: maxPixelSize)
        case .data(let data):
            // nonisolated async はグローバル実行系で走るため、このデコードは
            // actor の外。展開・スプールと画像デコードが並行できる
            return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
        case .pooled(let poolIndex, let extractor, let entryIndex):
            // 展開は貸し出された係の隔離で走る(本 actor と他の係に対して並列)
            let data = await extractor.contents(ofEntry: entryIndex)
            await releaseExtractor(poolIndex)
            guard let data else {
                throw BookSourceError.pageLoadFailed(entry.name)
            }
            return try ImageDecoding.decode(data, maxPixelSize: maxPixelSize)
        }
    }

    /// ページ寸法: スプール済みならヘッダ読み、子は委譲。未スプールの書庫
    /// エントリは全展開が必要なので nil(呼び出し側がデコード判定へ)
    func imageSize(for entry: PageEntry) async -> CGSize? {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return await children[sourceIndex].imageSize(for: childEntry)
        }
        // 暗号化スプールはシール済みバイト列なのでヘッダ直読みできない
        // (nil で従来の取得経路へ)
        guard spooledIDs.contains(entry.id), !spoolEncrypted,
              let directory = spoolDirectory else {
            return nil
        }
        return ImageDecoding.imageSize(
            at: directory.appendingPathComponent(String(entry.id)))
    }

    /// ページの中身の取り出し方(actor 内で決定する)。
    /// pooled はプールの展開係を貸し出し、実際の展開は actor の外
    /// (extractor 自身の隔離)で行う — 展開どうし・スプールと並列になる
    private enum PageContent {
        case data(Data)
        case child(any BookSource, PageEntry)
        case pooled(poolIndex: Int, extractor: ArchiveEntryExtractor, entryIndex: Int32)
    }

    /// 1 ページ分のオンデマンド展開サイズの上限(先読み/サムネイル/オンデマンド
    /// のどの経路でも、この宣言サイズを超えるエントリは展開しない。zip 爆弾対策)。
    /// 2 GiB は現実的な単一ページ画像ファイル(超高解像度の無圧縮 TIFF/BMP や
    /// レイヤー付き PSD でも)を確実に上回る一方、展開爆弾が宣言する数 GB〜の
    /// 塊は依然として弾ける。サイズ不明のエントリ(entryHasSize=false)は
    /// 判定できないため通す(残存リスクとして許容)
    static let perPageDecodeSizeLimit: Int64 = 2 << 30

    /// エントリの宣言展開サイズが上限を超えるか。サイズ不明なら false(=通す)。
    /// 32bit の size(ofEntry:) ではなく 64bit の uncompressedSize(ofEntry:) を使う
    private func exceedsPerPageDecodeLimit(_ index: Int32) -> Bool {
        guard archive.entryHasSize(index) else { return false }
        return archive.uncompressedSize(ofEntry: index) > Self.perPageDecodeSizeLimit
    }

    private func pageContent(for entry: PageEntry) throws -> PageContent {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return .child(children[sourceIndex], childEntry)
        }
        if let spooled = spooledData(for: entry.id) {
            return .data(spooled)
        }
        guard let index = Int32(exactly: entry.id) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        if let (poolIndex, extractor) = acquireExtractor() {
            return .pooled(poolIndex: poolIndex, extractor: extractor,
                           entryIndex: index)
        }
        // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない
        guard !exceedsPerPageDecodeLimit(index) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        guard let extracted = archive.contents(ofEntry: index) else {
            throw BookSourceError.pageLoadFailed(entry.name)
        }
        return .data(extracted)
    }

    /// 展開係の貸し出し(エントリ独立圧縮の形式のみ)。空き優先・
    /// 全員使用中のときだけ成長・成長不能時はいちばん空いている係に相乗り
    private func acquireExtractor() -> (Int, ArchiveEntryExtractor)? {
        guard Self.nonSolidExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        if let idle = extractorBusyCounts.indices.first(
            where: { extractorBusyCounts[$0] == 0 }) {
            extractorBusyCounts[idle] += 1
            return (idle, extractors[idle])
        }
        if !extractorGrowthDisabled, extractors.count < Self.extractorPoolSize {
            // エントリ数の一致を検証してから採用する(開いた後にファイルが
            // 差し替えられた場合、一覧と食い違う内容を展開しないため)。
            // メモリ背景(暗号化親のネスト子)は共有 NSData から再オープンし、
            // 平文を disk に置かずに並列展開を保つ(cooViewer-6ax)
            let expected = archive.numberOfEntries()
            let grown: ArchiveEntryExtractor?
            if let sourceData {
                grown = ArchiveEntryExtractor(data: sourceData, password: password,
                                              expectedEntryCount: expected)
            } else {
                grown = ArchiveEntryExtractor(url: url, password: password,
                                              expectedEntryCount: expected)
            }
            if let extractor = grown {
                extractors.append(extractor)
                extractorBusyCounts.append(1)
                return (extractors.count - 1, extractor)
            }
            extractorGrowthDisabled = true
        }
        guard !extractors.isEmpty else { return nil }
        var index = 0
        for i in extractorBusyCounts.indices
            where extractorBusyCounts[i] < extractorBusyCounts[index] { index = i }
        extractorBusyCounts[index] += 1
        return (index, extractors[index])
    }

    private func releaseExtractor(_ index: Int) {
        if extractorBusyCounts.indices.contains(index) {
            extractorBusyCounts[index] -= 1
        }
    }

    /// テスト用: 生成済みの展開係の数
    var extractorCount: Int { extractors.count }

    /// ルーペ用。ネストした PDF はベクトルから倍率連動で描き直せるよう子へ委譲する
    func loupeImage(for entry: PageEntry, pixelScale: CGFloat) async throws -> CGImage {
        if case .child(let sourceIndex, let childEntry) = locations[entry.id] {
            return try await children[sourceIndex].loupeImage(
                for: childEntry, pixelScale: pixelScale)
        }
        return try await image(for: entry, maxPixelSize: nil)
    }

    func isEncrypted() async -> Bool {
        archive.isEncrypted()
    }

    /// ルートの ComicInfo.xml を読んで解析する(cooViewer-4fi.2)。暗号化書庫では
    /// 解錠後のみ読める(未解錠は contents が nil で自然に nil)。zip 爆弾対策で
    /// 展開後サイズが判るなら小さな上限で弾く(メタデータは通常数 KB)
    func metadata() async -> ComicInfo? {
        guard let index = comicInfoEntryIndex else { return nil }
        if archive.entryHasSize(index),
           archive.uncompressedSize(ofEntry: index) > Self.comicInfoSizeLimit {
            return nil
        }
        guard let data = archive.contents(ofEntry: index) else { return nil }
        return ComicInfo.parse(data)
    }

    /// 最上位書庫が暗号化されている、または組み立て時にネストの暗号化書庫/PDF を
    /// 解除して束ねていれば、復号済み保護コンテンツを含む本(CWE-312)。
    /// ネストの解除は build 後に確定するため buildIfNeeded を待ってから判定する
    func containsProtectedContent() async -> Bool {
        await buildIfNeeded()
        if archive.isEncrypted() { return true }
        return await unlocker.sawUnlockedChild
    }

    func hasSkippedLockedContent() async -> Bool {
        await unlocker.sawSkippedChild
    }

    func attachNestedPasswordProvider(_ provider: NestedPasswordProvider?) async {
        await unlocker.setProvider(provider)
    }

    func notePasswordSaveConsent(_ password: String) async {
        // 最上位ダイアログの保存同意をネスト子へ引き継ぐ(同一パスワードの
        // 子が解錠されたとき、その子のキーへも保存される)
        await unlocker.noteSaveConsent(password)
    }

    func applyMediaProfile(_ profile: MediaProfile) async {
        mediaProfile = profile
    }

    /// パスワードを設定し、先頭エントリの展開を試して検証する(仕様書 §4.1.3)。
    /// 画像がなくネスト書庫だけの本でも検証できるよう候補もプローブに使う。
    func checkAndSetPassword(_ password: String) async -> Bool {
        // プローブは「暗号化されているエントリ」を優先する。旧実装相当の
        // 「先頭エントリで検証」(仕様書 §4.1.3)だと、先頭が非暗号化の混在
        // 書庫で任意のパスワードが「成功」してしまい、保存パスワードの
        // 自動試行では誤値が無音で確定・永続化される(設計書 §2.4 の強化点)
        // zip 爆弾対策: 保存パスワードの自動試行では無人でプローブ展開が走る
        // ため、宣言サイズが上限内のエントリを優先する(全滅時のみ従来どおり)
        let candidates = outerImages.map { Int32($0.id) } + nestedCandidates.map(\.index)
        let safe = candidates.filter { !exceedsPerPageDecodeLimit($0) }
        let pool = safe.isEmpty ? candidates : safe
        let probe = pool.first(where: { archive.entryIsEncrypted($0) }) ?? pool.first
        // 画像も書庫/PDF もない書庫は検証しようがない(=本としては空)。
        // false を返すと正しいパスワードでも「試行超過」になってしまうため通す
        guard let probe else { return true }
        archive.setPassword(password)
        guard archive.contents(ofEntry: probe) != nil else { return false }
        self.password = password
        // ネストした子の解除でも再利用できるよう記録する
        await unlocker.addKnown(password)
        return true
    }

    // MARK: - スプール

    /// 全ページのローカル展開を開始する(パスワード解除後に呼ぶこと)。
    /// 書庫順=エントリ順の逐次展開なので、ネットワーク越しでも solid 書庫でも
    /// 最速のアクセスパターンになる。展開中のページ要求は従来経路で応える。
    /// ネスト分は展開時点でローカルファイルになっているため対象外。
    func beginBackgroundPreparation(spoolSizeLimit: Int64) async {
        await buildIfNeeded()  // ネスト展開もこの時点で済ませる
        beginSpooling(sizeLimit: spoolSizeLimit)
    }

    func beginSpooling(sizeLimit: Int64) {
        // 高速ローカルボリュームではランダムアクセスが安い形式(zip 系)の
        // スプールを省き、二重書き込みを避ける(設計書 キャッシュ節)
        guard mediaProfile.shouldSpoolArchive(fileExtension: url.pathExtension) else {
            return
        }
        guard spoolTask == nil, !outerImages.isEmpty else { return }
        // 暗号化書庫の復号済みページを平文で temp に残さない(CWE-312。
        // 保存パスワードの自動解錠で無人でも展開が走るため)。スプールは
        // プロセス生存中しか読まれないので、鍵はメモリのみの使い捨て —
        // プロセス終了で残骸ファイルは復号不能なゴミになる
        spoolEncrypted = password != nil
        var total: Int64 = 0
        for entry in outerImages {
            total += Int64(archive.size(ofEntry: Int32(entry.id)))
        }
        guard total <= sizeLimit else { return }

        let directory = Self.spoolRoot().appendingPathComponent(
            "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)) != nil else { return }
        spoolDirectory = directory

        let ids = outerImages.map(\.id)
        spoolTask = Task { [weak self] in
            for id in ids {
                if Task.isCancelled { return }
                await self?.spoolEntry(id)
                // 表示中のページ要求が割り込めるよう 1 エントリごとに譲る
                await Task.yield()
            }
        }
    }

    /// スプール完了を待つ(テスト・診断用)
    func waitForSpoolCompletion() async {
        await spoolTask?.value
    }

    var spooledEntryCount: Int { spooledIDs.count }
    /// スプール済みバイト量(アクティビティ窓向け。書き込み時に累積)
    private var spooledBytes: Int64 = 0

    /// アクティビティ窓向けのスプール実態スナップショット
    struct SpoolStats: Sendable, Equatable {
        let spooled: Int
        let total: Int
        let bytes: Int64
        let active: Bool
    }
    func spoolStats() -> SpoolStats {
        SpoolStats(spooled: spooledIDs.count, total: outerImages.count,
                   bytes: spooledBytes, active: spoolTask != nil)
    }

    private func spoolEntry(_ id: Int) {
        guard let directory = spoolDirectory, !spooledIDs.contains(id) else { return }
        // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開(スプール)しない
        guard !exceedsPerPageDecodeLimit(Int32(id)) else { return }
        guard var data = archive.contents(ofEntry: Int32(id)) else { return }
        if spoolEncrypted {
            // seal 失敗時は書かない(平文フォールバック禁止)
            guard let sealed = SuperResCacheCrypto.seal(data, using: spoolKey) else {
                return
            }
            data = sealed
        }
        let fileURL = directory.appendingPathComponent(String(id))
        if (try? data.write(to: fileURL, options: .atomic)) != nil {
            spooledIDs.insert(id)
            spooledBytes += Int64(data.count)
        }
    }

    private func spooledData(for id: Int) -> Data? {
        guard spooledIDs.contains(id), let directory = spoolDirectory else { return nil }
        // スプールファイルは書き切り後は不変(アプリ所有)なのでマップ読みが安全。
        // 大きなページのコピーを 1 回分省く
        let raw = try? Data(contentsOf: directory.appendingPathComponent(String(id)),
                            options: .mappedIfSafe)
        guard let raw else { return nil }
        guard spoolEncrypted else { return raw }
        return SuperResCacheCrypto.open(raw, using: spoolKey)
    }
}

/// 書庫エントリの展開係(独立した XADArchive を actor で直列化)。
/// ArchiveSource がプールとして複数持ち、エントリ独立圧縮の形式(zip 系)で
/// エントリ間の並列展開を実現する(PDFPageRenderer と同型)
actor ArchiveEntryExtractor {
    private let archive: XADArchive

    /// expectedEntryCount: メイン書庫のエントリ数。開いた後にファイルが
    /// 差し替えられていた場合に、一覧と食い違う内容を展開しないための検証
    /// (エントリ数が同じ差し替えまでは検出しない割り切り。PDF 側と同じ)
    init?(url: URL, password: String?, expectedEntryCount: Int32) {
        guard let archive = XADArchive(file: url.path) else { return nil }
        if let password {
            archive.setPassword(password)
        }
        guard archive.numberOfEntries() == expectedEntryCount else { return nil }
        self.archive = archive
    }

    /// メモリ背景版(暗号化親のネスト子。共有 NSData から独立ハンドルを開く。
    /// 平文を disk に置かずに並列展開する。cooViewer-6ax)
    init?(data: Data, password: String?, expectedEntryCount: Int32) {
        guard let archive = XADArchive(data: data) else { return nil }
        if let password {
            archive.setPassword(password)
        }
        guard archive.numberOfEntries() == expectedEntryCount else { return nil }
        self.archive = archive
    }

    func contents(ofEntry index: Int32) -> Data? {
        // zip 爆弾対策: 宣言展開サイズが上限超のエントリは展開しない。
        // 独立書庫なので ArchiveSource と同じ判定をここでも行う
        // (サイズ不明なら通す。32bit の size(ofEntry:) は使わない)
        if archive.entryHasSize(index),
           archive.uncompressedSize(ofEntry: index) > ArchiveSource.perPageDecodeSizeLimit {
            return nil
        }
        return archive.contents(ofEntry: index)
    }
}
