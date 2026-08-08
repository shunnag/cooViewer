/// 割り当て可能なアクション(仕様書 §5.5 キー 0-52 / §5.6 マウス 0-64)。
/// 旧実装の整数は「移行用の対応表」としてのみ使い、内部では型で扱う。
/// Apple Remote 専用の経路は近代化で削除(設計書 §2.2)。
/// EN: Typed action catalog; the legacy integers exist only for migration.
enum ReaderAction: Equatable, Sendable {
    case nextPage, previousPage, halfNextPage, halfPreviousPage
    case goToLastPage, goToFirstPage
    case nextBookmark, previousBookmark
    case nextBook, previousBook
    case addRemoveBookmark
    case switchSingleSpread
    case toggleShowNumber, toggleShowPageBar
    case skip, backSkip                    // value=枚数(既定 10)
    case viewOriginalRight, viewOriginalLeft
    case toggleSlideshow
    case showThumbnail
    case cycleReadMode
    case goToPage                          // pageMover(仕様書 §5.8)
    case showInFinderRight, showInFinderLeft
    case pageUp, pageDown
    case pageUpOrPreviousPage, pageDownOrNextPage
    case scrollToTop, scrollToEnd
    case scrollUp, scrollDown, scrollLeft, scrollRight  // value=px(既定 20)
    case toggleLoupe
    case nextSubFolder, previousSubFolder
    case loupePowerUp, loupePowerDown
    case goToPercent                       // value=%(0-90)
    case rotateRight, rotateLeft
    case cycleViewMode
    case trashRight, trashLeft
    case cycleSortMode, shuffle
    case closeWindow
    case openLastPage
    case toggleFullscreen, minimizeWindow
    case enlargeViewMode, reduceViewMode
    case dragScroll
    case contextualMenu
    /// 補間なし ⇔ 直前の補間の切り替え(新実装で追加。旧番号 53 は未使用域)
    case toggleInterpolation

    // 画面の左右どちらで操作したかで分岐する系(仕様書 §5.6 の **)
    case positionalNextPrevPage, positionalHalfNextPrev, positionalLastTop
    case positionalNextPrevBookmark, positionalNextPrevBook, positionalSkipBack
    case positionalViewOriginal, positionalShowInFinder, positionalPageUpDownTurn
    case positionalTrash, positionalRotate, positionalNextPrevSubFolder
}

extension ReaderAction {
    /// 旧 KeyArray の action 番号 → アクション(仕様書 §5.5)
    /// EN: Legacy KeyArray action number -> typed action.
    static func fromLegacyKeyNumber(_ number: Int) -> ReaderAction? {
        switch number {
        case 0: .nextPage
        case 1: .previousPage
        case 2: .halfNextPage
        case 3: .halfPreviousPage
        case 4: .goToLastPage
        case 5: .goToFirstPage
        case 6: .nextBookmark
        case 7: .previousBookmark
        case 8: .nextBook
        case 9: .previousBook
        case 10: .addRemoveBookmark
        case 11: .switchSingleSpread
        case 12: .toggleShowNumber
        case 13: .skip
        case 14: .backSkip
        case 15: .viewOriginalRight
        case 16: .viewOriginalLeft
        case 17: .toggleSlideshow
        case 18: .showThumbnail
        case 19: .cycleReadMode
        case 20: .toggleShowPageBar
        case 21: .goToPage
        case 22: .showInFinderRight
        case 23: .showInFinderLeft
        case 24: .pageUp
        case 25: .pageDown
        case 26: .pageUpOrPreviousPage
        case 27: .pageDownOrNextPage
        case 28: .scrollToTop
        case 29: .scrollToEnd
        case 30: .scrollUp
        case 31: .scrollDown
        case 32: .scrollLeft
        case 33: .scrollRight
        case 34: .toggleLoupe
        case 35: .nextSubFolder
        case 36: .previousSubFolder
        case 37: .loupePowerUp
        case 38: .loupePowerDown
        case 39: .goToPercent
        case 40: .rotateRight
        case 41: .rotateLeft
        case 42: .cycleViewMode
        case 43: .trashRight
        case 44: .trashLeft
        case 45: .cycleSortMode
        case 46: .closeWindow
        case 47: .shuffle
        case 48: .openLastPage
        case 49: .toggleFullscreen
        case 50: .minimizeWindow
        case 51: .enlargeViewMode
        case 52: .reduceViewMode
        case 53: .toggleInterpolation
        default: nil
        }
    }

