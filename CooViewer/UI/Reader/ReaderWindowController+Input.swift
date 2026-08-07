import AppKit

/// 入力イベント → バインディング解決 → アクション実行(仕様書 §5)。
/// 旧 Controller (Input) カテゴリに相当する。
extension ReaderWindowController {
    private var fitModeNumber: Int { readerViewForInput.fitMode.rawValue }
    private var readsFromLeft: Bool { book?.readMode.readsFromLeft ?? false }

    // MARK: - キー(仕様書 §5.3, §5.5)

    /// 処理したら true。未割り当てなら false(ビープへ)。
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard book != nil else { return false }
        guard !event.modifierFlags.contains(.command) else { return false }
        guard let character = event.charactersIgnoringModifiers?.first else { return false }
        let modifiers = LegacyModifier.encode(keyEvent: event)
        guard let binding = bindings.resolveKey(
            character: character, modifiers: modifiers,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft),
            let action = binding.action else { return false }
        perform(action, value: binding.value, leftHalf: nil)
        return true
    }

    // MARK: - マウス/ジェスチャ(仕様書 §5.6, §5.9)

    func handleClick(button: Int, modifiers: Int, leftHalf: Bool) {
        guard let binding = bindings.resolveMouse(
            button: button, modifiers: modifiers,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft),
            let action = binding.action else { return }
        perform(action, value: binding.value, leftHalf: leftHalf)
    }

    func handleGesture(virtualButton: Int, modifiers: Int) {
        handleClick(button: virtualButton, modifiers: modifiers, leftHalf: false)
    }

    func handleDragGesture(directionModifier: Int, baseModifiers: Int) {
        guard let binding = bindings.resolveDrag(
            button: 0, baseModifiers: baseModifiers, directionModifier: directionModifier,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft),
            let action = binding.action else { return }
        perform(action, value: binding.value, leftHalf: nil)
    }

    func shouldDragScroll(modifiers: Int) -> Bool {
        let binding = bindings.resolveMouse(
            button: 0, modifiers: LegacyModifier.drag + modifiers,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft)
        return binding?.action == .dragScroll
    }

    // MARK: - ホイール(仕様書 §4.16)

    func handleScrollWheel(_ event: NSEvent) {
        guard book != nil else { return }
        let mode = settings.canScrollMode
        let view = readerViewForInput

        if view.fitMode == .fitToScreen || mode == 3 {
            // 慣性スクロールでは連続でめくらない。閾値は旧実装同様
            // 行単位デルタ(deltaY)と比較する(仕様書 §4.16)
            guard event.momentumPhase == [] else { return }
            wheelTurnPage(deltaY: event.deltaY)
            return
        }
        let delta = CGPoint(x: -event.scrollingDeltaX, y: -event.scrollingDeltaY)
        switch mode {
        case 0:
            view.scroll(by: delta)
        case 1:
            if !view.scroll(by: delta) {
                _ = delta.y > 0 ? view.pageDown() : view.pageUp()
            }
        case 2:
            if !view.scroll(by: delta) {
                if delta.y > 0 {
                    if !view.pageDown() { perform(.nextPage, value: nil, leftHalf: nil) }
                } else {
                    if !view.pageUp() { performPreviousFromEnd() }
                }
            }
        default:
            break
        }
    }

    private func wheelTurnPage(deltaY: CGFloat) {
        let sensitivity = settings.wheelSensitivity
        guard sensitivity > 0, abs(deltaY) >= sensitivity else { return }
        if deltaY < 0 {
            perform(.nextPage, value: nil, leftHalf: nil)
        } else {
            perform(.previousPage, value: nil, leftHalf: nil)
        }
    }

    // MARK: - アクション実行

    /// leftHalf: 画面の左半分での操作か(positional 系のみ使用。nil=キー等)
    func perform(_ action: ReaderAction, value: Double?, leftHalf: Bool?) {
        // 「left 側=次」は右→左読みのとき。左綴じでは鏡像(仕様書 §5.6)
        let isNextSide = (leftHalf ?? true) == !readsFromLeft

        switch action {
        case .nextPage: nextPage(nil)
        case .previousPage: previousPage(nil)
        case .halfNextPage: halfNextPage(nil)
        case .halfPreviousPage: halfPreviousPage(nil)
        case .goToLastPage: goToLastPage(nil)
        case .goToFirstPage: goToFirstPage(nil)
        case .skip: skipPages(by: Int(value ?? 10))
        case .backSkip: skipPages(by: -Int(value ?? 10))
        case .goToPercent: jumpToPercent(Double(value ?? 0) / 100.0)
        case .goToPage: promptGoToPage()
        case .cycleReadMode: cycleReadMode(nil)
        case .toggleShowNumber: settings.showNumber.toggle()
        case .toggleShowPageBar: settings.showPageBar.toggle()
        case .pageUp: _ = readerViewForInput.pageUp()
        case .pageDown: _ = readerViewForInput.pageDown()
        case .pageUpOrPreviousPage:
            if !readerViewForInput.pageUp() { performPreviousFromEnd() }
        case .pageDownOrNextPage:
            if !readerViewForInput.pageDown() { nextPage(nil) }
        case .scrollToTop: readerViewForInput.scrollToHome()
        case .scrollToEnd: readerViewForInput.scrollToEnd()
        case .scrollUp: readerViewForInput.scroll(by: CGPoint(x: 0, y: -(value ?? 20)))
        case .scrollDown: readerViewForInput.scroll(by: CGPoint(x: 0, y: value ?? 20))
        case .scrollLeft: readerViewForInput.scroll(by: CGPoint(x: value ?? 20, y: 0))
        case .scrollRight: readerViewForInput.scroll(by: CGPoint(x: -(value ?? 20), y: 0))
        case .rotateRight: rotateRight(nil)
        case .rotateLeft: rotateLeft(nil)
        case .cycleViewMode: cycleViewMode()
        case .enlargeViewMode: stepViewMode(enlarge: true)
        case .reduceViewMode: stepViewMode(enlarge: false)
        case .cycleSortMode: cycleSortMode()
        case .shuffle: book?.setSortMode(.shuffle); refreshAfterJump()
        case .closeWindow: window?.performClose(nil)
        case .toggleFullscreen: window?.toggleFullScreen(nil)
        case .minimizeWindow: window?.performMiniaturize(nil)
        case .contextualMenu: showContextMenu()

        case .positionalNextPrevPage:
            isNextSide ? nextPage(nil) : previousPage(nil)
        case .positionalHalfNextPrev:
            isNextSide ? halfNextPage(nil) : halfPreviousPage(nil)
        case .positionalLastTop:
            isNextSide ? goToLastPage(nil) : goToFirstPage(nil)
        case .positionalSkipBack:
            skipPages(by: isNextSide ? Int(value ?? 10) : -Int(value ?? 10))
        case .positionalPageUpDownTurn:
            if isNextSide {
                if !readerViewForInput.pageDown() { nextPage(nil) }
            } else {
                if !readerViewForInput.pageUp() { performPreviousFromEnd() }
            }
        case .positionalRotate:
            isNextSide ? rotateRight(nil) : rotateLeft(nil)

        case .nextBookmark: goToBookmark(next: true)
        case .previousBookmark: goToBookmark(next: false)
        case .positionalNextPrevBookmark: goToBookmark(next: isNextSide)
        case .addRemoveBookmark: toggleBookmark()
        case .switchSingleSpread: switchSingleSpread()
        case .nextBook: openAdjacentBook(forward: true)
        case .previousBook: openAdjacentBook(forward: false)
        case .positionalNextPrevBook: openAdjacentBook(forward: isNextSide)
        case .nextSubFolder: goToSubFolder(next: true)
        case .previousSubFolder: goToSubFolder(next: false)
        case .positionalNextPrevSubFolder: goToSubFolder(next: isNextSide)
        case .toggleSlideshow: toggleSlideshow()
        case .viewOriginalRight: viewOriginal(leftSide: false)
        case .viewOriginalLeft: viewOriginal(leftSide: true)
        case .positionalViewOriginal: viewOriginal(leftSide: leftHalf)
        case .showInFinderRight: showInFinder(leftSide: false)
        case .showInFinderLeft: showInFinder(leftSide: true)
        case .positionalShowInFinder: showInFinder(leftSide: leftHalf)
        case .trashRight: trashDisplayedPage(leftSide: false)
        case .trashLeft: trashDisplayedPage(leftSide: true)
        case .positionalTrash: trashDisplayedPage(leftSide: leftHalf ?? true)
        case .openLastPage: openTheLastBook()

        case .showThumbnail: showThumbnail()
        case .toggleLoupe: toggleLoupe()
        // 倍率 ±value、既定 0.5(仕様書 §4.10 action 37/38)
        case .loupePowerUp: adjustLoupeRate(by: value ?? 0.5)
        case .loupePowerDown: adjustLoupeRate(by: -(value ?? 0.5))

        case .dragScroll:
            break  // 実処理は ReaderView のドラッグ追従
        }
    }

    // MARK: - 個別処理

    private func skipPages(by delta: Int) {
        guard let book else { return }
        book.skip(by: delta)
        refreshAfterJump()
    }

    private func jumpToPercent(_ percent: Double) {
        guard let book else { return }
        if book.goToPercent(percent) == .moved {
            refreshAfterJump()
        } else {
            handleEndOfBook()
        }
    }

    /// Go to Page(旧 pageMover の簡易版。完全版はマイルストーン 7)
    private func promptGoToPage() {
        guard let book else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Go to Page")
        alert.addButton(withTitle: String(localized: "Go"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.placeholderString = "1-\(book.pageCount)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let page = Int(field.stringValue) else { return }
        book.goTo(index: page - 1)
        refreshAfterJump()
    }

    private func cycleViewMode() {
        // 0→1→3→2→0(仕様書 §5.5 action 42)
        let next: ReaderView.FitMode = switch readerViewForInput.fitMode {
        case .fitToScreen: .fitWidth
        case .fitWidth: .fitWidthDivide
        case .fitWidthDivide: .noScale
        case .noScale: .fitToScreen
        }
        readerViewForInput.fitMode = next
    }

    private func stepViewMode(enlarge: Bool) {
        // 仕様書 §5.5 action 51/52
        let next: ReaderView.FitMode?
        switch (readerViewForInput.fitMode, enlarge) {
        case (.fitToScreen, true): next = .fitWidth
        case (.fitWidth, true): next = .fitWidthDivide
        case (.fitWidthDivide, true): next = .noScale
        case (.noScale, true): next = nil
        case (.noScale, false): next = .fitWidthDivide
        case (.fitWidthDivide, false): next = .fitWidth
        case (.fitWidth, false): next = .fitToScreen
        case (.fitToScreen, false): next = nil
        }
        if let next { readerViewForInput.fitMode = next }
    }

    private func cycleSortMode() {
        guard let book else { return }
        // 旧巡回(仕様書 §5.5 action 45)に「名前(単純)」を名前の直後に挿入:
        // 日付可: 0→4→2→3→1→0 / 不可: 0→4→1→0
        let next: SortMode
        if book.source.supportsDateSort {
            switch book.sortMode {
            case .name: next = .literalName
            case .literalName: next = .creationDate
            case .creationDate: next = .modificationDate
            case .modificationDate: next = .shuffle
            case .shuffle: next = .name
            }
        } else {
            switch book.sortMode {
            case .name: next = .literalName
            case .literalName: next = .shuffle
            default: next = .name
            }
        }
        book.setSortMode(next)
        refreshAfterJump()
    }

    private func showContextMenu() {
        guard let view = window?.contentView, let event = NSApp.currentEvent else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Next Page"),
                     action: #selector(nextPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Previous Page"),
                     action: #selector(previousPage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "First Page"),
                     action: #selector(goToFirstPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Last Page"),
                     action: #selector(goToLastPage(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
