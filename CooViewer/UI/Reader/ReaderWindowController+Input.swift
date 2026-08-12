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
        if isThumbnailOverlayVisible, character == "\u{1B}" {
            hideThumbnailOverlay()  // Esc で閉じる
            return true
        }
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
        // 水平スワイプのページ送りはトグルで無効化できる。システム設定が
        // 「3 本指でスワイプ」の場合はスクロールではなく swipe イベントとして
        // この経路に届くため、2 本指(handleSwipeToTurn)と共通でここで見る
        var button = virtualButton
        if button == VirtualButton.swipeLeft || button == VirtualButton.swipeRight {
            guard settings.swipeToTurnPage else { return }
            // スワイプの向き反転(既定オン)。オフで旧来の向きに戻る
            if settings.flipSwipeDirection {
                button = button == VirtualButton.swipeLeft
                    ? VirtualButton.swipeRight : VirtualButton.swipeLeft
            }
        }
        handleClick(button: button, modifiers: modifiers, leftHalf: false)
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
        if handleSwipeToTurn(event) { return }
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

    /// システムの「ページ間をスワイプ」と同じ 2 本指の水平スクロールジェスチャで
    /// ページを前後させる(既定オン。設定の「操作」でオフにできる)。
    /// 方向は既存のスワイプ仮想ボタン経由で解決するため、読み方向・カスタム
    /// バインディングに追従する。処理した(消費した)ら true。
    private func handleSwipeToTurn(_ event: NSEvent) -> Bool {
        guard settings.swipeToTurnPage,
              NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return false }
        // 消費したスワイプの慣性イベントは、めくった後の新しいページを
        // 揺らさないよう終端まで飲み込む
        if event.momentumPhase != [] {
            guard swipeConsumeMomentum else { return false }
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                swipeConsumeMomentum = false
            }
            return true
        }
        switch event.phase {
        case .began:
            swipeConsumeMomentum = false
            swipeTrackingActive =
                abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            swipeTrackingDeltaX = event.scrollingDeltaX
            interactiveCurlPhase = nil
            interactiveCurlEndDecision = nil
            return swipeTrackingActive
        case .changed:
            guard swipeTrackingActive else { return false }
            swipeTrackingDeltaX += event.scrollingDeltaX
            driveInteractiveCurl(event)
            return true
        case .ended, .cancelled:
            guard swipeTrackingActive else { return false }
            swipeTrackingActive = false
            swipeConsumeMomentum = true
            if settleInteractiveCurlOnGestureEnd() { return true }
            if abs(swipeTrackingDeltaX) > 60 {
                let virtualButton = swipeTrackingDeltaX > 0
                    ? VirtualButton.swipeRight : VirtualButton.swipeLeft
                handleGesture(virtualButton: virtualButton,
                              modifiers: LegacyModifier.encode(flags: event.modifierFlags))
            }
            return true
        default:
            return swipeTrackingActive  // 慣性イベント等はスワイプ中なら消費
        }
    }

    // MARK: - スワイプ追従カール(設定「ページカール」時のみ)

    /// スワイプ中の移動量からカールの進行度を駆動する。
    /// スワイプの向きが「次/前のページ」に割り当てられている場合だけ追従し、
    /// それ以外の割当・修飾キー付きは従来動作(離した時に一括実行)のまま
    private func driveInteractiveCurl(_ event: NSEvent) {
        guard settings.pageTurnAnimation == .curl,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let delta = swipeTrackingDeltaX
        switch interactiveCurlPhase {
        case .finished, .unavailable:
            return
        case nil:
            guard abs(delta) > 12 else { return }
            guard LegacyModifier.encode(flags: event.modifierFlags) == 0,
                  let forward = swipeTurnDirection(deltaX: delta) else {
                interactiveCurlPhase = .unavailable
                return
            }
            interactiveCurlPhase = .starting(forward: forward)
            interactiveCurlProgress = curlProgress(for: delta)
            Task { await self.startInteractiveCurl(forward: forward) }
        case .starting:
            interactiveCurlProgress = curlProgress(for: delta)
        case .active:
            interactiveCurlProgress = curlProgress(for: delta)
            readerViewForInput.updateInteractiveCurl(progress: interactiveCurlProgress)
        }
    }

    /// 移動量 → 進行度(350pt のスワイプでめくり切り)
    private func curlProgress(for delta: CGFloat) -> CGFloat {
        min(1, max(0, abs(delta) / 350))
    }

    /// スワイプの向きに割り当てられたアクションが次/前のページなら進行方向を返す
    private func swipeTurnDirection(deltaX: CGFloat) -> Bool? {
        var button = deltaX > 0 ? VirtualButton.swipeRight : VirtualButton.swipeLeft
        if settings.flipSwipeDirection {
            button = button == VirtualButton.swipeLeft
                ? VirtualButton.swipeRight : VirtualButton.swipeLeft
        }
        guard let binding = bindings.resolveMouse(
            button: button, modifiers: 0,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft),
            let action = binding.action else { return nil }
        switch action {
        case .nextPage: return true
        case .previousPage: return false
        default: return nil
        }
    }

    /// モデルを先に進め、旧内容のスナップショットで追従用オーバーレイを組む。
    /// 画面は progress=0 のオーバーレイ(旧内容)のまま=見た目は変わらない
    private func startInteractiveCurl(forward: Bool) async {
        guard let book, case .starting = interactiveCurlPhase else { return }
        let oldContent = readerViewForInput.snapshotContent()
        let moved = forward ? book.moveNext() : await book.movePrevious()
        guard moved == .moved else {
            // 端に達した: 従来動作(離した時の端処理=ループ/次の本)へ
            interactiveCurlPhase = .unavailable
            return
        }
        pendingTurnForward = nil
        if let oldContent {
            readerViewForInput.pendingInteractiveCurl = (oldContent, forward)
        }
        await refreshDisplay()
        if readerViewForInput.hasInteractiveCurl {
            interactiveCurlPhase = .active(forward: forward)
            readerViewForInput.updateInteractiveCurl(progress: interactiveCurlProgress)
        } else {
            // オーバーレイを組めない状態(回転・ルーペ等): 即時切替済み
            interactiveCurlPhase = .finished
        }
        settleInteractiveCurlIfGestureEnded()
    }

    /// ジェスチャ終了時の確定/取消。追従に入っていたら true(従来動作を抑止)
    private func settleInteractiveCurlOnGestureEnd() -> Bool {
        switch interactiveCurlPhase {
        case nil, .unavailable:
            interactiveCurlPhase = nil
            return false
        case .finished:
            interactiveCurlPhase = nil
            return true
        case .starting:
            // 準備完了時(startInteractiveCurl の末尾)に判定を適用する
            interactiveCurlEndDecision = abs(swipeTrackingDeltaX) > 60
            return true
        case .active(let forward):
            let complete = abs(swipeTrackingDeltaX) > 60
                || interactiveCurlProgress > 0.35
            resolveActiveCurl(forward: forward, complete: complete)
            return true
        }
    }

    /// 準備完了前にジェスチャが終わっていた場合の後始末
    private func settleInteractiveCurlIfGestureEnded() {
        guard let decision = interactiveCurlEndDecision else { return }
        interactiveCurlEndDecision = nil
        if case .active(let forward) = interactiveCurlPhase {
            resolveActiveCurl(forward: forward, complete: decision)
        } else {
            interactiveCurlPhase = nil
        }
    }

    /// 追従中カールの確定(残り再生)または取消(巻き戻し+モデルを戻す)
    private func resolveActiveCurl(forward: Bool, complete: Bool) {
        interactiveCurlPhase = nil
        if complete {
            readerViewForInput.finishInteractiveCurl()
        } else {
            readerViewForInput.cancelInteractiveCurl { [weak self] in
                guard let self, let book = self.book else { return }
                Task {
                    if forward {
                        _ = await book.movePrevious()
                    } else {
                        _ = book.moveNext()
                    }
                    await self.refreshDisplay()
                }
            }
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

        // サムネイルオーバーレイ表示中はページ送りをサムネイルのめくりに転用
        // (旧来のページ単位閲覧 §4.8)。t(showThumbnail)は下でトグル=閉じる
        if isThumbnailOverlayVisible {
            switch action {
            case .nextPage, .pageDownOrNextPage, .halfNextPage:
                thumbnailOverlayTurnPage(forward: true)
                return
            case .previousPage, .pageUpOrPreviousPage, .halfPreviousPage:
                thumbnailOverlayTurnPage(forward: false)
                return
            case .positionalNextPrevPage, .positionalHalfNextPrev:
                thumbnailOverlayTurnPage(forward: isNextSide)
                return
            default:
                break
            }
        }

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
        case .toggleInterpolation: settings.toggleInterpolationNone()

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
        setFitMode(next)
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
        if let next {
            setFitMode(next)
        }
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