    /// 旧 MouseArray の action 番号 → アクション(仕様書 §5.6)。
    /// - 5 のフォールスルーバグは再現しない(§13.3 で「修正」判断)。
    /// - 28/29 は UI ラベルが実挙動と左右逆だったため、**実挙動**を正として読み替える(§13.3)。
    /// EN: Legacy MouseArray number -> action; 28/29 follow the legacy app's
    /// EN: actual behavior, not its mislabeled UI.
    static func fromLegacyMouseNumber(_ number: Int) -> ReaderAction? {
        switch number {
        case 0: .positionalNextPrevPage
        case 1: .positionalHalfNextPrev
        case 2: .positionalLastTop
        case 3: .positionalNextPrevBookmark
        case 4: .positionalNextPrevBook
        case 5: .positionalSkipBack
        case 6: .nextPage
        case 7: .previousPage
        case 8: .halfNextPage
        case 9: .halfPreviousPage
        case 10: .goToLastPage
        case 11: .goToFirstPage
        case 12: .nextBookmark
        case 13: .previousBookmark
        case 14: .nextBook
        case 15: .previousBook
        case 16: .addRemoveBookmark
        case 17: .switchSingleSpread
        case 18: .toggleShowNumber
        case 19: .skip
        case 20: .backSkip
        case 21: .viewOriginalRight
        case 22: .viewOriginalLeft
        case 23: .toggleSlideshow
        case 24: .showThumbnail
        case 25: .cycleReadMode
        case 26: .toggleShowPageBar
        case 27: .positionalViewOriginal
        case 28: .showInFinderRight   // 旧ラベル "left"、実挙動 R(§5.6 #28)
        case 29: .showInFinderLeft    // 旧ラベル "right"、実挙動 L(§5.6 #29)
        case 30: .positionalShowInFinder
        case 31: .pageUp
        case 32: .pageDown
        case 33: .pageUpOrPreviousPage
        case 34: .pageDownOrNextPage
        case 35: .scrollToTop
        case 36: .scrollToEnd
        case 37: .scrollUp
        case 38: .scrollDown
        case 39: .scrollLeft
        case 40: .scrollRight
        case 41: .dragScroll
        case 42: .positionalPageUpDownTurn
        case 43: .toggleLoupe
        case 44: .nextSubFolder
        case 45: .previousSubFolder
        case 46: .positionalNextPrevSubFolder
        case 47: .loupePowerUp
        case 48: .loupePowerDown
        case 49: .rotateRight
        case 50: .rotateLeft
        case 51: .cycleViewMode
        case 52: .trashRight
        case 53: .trashLeft
        case 54: .positionalTrash
        case 55: .positionalRotate
        case 56: .cycleSortMode
        case 57: .closeWindow
        case 58: .shuffle
        case 59: .contextualMenu
        case 60: .openLastPage
        case 61: .toggleFullscreen
        case 62: .minimizeWindow
        case 63: .enlargeViewMode
        case 64: .reduceViewMode
        default: nil
        }
    }

    /// switchAction の入替ペア(仕様書 §5.4)。左綴じ時に対称アクションへ入替える。
    /// EN: Mirror-swap pairs applied when reading left-to-right.
    static func switchedLegacyKeyNumber(_ number: Int) -> Int {
        switch number {
        case 0: 1
        case 1: 0
        case 2: 3
        case 3: 2
        case 4: 5
        case 5: 4
        case 6: 7
        case 7: 6
        case 8: 9
        case 9: 8
        case 13: 14
        case 14: 13
        case 26: 27
        case 27: 26
        case 35: 36
        case 36: 35
        default: number
        }
    }

    static func switchedLegacyMouseNumber(_ number: Int) -> Int {
        switch number {
        case 6: 7
        case 7: 6
        case 8: 9
        case 9: 8
        case 10: 11
        case 11: 10
        case 12: 13
        case 13: 12
        case 14: 15
        case 15: 14
        case 19: 20
        case 20: 19
        case 33: 34
        case 34: 33
        case 44: 45
        case 45: 44
        default: number
        }
    }
}
