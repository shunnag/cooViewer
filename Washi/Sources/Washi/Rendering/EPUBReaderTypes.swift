import AppKit
import Foundation

/// 読書位置(spine 項目 + 項目内進行率)。リフローではページ番号が
/// ウインドウ寸法・フォント設定で変わるため、進行率(0..1)で永続化する
public struct EPUBLocator: Sendable, Equatable, Codable {
    public var spineIndex: Int
    /// 項目内の進行率 0.0(先頭)〜1.0(末尾)
    public var progression: Double
    /// spine itemref の idref。あれば配信本の改版(spine の並べ替え・増減)を
    /// またいで正しい項目へ追跡できる(EPUBPublication.resolve)。
    /// 旧形式の保存データ({spineIndex, progression} のみ)とデコード互換
    public var idref: String?

    public init(spineIndex: Int, progression: Double = 0, idref: String? = nil) {
        self.spineIndex = spineIndex
        self.progression = min(1, max(0, progression))
        self.idref = idref
    }
}

/// 余白(NSEdgeInsets は Equatable/Sendable でないため独自型)
public struct EPUBReaderInsets: Sendable, Equatable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0,
                bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = EPUBReaderInsets()
}

/// 配色テーマ。system はビューの実効外観(ライト/ダーク)に追従する
public enum EPUBReaderTheme: Int, Sendable {
    case system = 0
    case light = 1
    case dark = 2
}

/// ページ送り演出の内蔵スタイル
public enum EPUBPageTurnStyle: Sendable, Equatable {
    case none
    /// クロスフェード
    case fade
    /// 旧ページが物理方向(綴じの反対側)へ滑り出す
    case slide
}

/// 見開き(2 ページ)表示の方針。auto はウインドウ幅で自動切替
/// (Apple Books の 1/2 ページ判定と同じ発想)
public enum EPUBColumnMode: Int, Sendable {
    case auto = 0
    case single = 1
    case double = 2
}

/// リーダー表示設定
public struct EPUBReaderSettings: Sendable, Equatable {
    /// 基準フォントサイズ倍率(html font-size % 指定)。
    /// 許容範囲は EPUBReaderView.fontScaleRange(0.5〜3.0)
    public var fontScale: Double = 1.0
    /// ページ間ギャップ px(隣ページの字形はみ出し防止。0 でも動作はする)
    public var pageGap: Double = 24
    /// コンテンツ余白(WKWebView 自体をインセット配置し、multicol の座標系を
    /// 単純に保つ。余白はネイティブ側の背景として描かれ、地(下部)に
    /// 各ページのノンブルが載る — Apple Books の版面設計を模す。
    /// 固定レイアウト(FXL)ページには適用されない(全面表示)
    public var insets = EPUBReaderInsets(top: 56, left: 56, bottom: 52, right: 56)
    /// 見開き表示の方針(既定: ウインドウ幅で自動)
    public var columnMode: EPUBColumnMode = .auto
    /// 配色(既定: システム外観に追従)
    public var theme: EPUBReaderTheme = .system
    /// 柱(書名/章題)とノンブル(ページ番号)を余白に表示するか
    public var showsPageFurniture = true
    /// ページ送りの演出(「視差効果を減らす」有効時と高速連打時は自動省略)。
    /// delegate の animatePageTurn がホスト独自の演出(カール等)で
    /// 置き換えることもできる
    public var pageTurnStyle: EPUBPageTurnStyle = .slide
    /// ピンチでフォント倍率を変更するか(OFF でも adjustFontScale(by:) や
    /// settings.fontScale の直接変更は有効)
    public var pinchAdjustsFontScale = true
    /// 本が font-family を指定しないときに使う既定フォント(CSS ファミリー名。
    /// nil = WebKit 既定)。html レベルへ !important なしで注入するため、
    /// 本文側の指定(電書協テンプレート等)は常にそちらが勝つ
    public var defaultFontFamily: String?
    /// ページ背景の CSS 色(nil = テーマ既定)
    public var backgroundColorCSS: String?
    /// 本文文字色の CSS 色(nil = テーマ既定)
    public var textColorCSS: String?
    /// 追加のユーザー CSS(最後に注入)
    public var userCSS: String?
    /// true なら矢印・スペース等の既定キー操作をビュー内で処理する。
    /// false ならキーは delegate へ転送される(ホストのキーバインド優先)
    public var handlesKeyboardNavigation = true
    /// scripted コンテンツ(本の JavaScript)を許可するか(既定 false)
    public var allowsScriptedContent = false

    public init() {}

    /// テーマの実効配色(ライト = 紙白、ダーク = Apple Books 系の
    /// ほぼ黒 + 明灰文字)。明示指定(backgroundColorCSS 等)が最優先
    func effectiveColors(isDark: Bool) -> (background: String, text: String?) {
        let background = backgroundColorCSS ?? (isDark ? "#1a1a1c" : "#ffffff")
        let text = textColorCSS ?? (isDark ? "#d5d5d0" : nil)
        return (background, text)
    }

