import AppKit
import Foundation
import Washi

/// 脚注リンクを本文移動ではなくポップオーバーへ渡す条件。
/// cooViewer-oxr.32 / 設計書 §2.4 の host 側判断を UI から分離する。
enum EPUBFootnotePolicy {
    static func shouldPopover(link: EPUBInternalLink, isEnabled: Bool) -> Bool {
        isEnabled && (link.isNoteReference || link.hasBacklink)
    }
}

/// 脚注アンカーと本文領域からポップオーバーの位置を決める純粋な幾何処理。
/// cooViewer-oxr.32 / 設計書 §2.4。
enum EPUBFootnotePopoverGeometry {
    struct Placement: Equatable {
        let anchorRect: CGRect
        let preferredEdge: NSRectEdge
    }

    static func placement(
        anchorRect: CGRect?,
        lastClickLocation: CGPoint?,
        in viewBounds: CGRect
    ) -> Placement {
        let fallbackPoint = lastClickLocation
            ?? CGPoint(x: viewBounds.midX, y: viewBounds.midY)
        let resolvedRect: CGRect
        if let anchorRect, !anchorRect.isNull, !anchorRect.isEmpty {
            resolvedRect = anchorRect
        } else {
            resolvedRect = CGRect(origin: fallbackPoint, size: CGSize(width: 1, height: 1))
        }
        // 上半分のアンカーなら下側、下半分なら上側を優先して本文を隠しにくくする。
        let edge: NSRectEdge = resolvedRect.midY >= viewBounds.midY ? .minY : .maxY
        return Placement(anchorRect: resolvedRect, preferredEdge: edge)
    }
}

/// EPUB のページ入力を、全体ノンブルと印刷版ページ名のどちらへ渡すか決める。
/// cooViewer-oxr.38 / 設計書 §2.4。
enum EPUBPageJumpResolver {
    enum Resolution: Equatable {
        case global(Int)
        case printPage(String)
        case invalid
    }

    static func resolve(
        input: String,
        printLabels: [String],
        totalPages: Int
    ) -> Resolution {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .invalid }
        if let page = Int(value), totalPages > 0,
           (1...totalPages).contains(page) {
            return .global(page)
        }
        return printLabels.contains(value) ? .printPage(value) : .invalid
    }
}

/// 右クリック割当が解決できた場合だけ WebKit のメニューを抑止する。
/// cooViewer-oxr.35 / 設計書 §2.4。
enum EPUBContextMenuDecision {
    static func shouldSuppressMenu(hasResolvedAction: Bool) -> Bool {
        hasResolvedAction
    }
}

/// 選択本文を検索語へ正規化する。空白だけなら直前の有効選択を壊さないため nil。
/// cooViewer-oxr.34 / 設計書 §2.4。
enum EPUBSelectionSearchTerm {
    static func term(from selection: String?) -> String? {
        guard let selection else { return nil }
        let normalized = selection.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}

/// SettingsStore の値を Washi 設定へ写すための Sendable な入力スナップショット。
/// cooViewer-oxr.32/33/35/38 / 設計書 §2.4。
struct EPUBSettingsValues: Sendable, Equatable {
    let pageTurnStyle: EPUBPageTurnStyle
    let fontScale: Double
    let pinchAdjustsFontScale: Bool
    let showsPageFurniture: Bool
    let insets: EPUBReaderInsets
    let defaultFontFamily: String
    let theme: EPUBReaderTheme
    let forcesReadableColors: Bool
    let horizontalWheelTurnsPages: Bool
    let reversesHorizontalWheelTurn: Bool
    let hidesFootnoteAsides: Bool
    let lineHeightScale: Double
    let letterSpacing: Int
    let paragraphSpacing: Int
    let forceFont: Bool
    let hidesRuby: Bool
    let showsPrintPageInFurniture: Bool
}

/// 設定値の単位変換を UI コントローラから分離した純粋な mapper。
/// cooViewer-oxr.33 / 設計書 §2.4。
enum EPUBSettingsMapper {
    static func readerSettings(from values: EPUBSettingsValues) -> EPUBReaderSettings {
        var settings = EPUBReaderSettings()
        settings.handlesKeyboardNavigation = false
        settings.pageTurnStyle = values.pageTurnStyle
        settings.fontScale = values.fontScale
        settings.pinchAdjustsFontScale = values.pinchAdjustsFontScale
        settings.showsPageFurniture = values.showsPageFurniture
        settings.insets = values.insets

        let font = values.defaultFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.defaultFontFamily = font.isEmpty ? nil : font
        settings.theme = values.theme
        settings.forcesReadableColors = values.forcesReadableColors
        settings.horizontalWheelTurnsPages = values.horizontalWheelTurnsPages
        settings.reversesHorizontalWheelTurn = values.reversesHorizontalWheelTurn

        settings.hidesFootnoteAsides = values.hidesFootnoteAsides
        settings.lineHeightScale = values.lineHeightScale > 0 ? values.lineHeightScale : nil
        settings.letterSpacingEm = switch values.letterSpacing {
        case 1: 0.05
        case 2: 0.1
        default: nil
        }
        settings.paragraphSpacingEm = switch values.paragraphSpacing {
        case 1: 0.5
        case 2: 1.0
        default: nil
        }
        settings.fontFamilyOverride = values.forceFont && !font.isEmpty ? font : nil
        settings.hidesRuby = values.hidesRuby
        settings.contextMenuPolicy = .readingDefault
        settings.showsPrintPageInFurniture = values.showsPrintPageInFurniture
        // announcesPageChanges は Washi の安全な既定値 true を維持する。
        return settings
    }
}
