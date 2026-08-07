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

    /// 見開き判定しきい値×1000(0 は 740 に補正。仕様書 §6.1)
    var singleSetting: Int {
        let value = defaults.integer(forKey: "SingleSetting")
        return value == 0 ? PageLayout.defaultSingleSetting : value
    }

    var interpolation: ReaderView.Interpolation {
        ReaderView.Interpolation(rawValue: defaults.integer(forKey: "Interpolation"))
            ?? .systemDefault
    }

    /// 補間なし ⇔ 直前の補間を切り替える(直前が未保存なら「高」へ)
    func toggleInterpolationNone() {
        let current = defaults.integer(forKey: "Interpolation")
        if current == ReaderView.Interpolation.none.rawValue {
            let stored = defaults.object(forKey: "InterpolationBeforeNone") as? Int
            let restored = (stored == nil || stored == ReaderView.Interpolation.none.rawValue)
                ? ReaderView.Interpolation.high.rawValue : stored!
            defaults.set(restored, forKey: "Interpolation")
        } else {
            defaults.set(current, forKey: "InterpolationBeforeNone")
            defaults.set(ReaderView.Interpolation.none.rawValue, forKey: "Interpolation")
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

    /// ページキャッシュ上限(バイト)。既定は物理メモリの 15%(上限 2GB)。
    /// "PageCacheMegabytes" で明示指定可(0/未設定=自動)。
    /// 旧 ImageCache(枚数)は廃止(設計書「キャッシュ・先読み設計」)。
    var pageCacheByteLimit: Int {
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        if advancedSettingsEnabled {
            // 高度な設定: 指定パーセントをそのまま使う(2GB 上限は適用しない)
            return physical / 100 * advancedMemoryPercent
        }
        let megabytes = defaults.integer(forKey: "PageCacheMegabytes")
        if megabytes > 0 { return megabytes * 1024 * 1024 }
        return min(2 * 1024 * 1024 * 1024,
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

    /// NSArchiver 形式の NSColor を読む。NSUnarchiver は Swift から直接使えないため
    /// ランタイム経由で呼ぶ。失敗したら nil(既定値へフォールバック。設計書 §5)。
    private static func legacyUnarchivedColor(_ data: Data) -> NSColor? {
        guard let unarchiverClass = NSClassFromString("NSUnarchiver") as? NSObject.Type else {
            return nil
        }
        let selector = NSSelectorFromString("unarchiveObjectWithData:")
        guard unarchiverClass.responds(to: selector) else { return nil }
        return unarchiverClass.perform(selector, with: data)?
            .takeUnretainedValue() as? NSColor
    }
}
