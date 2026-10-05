import Foundation

/// EPUB 本文の再構成に影響する設定だけを表す比較値。
/// ウインドウ枠の自動保存通知を設定変更と誤認しないために使う(cooViewer-oxr.83)。
struct EPUBSettingsFingerprint: Equatable {
    let pageTurnAnimation: Int
    let fontScale: Double
    let pinchAdjustsFontScale: Bool
    let showsPageFurniture: Bool
    let pageMargins: Int
    let defaultFontFamily: String
    let theme: Int
    let forcesReadableColors: Bool
    /// cooViewer-oxr.32/33/38: 設計書 §2.4 の新しい EPUB 設定も
    /// UserDefaults 全体通知から確実に抽出する。
    let footnotePopover: Bool
    let hidesFootnoteAsides: Bool
    let lineHeightScale: Double
    let letterSpacing: Int
    let paragraphSpacing: Int
    let forceFont: Bool
    let hidesRuby: Bool
    let showsPrintPage: Bool
    /// 縦ホイールめくりの無効化切替も表示中の EPUB へ反映する(仕様書 §6.1)。
    let wheelTurnsPages: Bool
    let horizontalWheelTurnsPages: Bool
    let flipSwipeDirection: Bool
}
