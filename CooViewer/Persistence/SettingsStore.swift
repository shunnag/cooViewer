import AppKit

/// 型付き設定アクセス。キー名は旧実装(仕様書 §6.1)と同一で、
/// ドメイン jp.coo.cooViewer を引き継ぐため既存ユーザーの値がそのまま生きる。
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 揮発性既定値(旧 registerDefaults 相当。仕様書 §6.1)
    func registerDefaults() {
        defaults.register(defaults: [
            "ShowPageBar": true,
            "ShowNumber": true,
            "WheelSensitivity": 1.0,
            "CanScrollMode": 0,
            "PrevPageMode": 0,
            "OpenRecentLimit": 10,
            "OpenLastFolder": true,
            "SingleSetting": 740,
            "SwipeToTurnPage": true,
            "FlipSwipeDirection": true,
            "PlayAnimatedImages": true,
        ])
    }

    var readMode: ReadMode {
        get { ReadMode(rawValue: defaults.integer(forKey: "ReadMode")) ?? .rightToLeftSpread }
        set { defaults.set(newValue.rawValue, forKey: "ReadMode") }
    }

    var sortMode: SortMode {
        get { SortMode(rawValue: defaults.integer(forKey: "SortMode")) ?? .name }
        set { defaults.set(newValue.rawValue, forKey: "SortMode") }
    }

    /// 端超え動作(仕様書 §4.3.4): 0=ループ/1=次の本の先頭/2=前は末尾から/3=何もしない
    var loopCheck: Int { defaults.integer(forKey: "LoopCheck") }

    /// 最終ページ復元(仕様書 §7.3): 0=確認/1=自動/2=無効
    var goToLastPageMode: Int { defaults.integer(forKey: "GoToLastPage") }

    var readSubFolder: Bool { defaults.bool(forKey: "ReadSubFolder") }
    var rememberBookSettings: Bool { defaults.bool(forKey: "RememberBookSettings") }
    var openLastFolder: Bool { defaults.bool(forKey: "OpenLastFolder") }
    var openRecentLimit: Int { defaults.integer(forKey: "OpenRecentLimit") }

    /// 表示モード(仕様書 §3.2 fitScreenMode)。旧実装は永続化せず毎回 0 で
    /// 起動したが、新実装ではグローバル設定として保存する(仕様変更)。
    /// キー "FitMode" は新実装のみのキー(旧実装に同名キーは存在しない)
    var fitMode: ReaderView.FitMode {
        get { ReaderView.FitMode(rawValue: defaults.integer(forKey: "FitMode")) ?? .fitToScreen }
        set { defaults.set(newValue.rawValue, forKey: "FitMode") }
    }

    /// 見開きモードで先頭ページ(表紙)を単ページにする(新機能・既定オフ)
    var spreadCoverSingle: Bool {
        get { defaults.bool(forKey: "SpreadCoverSingle") }
        set { defaults.set(newValue, forKey: "SpreadCoverSingle") }
    }

    /// ページめくり効果(新設キー・既定なし)。0=なし/1=フェード/2=スライド/
    /// 3=ズームフェード/4=フリップ
    var pageTurnAnimation: PageTurnAnimation {
        get {
            PageTurnAnimation(rawValue: defaults.integer(forKey: "PageTurnAnimation"))
                ?? .none
        }
        set { defaults.set(newValue.rawValue, forKey: "PageTurnAnimation") }
    }

    /// 見開き判定しきい値×1000(0 は 740 に補正。仕様書 §6.1)
    var singleSetting: Int {
        let value = defaults.integer(forKey: "SingleSetting")
        return value == 0 ? PageLayout.defaultSingleSetting : value
    }

    var interpolation: ReaderView.Interpolation {
        ReaderView.Interpolation(rawValue: defaults.integer(forKey: "Interpolation"))
            ?? .systemDefault
    }

    /// ML 高画質化の処理段階(新設キー・既定なし。全ページ対象)。
    /// UI は renderQuality 経由で 0/3/4 のみ書くが、2.0b16 以前の
    /// 弱 1・中 2(CINoiseReduction)も従来どおり読める
    var noiseReductionLevel: NoiseReductionLevel {
        get {
            NoiseReductionLevel(rawValue: defaults.integer(forKey: "NoiseReductionLevel"))
                ?? .none
        }
        set { defaults.set(newValue.rawValue, forKey: "NoiseReductionLevel") }
    }

    /// ML 高画質化の適用範囲(新設キー・既定はメイン表示のみ)
    var noiseReductionScope: NoiseReductionScope {
        get {
            NoiseReductionScope(rawValue: defaults.integer(forKey: "NoiseReductionScope"))
                ?? .displayOnly
        }
        set { defaults.set(newValue.rawValue, forKey: "NoiseReductionScope") }
    }

    /// 描画品質(UI の「補間」5 段階)。実体は旧互換キー Interpolation
    /// (0-3 のまま。1.x と共有する設定に未知値を書かないため)と
    /// NoiseReductionLevel(ML 段階)の組合せへ分解して保存する。
    /// 読み出しは ML 段階を優先し、旧設定の Interpolation=2(低)は
    /// 標準として扱う(選択肢からは廃止)
    var renderQuality: RenderQuality {
        get {
            switch noiseReductionLevel {
            case .maximum: return .mlSuperRes
            case .strong: return .mlDenoise
            case .none, .light, .medium: break  // 弱・中(旧設定)は基礎補間で表示
            }
            switch interpolation {
            case .none: return .none
            case .high: return .high
            case .systemDefault, .low: return .standard
            }
        }
        set {
            defaults.set(newValue.interpolationRawValue, forKey: "Interpolation")
            defaults.set(newValue.noiseReductionRawValue, forKey: "NoiseReductionLevel")
        }
    }

    /// 補間なし ⇔ 直前の品質を切り替える(直前が未保存なら「高」へ)。
    /// 旧実装の f キー相当。ML 段階も含めた描画品質単位でトグルする
    func toggleInterpolationNone() {
        if renderQuality == RenderQuality.none {
            let stored = defaults.object(forKey: "InterpolationBeforeNone") as? Int
            let restored = stored.flatMap { RenderQuality(rawValue: $0) }
            renderQuality = (restored == nil || restored == RenderQuality.none)
                ? .high : restored!
        } else {
            defaults.set(renderQuality.rawValue, forKey: "InterpolationBeforeNone")
            renderQuality = .none
        }
    }

    /// ホイール動作(仕様書 §4.16)
    var canScrollMode: Int { defaults.integer(forKey: "CanScrollMode") }

    /// ホイールめくり閾値。0=無効(仕様書 §6.1)
    var wheelSensitivity: Double { defaults.double(forKey: "WheelSensitivity") }

    /// 前ページ復帰時の初期位置: 0=ページ先頭/1=ページ末尾
    var prevPageMode: Int { defaults.integer(forKey: "PrevPageMode") }

    var slideshowDelay: Double { defaults.double(forKey: "SlideshowDelay") }

    /// 2 本指スワイプ(システムの「ページ間をスワイプ」相当)でページを前後する
    var swipeToTurnPage: Bool { defaults.bool(forKey: "SwipeToTurnPage") }

    /// スワイプページめくりの向きを反転する(既定オン。オフで導入時の向き)
    var flipSwipeDirection: Bool { defaults.bool(forKey: "FlipSwipeDirection") }

    /// アニメーション画像(GIF/WebP 等)を再生する(既定オン)
    var playAnimatedImages: Bool { defaults.bool(forKey: "PlayAnimatedImages") }

    /// ルーペの一辺 pt(仕様書 §4.10 LoupeSize。0/未設定は 150 に補正)
    var loupeSize: Double {
        let value = defaults.double(forKey: "LoupeSize")
        return value <= 0 ? 150 : value
    }

    /// ルーペ倍率(仕様書 §4.10 LoupeRate)。新実装の意味論は「表示中コンテンツの
    /// 何倍か」で、旧既定 1.0(ピクセル等倍相当)は新意味論では等倍=無意味になるため、
    /// 未設定(0)時の既定を 2.0 に変更する(仕様変更)。
    var loupeRate: Double {
        get {
            let value = defaults.double(forKey: "LoupeRate")
            return value <= 0 ? 2.0 : value
        }
        set { defaults.set(newValue, forKey: "LoupeRate") }
    }

    var showPageBar: Bool {
        get { defaults.bool(forKey: "ShowPageBar") }
        set { defaults.set(newValue, forKey: "ShowPageBar") }
    }

    var showNumber: Bool {
        get { defaults.bool(forKey: "ShowNumber") }
        set { defaults.set(newValue, forKey: "ShowNumber") }
    }

    /// ページキャッシュ上限(バイト)。既定は物理メモリの 15%(上限 16GB)。
    /// 高度な設定 ON のときのみ、"PageCacheMegabytes"(隠しキー・MB 直指定)
    /// > メモリ%指定 の順で上書きできる。OFF では他の高度設定と同様、
    /// 明示指定は無視して常に標準の動きへ戻る。
    /// 旧 ImageCache(枚数)は廃止(設計書「キャッシュ・先読み設計」)。
    var pageCacheByteLimit: Int {
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        if advancedSettingsEnabled {
            let megabytes = defaults.integer(forKey: "PageCacheMegabytes")
            if megabytes > 0 { return megabytes * 1024 * 1024 }
            // 指定パーセントをそのまま使う(16GB 上限は適用しない)
            return physical / 100 * advancedMemoryPercent
        }
        // 標準時の上限。15% がこれに達するのは 107GB 超の構成のみで、
        // 実質はメモリ圧迫トリムに任せる安全弁
        return min(16 * 1024 * 1024 * 1024,
                   physical / 100 * AdvancedDefault.memoryPercent)
    }

    // MARK: - 高度な設定(新設。設定タブ「高度」)

    /// 高度な設定の既定値。マスタースイッチ OFF のとき・リセット時はこの値
    enum AdvancedDefault {
        static let memoryPercent = 15
        static let prefetchAhead = 12
        static let prefetchBehind = 3
        static let displayPixelCap = 4096
        static let spoolLimitGB = 4
        static let prepareNextBookPages = 6
        static let thumbnailCacheDays = 30
    }

    /// マスタースイッチ。OFF の間は下記アクセサすべてが既定値を返す
    var advancedSettingsEnabled: Bool {
        defaults.bool(forKey: "AdvancedSettingsEnabled")
    }

    /// ページキャッシュに使う物理メモリの割合(%)
    var advancedMemoryPercent: Int {
        advancedInt("AdvancedMemoryPercent",
                    default: AdvancedDefault.memoryPercent, in: 5...50)
    }

    /// 進行方向の先読みページ数
    var prefetchAheadCount: Int {
        advancedInt("AdvancedPrefetchAhead",
                    default: AdvancedDefault.prefetchAhead, in: 2...64)
    }

    /// 逆方向の先読みページ数(0 で無効)
    var prefetchBehindCount: Int {
        advancedInt("AdvancedPrefetchBehind",
                    default: AdvancedDefault.prefetchBehind, in: 0...16)
    }

    /// 表示用デコードの長辺上限(px)。原寸表示・ルーペには影響しない
    var displayPixelCap: Int {
        advancedInt("AdvancedDisplayPixelCap",
                    default: AdvancedDefault.displayPixelCap, in: 2048...8192)
    }

    /// 書庫のローカル一時展開(スプール)の合計サイズ上限
    var archiveSpoolSizeLimit: Int64 {
        Int64(advancedInt("AdvancedSpoolLimitGB",
                          default: AdvancedDefault.spoolLimitGB, in: 1...64)) << 30
    }

    /// 巻末の残りページ数がこの値以内になったら次の本を事前準備(0 で無効)
    var prepareNextBookPages: Int {
        advancedInt("AdvancedPrepareNextBookPages",
                    default: AdvancedDefault.prepareNextBookPages, in: 0...20)
    }

    /// サムネイルのディスクキャッシュ保持日数
    var thumbnailCacheDays: Int {
        advancedInt("AdvancedThumbnailCacheDays",
                    default: AdvancedDefault.thumbnailCacheDays, in: 1...365)
    }

    /// 本の置き場所の速度(内蔵 SSD/USB-HDD/ネットワーク)に応じて
    /// 読み込み・キャッシュ構築を自動調整する(既定 ON。設計書 キャッシュ節)。
    /// OFF では従来の固定動作(unknown プロファイル)になる。
    /// 高度設定で明示した値(先読み枚数・スプール方針)は常に自動より優先
    var adaptiveMediaTuning: Bool {
        get {
            defaults.object(forKey: "AdaptiveMediaTuning") == nil
                ? true : defaults.bool(forKey: "AdaptiveMediaTuning")
        }
        set { defaults.set(newValue, forKey: "AdaptiveMediaTuning") }
    }

    /// 書庫スプールの方針(高度設定の三択)。
    /// automatic=メディア速度で判断 / always=常に展開 / never=展開しない。
    /// マスタースイッチ OFF の間は automatic
    enum SpoolPolicy: Int {
        case automatic = 0
        case always = 1
        case never = 2
    }

    var archiveSpoolPolicy: SpoolPolicy {
        SpoolPolicy(rawValue: advancedInt(
            "AdvancedSpoolPolicy", default: 0, in: 0...2)) ?? .automatic
    }

    /// マスタースイッチ ON かつ保存済みのときだけ保存値(範囲内に丸める)を返す
    private func advancedInt(_ key: String, default defaultValue: Int,
                             in range: ClosedRange<Int>) -> Int {
        guard advancedSettingsEnabled, defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: key)))
    }

    /// 背景色。新形式(sRGB 成分)を優先し、旧 NSArchiver データは一度だけ読み替える
    /// (仕様書 §13.5)。読めなければ黒。
    var viewBackgroundColor: NSColor {
        get {
            if let components = defaults.array(forKey: "ViewBackgroundColorSRGB") as? [Double],
               components.count == 3 {
                return NSColor(srgbRed: components[0], green: components[1],
                               blue: components[2], alpha: 1)
            }
            if let data = defaults.data(forKey: "ViewBackGroundColor"),
               let legacy = Self.legacyUnarchivedColor(data) {
                // 旧実装同様 alpha は 1 に強制(仕様書 §6.1)
                return legacy.withAlphaComponent(1)
            }
            return .black
        }
        set {
            let srgb = newValue.usingColorSpace(.sRGB) ?? .black
            defaults.set([srgb.redComponent, srgb.greenComponent, srgb.blueComponent],
                         forKey: "ViewBackgroundColorSRGB")
        }
    }

    /// NSArchiver 形式のオブジェクト(NSColor/NSFont)を読む。NSUnarchiver は
    /// Swift から直接使えないためランタイム経由で呼ぶ。失敗したら nil
    /// (既定値へフォールバック。設計書 §6 リスク表)。
    private static func legacyUnarchivedObject(_ data: Data) -> AnyObject? {
        guard let unarchiverClass = NSClassFromString("NSUnarchiver") as? NSObject.Type else {
            return nil
        }
        let selector = NSSelectorFromString("unarchiveObjectWithData:")
        guard unarchiverClass.responds(to: selector) else { return nil }
        return unarchiverClass.perform(selector, with: data)?.takeUnretainedValue()
    }

    private static func legacyUnarchivedColor(_ data: Data) -> NSColor? {
        legacyUnarchivedObject(data) as? NSColor
    }

    /// ページ名の表示: false=ファイル名のみ / true=本の中の相対パス(新設キー)
    var showRelativePaths: Bool {
        get { defaults.bool(forKey: "ShowRelativePaths") }
        set { defaults.set(newValue, forKey: "ShowRelativePaths") }
    }

    // MARK: - ページ番号/ページバーのカスタマイズ(仕様書 §3.4, §6.1)

    /// 位置: 0=左上/1=右上/2=左下/3=右下(旧キーをそのまま読み書き)
    var pageNumPosition: Int {
        get { min(3, max(0, defaults.integer(forKey: "PageNumPosition"))) }
        set { defaults.set(newValue, forKey: "PageNumPosition") }
    }

    var pageBarPosition: Int {
        get { min(3, max(0, defaults.integer(forKey: "PageBarPosition"))) }
        set { defaults.set(newValue, forKey: "PageBarPosition") }
    }

    /// 2 秒自動隠し(マウス移動で再表示。仕様書 §3.4)
    var pageNumAutoHide: Bool {
        get { defaults.bool(forKey: "PageNumAutoHide") }
        set { defaults.set(newValue, forKey: "PageNumAutoHide") }
    }

    var pageBarAutoHide: Bool {
        get { defaults.bool(forKey: "PageBarAutoHide") }
        set { defaults.set(newValue, forKey: "PageBarAutoHide") }
    }

    /// バブルのサムネイル表示。旧既定は OFF だったが新実装では ON を既定にする
    /// (明示保存された旧値は尊重。設計書 §2.4)
    var pageBarShowThumbnail: Bool {
        get {
            guard defaults.object(forKey: "PageBarShowThumbnail") != nil else { return true }
            return defaults.integer(forKey: "PageBarShowThumbnail") != 0
        }
        set { defaults.set(newValue ? 1 : 0, forKey: "PageBarShowThumbnail") }
    }

    /// ページバー寸法(旧 {width,height} 辞書。0 値は旧実装同様補正 §6.2)
    var pageBarSize: CGSize {
        get {
            let dict = defaults.dictionary(forKey: "PageBarSize")
            let width = (dict?["width"] as? Double) ?? 0
            let height = (dict?["height"] as? Double) ?? 0
            return CGSize(width: width > 0 ? min(1000, max(50, width)) : 200,
                          height: height > 0 ? min(40, max(6, height)) : 15)
        }
        set {
            defaults.set(["width": Double(newValue.width),
                          "height": Double(newValue.height)], forKey: "PageBarSize")
        }
    }

    /// ページ番号フォント。新キー(ファミリー+サイズ)優先、旧 TextFont
    /// (NSArchiver)を読み替え、無ければ等幅数字のシステムフォント 11pt
    var pageNumFont: NSFont {
        let size = pageNumFontSize
        let family = defaults.string(forKey: "PageNumFontFamily") ?? ""
        if !family.isEmpty, let font = NSFont(name: family, size: size) {
            return font
        }
        if defaults.object(forKey: "PageNumFontSize") == nil,
           let data = defaults.data(forKey: "TextFont"),
           let legacy = Self.legacyUnarchivedObject(data) as? NSFont {
            return legacy
        }
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    var pageNumFontSize: Double {
        let stored = defaults.double(forKey: "PageNumFontSize")
        return stored > 0 ? min(32, max(8, stored)) : 11
    }

    var pageNumTextColor: NSColor {
        get { color(newKey: "TextColorSRGBA", legacyKey: "TextColor", default: .white) }
        set { setColor(newValue, newKey: "TextColorSRGBA") }
    }

    var pageNumBackgroundColor: NSColor {
        get {
            color(newKey: "TextBGColorSRGBA", legacyKey: "TextBGColor",
                  default: .black.withAlphaComponent(0.8))
        }
        set { setColor(newValue, newKey: "TextBGColorSRGBA") }
    }

    var pageNumBorderColor: NSColor {
        get {
            color(newKey: "TextBorderColorSRGBA", legacyKey: "TextBorderColor",
                  default: .white)
        }
        set { setColor(newValue, newKey: "TextBorderColorSRGBA") }
    }

    var pageBarBackgroundColor: NSColor {
        get {
            color(newKey: "PageBarBGColorSRGBA", legacyKey: "PageBarBGColor",
                  default: .black.withAlphaComponent(0.8))
        }
        set { setColor(newValue, newKey: "PageBarBGColorSRGBA") }
    }

    var pageBarBorderColor: NSColor {
        get {
            color(newKey: "PageBarBorderColorSRGBA", legacyKey: "PageBarBorderColor",
                  default: .white)
        }
        set { setColor(newValue, newKey: "PageBarBorderColorSRGBA") }
    }

    var pageBarReadColor: NSColor {
        get {
            color(newKey: "PageBarReadedColorSRGBA", legacyKey: "PageBarReadedColor",
                  default: .white.withAlphaComponent(0.5))
        }
        set { setColor(newValue, newKey: "PageBarReadedColorSRGBA") }
    }

    /// 色設定の共通経路: 新キー(sRGB 4 成分)→ 旧 NSArchiver データ → 既定値
    private func color(newKey: String, legacyKey: String,
                       default defaultColor: NSColor) -> NSColor {
        if let components = defaults.array(forKey: newKey) as? [Double],
           components.count == 4 {
            return NSColor(srgbRed: components[0], green: components[1],
                           blue: components[2], alpha: components[3])
        }
        if let data = defaults.data(forKey: legacyKey),
           let legacy = Self.legacyUnarchivedColor(data) {
            return legacy
        }
        return defaultColor
    }

    private func setColor(_ color: NSColor, newKey: String) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        defaults.set([srgb.redComponent, srgb.greenComponent, srgb.blueComponent,
                      srgb.alphaComponent], forKey: newKey)
    }
}