    /// フォントサイズ・既定フォントの CSS(ページ割りに影響する部分)
    private func fontCSS() -> String {
        var css = ""
        if fontScale != 1.0 {
            css += "html { font-size: \(Int((fontScale * 100).rounded()))% !important; }\n"
            // body が絶対値(medium・px 等)で font-size を固定する本
            // (ワープロ産に多い)にもルート倍率が波及するよう、body を
            // ルート相対へ正規化する。倍率 1.0(既定)では一切注入しないので
            // 本の設計どおり。!important なしの後置注入のため、より具体的な
            // セレクタの指定は本が勝つ。トレードオフ: body{font-size:62.5%}
            // 等の相対指定も 1rem に潰れる(主要リーダーと同じ割り切り。
            // 倍率を 1.0 に戻せば常に本の設計どおりに復帰する)
            css += "body { font-size: 1rem; }\n"
        }
        if let family = defaultFontFamily, !family.isEmpty {
            // !important なし + html レベル = 継承でしか効かないため、
            // 「本が指定しなかったときだけ」の既定フォントになる。
            // 値は CSS 文字列としてエスケープ(defaults 直書きの任意文字列で
            // 規則が壊れたり CSS が注入されたりしないように)
            let escaped = family
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            css += "html { font-family: \"\(escaped)\", serif; }\n"
        }
        return css
    }

    /// ページ割りに影響する CSS だけを組み立てる(census 用。
    /// 配色はページ数に影響しないため含めない — テーマ切替で census を
    /// 無駄に無効化しないためのキー安定化)
    func layoutAffectingCSS() -> String {
        fontCSS() + (userCSS ?? "")
    }

    /// 注入するユーザー CSS を組み立てる
    func composedUserCSS(isDark: Bool) -> String {
        var css = fontCSS()
        let colors = effectiveColors(isDark: isDark)
        css += ":root { color-scheme: \(isDark ? "dark" : "light"); }\n"
        css += "html { background-color: \(colors.background) !important; }\n"
        if let text = colors.text {
            // body への継承指定のみ(本文が色指定を持つ本はそちらが勝つ)。
            // リンクはダークで読める青へ
            css += "body { color: \(text); }\n"
            if isDark {
                css += "a { color: #7fb2ff; }\n"
            }
        }
        if let extra = userCSS {
            css += extra
        }
        return css
    }
}

/// ホストへ転送するキーイベント(handlesKeyboardNavigation = false のとき)
public struct EPUBKeyEvent: Sendable, Equatable {
    public let key: String
    public let code: String
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool
}

/// ページ面クリックの詳細(delegate 転送用)。
/// button は NSEvent 流の番号(0=左, 1=右, 2=中, 3/4=サイド)。
/// 右クリックは WebKit のコンテキストメニューに委ねるため通知しない
public struct EPUBClickEvent: Sendable, Equatable {
    /// 0..1 の正規化座標
    public let x: Double
    public let y: Double
    public let button: Int
    public let shift: Bool
    public let option: Bool
    public let control: Bool
    public let command: Bool

    /// 修飾キーなしの左クリックか(既定の端タップめくり対象)
    public var isPlainPrimary: Bool {
        button == 0 && !shift && !option && !control && !command
    }
}

/// リーダービューのイベント通知先
@MainActor
public protocol EPUBReaderViewDelegate: AnyObject {
    /// 表示位置が変わった(ページ送り・章移動・復元)
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int)
    /// 本の先頭/末尾を越えようとした(forward=true が末尾側)
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool)
    /// 外部リンクを開こうとしている。true を返すと既定動作(ブラウザで開く)
    func readerView(_ view: EPUBReaderView, shouldOpenExternalURL url: URL) -> Bool
    /// handlesKeyboardNavigation = false のときのキー転送
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent)
    /// ページ面のクリック(リンク以外。左・中・サイドボタン+修飾キー付き)。
    /// true を返すと処理済み、false で既定動作(修飾なし左クリックの
    /// 左右端タップめくりのみ)
    func readerView(_ view: EPUBReaderView, didClick event: EPUBClickEvent) -> Bool
    /// ファイルのドロップ(ホストが「別の本を開く」等に使う)。
    /// false ならドロップは拒否される
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool
    /// ピンチ等でフォント倍率が変わった(ホストの永続化用)
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double)
    /// ページ送り演出をホスト独自の効果(ページカール等)で置き換える。
    /// oldPage/newPage はページ領域(pageRect、view 座標系)のスナップショット。
    /// **このメソッド内で同期的に**オーバーレイを view へ載せて true を返すこと
    /// (戻った直後に Washi が旧ページのカバーを外す)。false なら内蔵の
    /// pageTurnStyle(スライド/フェード)で演出する
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool
    /// 読み込み失敗等
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error)
    /// 全文ページ数の実測(census)が更新された(完了または無効化)。
    /// view.pageCensus / censusTotalPages / currentGlobalPageRange を参照
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView)
}

public extension EPUBReaderViewDelegate {
    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {}
    func readerView(_ view: EPUBReaderView, didReachBookEdge forward: Bool) {}
    func readerView(_ view: EPUBReaderView,
                    shouldOpenExternalURL url: URL) -> Bool { true }
    func readerView(_ view: EPUBReaderView, didReceiveKey event: EPUBKeyEvent) {}
    func readerView(_ view: EPUBReaderView,
                    didClick event: EPUBClickEvent) -> Bool { false }
    func readerView(_ view: EPUBReaderView,
                    didReceiveDroppedFileURL url: URL) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didChangeFontScale scale: Double) {}
    func readerView(_ view: EPUBReaderView,
                    animatePageTurnFrom oldPage: NSImage, to newPage: NSImage,
                    forward: Bool, in pageRect: CGRect) -> Bool { false }
    func readerView(_ view: EPUBReaderView, didFailWith error: any Error) {}
    func readerViewDidUpdatePageCensus(_ view: EPUBReaderView) {}
}
