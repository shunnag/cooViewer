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
        let megabytes = defaults.integer(forKey: "PageCacheMegabytes")
        if megabytes > 0 { return megabytes * 1024 * 1024 }
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        return min(2 * 1024 * 1024 * 1024, physical * 15 / 100)
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
