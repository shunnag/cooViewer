import AppKit

/// カール追従の共有判定(スワイプ/マウスドラッグ共通の純関数。設計書 §7.6)
enum InteractiveCurlRules {
    /// 移動量 → 進行度(350pt のスワイプ/ドラッグでめくり切り)
    static func progress(for delta: CGFloat) -> CGFloat {
        min(1, max(0, abs(delta) / 350))
    }

    /// ジェスチャ終了時にめくり切るか(60pt 超の移動または進行度 0.35 超)
    static func completes(finalDelta: CGFloat, progress: CGFloat) -> Bool {
        abs(finalDelta) > 60 || progress > 0.35
    }

    /// マウスドラッグでカール追従を開始してよいか: 水平方向の本判定
    /// (30pt 超)が出たときのみ。垂直はカールの向きと合わないため対象外
    static func beginsMouseTracking(dx: CGFloat, dy: CGFloat) -> Bool {
        switch MouseGestureRecognizer.dragDirection(dx: dx, dy: dy) {
        case LegacyModifier.dragLeft?, LegacyModifier.dragRight?: true
        default: false
        }
    }
}

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
        if mouseCurlConsumedGesture {
            // カール追従が確定/巻き戻しを済ませたドラッグの解放(30pt 内へ
            // 戻して離した場合はクリック判定になる)を二重発火させない
            mouseCurlConsumedGesture = false
            return
        }
        guard let binding = bindings.resolveMouse(
            button: button, modifiers: modifiers,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft),
            let action = binding.action else { return }
        perform(action, value: binding.value, leftHalf: leftHalf)
    }

    func handleGesture(virtualButton: Int, modifiers: Int, leftHalf: Bool) {
        // 水平スワイプの「ページ送り」だけをトグルで無効化・向き反転する。
        // 水平スワイプを別アクション(次の本など)へ割り当てたユーザーの設定は
        // トグル/反転の影響を受けず常に発火させる(解決結果で判定)。
        // システム設定が「3 本指でスワイプ」の場合も swipe イベントとして
        // この経路に届くため、2 本指(handleSwipeToTurn)と共通でここで見る
        var button = virtualButton
        if button == VirtualButton.swipeLeft || button == VirtualButton.swipeRight {
            let action = bindings.resolveMouse(
                button: button, modifiers: modifiers,
                fitMode: fitModeNumber, readsFromLeft: readsFromLeft)?.action
            if action == .nextPage || action == .previousPage {
                guard settings.swipeToTurnPage else { return }
                // スワイプの向き反転(既定オン)。オフで旧来の向きに戻る
                if settings.flipSwipeDirection {
                    button = button == VirtualButton.swipeLeft
                        ? VirtualButton.swipeRight : VirtualButton.swipeLeft
                }
            }
        }
        handleClick(button: button, modifiers: modifiers, leftHalf: leftHalf)
    }

    func handleDragGesture(directionModifier: Int, baseModifiers: Int, button: Int,
                           leftHalf: Bool) {
        if mouseCurlConsumedGesture {
            mouseCurlConsumedGesture = false
            return  // カール追従が既にページ送りを確定/取消した
        }
        guard let binding = bindings.resolveDrag(
            button: button, baseModifiers: baseModifiers, directionModifier: directionModifier,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft),
            let action = binding.action else { return }
        perform(action, value: binding.value, leftHalf: leftHalf)
    }

    func shouldDragScroll(button: Int, modifiers: Int) -> Bool {
        bindings.resolveDragScroll(button: button,
                                   modifiers: LegacyModifier.drag + modifiers,
                                   fitMode: fitModeNumber) != nil
    }

    /// ドラッグ追跡中の方向 HUD 駆動。方向と割当アクション名を予告する
    /// (旧マウスジェスチャの「何が起きるか見えない」弱点への 2.0 の答え。
    /// 設定「操作」の GestureHUDEnabled でオフ可)
    func handleDragTracking(dx: CGFloat, dy: CGFloat, button: Int, modifiers: Int,
                            elapsed: TimeInterval) {
        guard book != nil else { return }
        // 水平ドラッグの割当が次/前ページならカールがカーソルに追従する。
        // 追従中は HUD を出さない — カール自体がフィードバック(設計書 §2.4)
        if driveMouseDragCurl(dx: dx, dy: dy, button: button, modifiers: modifiers) {
            gestureHUD.hide()
            return
        }
        guard settings.gestureHUDEnabled else { return }
        let state = GestureHUDModel.state(dx: dx, dy: dy, elapsed: elapsed)
        var actionName: String?
        switch state {
        case .faint(let direction), .armed(let direction):
            // resolveDrag は switchAction 入替(左綴じ)適用済みの番号を返すため、
            // 表示名と実際の発火が食い違わない(仕様書 §5.4)
            if let binding = bindings.resolveDrag(
                button: button, baseModifiers: modifiers, directionModifier: direction,
                fitMode: fitModeNumber, readsFromLeft: readsFromLeft) {
                actionName = ActionNames.mouseActionName(binding.legacyActionNumber)
            }
        case .hidden, .expired:
            break
        }
        gestureHUD.apply(state: state, actionName: actionName)
    }

    /// ドラッグ追跡の終了(発火の有無に関わらず解放時)。カール追従の確定/取消と
    /// HUD の後始末を行う
    func handleDragTrackingEnded() {
        gestureHUD.hide()
        guard mouseCurlTracking else {
            mouseCurlConsumedGesture = false
            return
        }
        mouseCurlTracking = false
        mouseCurlConsumedGesture =
            settleInteractiveCurlOnGestureEnd(finalDelta: mouseCurlDelta)
        mouseCurlDelta = 0
        if mouseCurlConsumedGesture {
            // 直後に同期ディスパッチされる mouseUp のクリック/ジェスチャだけを
            // 抑止する。発火が無かった場合(1 秒超等)に旗が残らないよう、
            // 現在のイベント処理が終わったら必ず下ろす
            Task { @MainActor in self.mouseCurlConsumedGesture = false }
        }
    }

    /// マウスドラッグでのカール追従。追従が進行中なら true(HUD を抑止)。
    /// 追従開始後は 1 秒長押しキャンセルを適用しない — スワイプ同様の直接操作
    /// として、離した時点の進行度で確定/巻き戻しを決める(設計書 §2.4)
    private func driveMouseDragCurl(dx: CGFloat, dy: CGFloat, button: Int,
                                    modifiers: Int) -> Bool {
        if !mouseCurlTracking {
            // 水平方向の本判定(30pt 超)が出た瞬間から追従を試みる。
            // 垂直ドラッグは割当が次/前ページでもカールの向きと合わないため従来動作
            guard InteractiveCurlRules.beginsMouseTracking(dx: dx, dy: dy) else {
                return false
            }
            mouseCurlTracking = true
            // 前回の端到達等で残った確定予約を持ち越さない(スワイプの .began と同型)
            interactiveCurlEndDecision = nil
        }
        mouseCurlDelta = dx
        driveInteractiveCurl(delta: dx, modifiers: modifiers, startThreshold: 30,
                             direction: { self.dragTurnDirection(dx: $0, button: button) })
        switch interactiveCurlPhase {
        case .starting, .active, .finished:
            return true
        case nil, .unavailable:
            return false  // 追従不成立(別割当・カール以外の効果等)は HUD へ
        }
    }

    // MARK: - スマートズーム/Force click(設計書 §2.4 の新規操作)

    /// 2 本指ダブルタップ: 全体フィットならタップ位置を中心に幅フィットへ拡大、
    /// 拡大系表示中なら全体フィットへ戻るトグル(Preview.app と同じ心理モデル)
    func handleSmartZoom(at point: CGPoint) {
        guard settings.smartZoomEnabled, let book else { return }
        let view = readerViewForInput
        if view.fitMode == .fitToScreen {
            let ratio = view.contentAnchorRatio(for: point)
            setFitMode(.fitWidth)
            view.scroll(toAnchorRatio: ratio)
            // キャップ上昇による非同期の再デコードが setPages でスクロールを
            // 先頭へ戻すことがあるため、完了時に再適用する
            pendingScrollAnchor = (ratio, book.currentIndex)
        } else {
            pendingScrollAnchor = nil
            setFitMode(.fitToScreen)
        }
    }

    /// トラックパッドの深押し=クイックルーペ: 押している間だけ表示し、
    /// 解放(handleForceClickEnded)で消える — 消す操作を覚える必要がない。
    /// ⌘L / l キー / 中クリックの常時表示トグルは従来どおりで、常時表示中に
    /// 深押しした場合はそれを消す(ルーペ操作としての一貫性)。処理したら true
    func handleForceClick() -> Bool {
        guard settings.forceClickLoupe, book != nil else { return false }
        if readerViewForInput.isLoupeEnabled {
            forceClickLoupeHeld = false
            perform(.toggleLoupe, value: nil, leftHalf: nil)  // 表示中なら消す
        } else {
            forceClickLoupeHeld = true
            perform(.toggleLoupe, value: nil, leftHalf: nil)
        }
        return true
    }

    /// 深押しの解放: クイックルーペで出したルーペだけを畳む
    func handleForceClickEnded() {
        guard forceClickLoupeHeld else { return }
        forceClickLoupeHeld = false
        if readerViewForInput.isLoupeEnabled {
            perform(.toggleLoupe, value: nil, leftHalf: nil)
        }
    }

    /// ドラッグ方向の割当が次/前のページなら進行方向を返す(カール追従の可否)
    private func dragTurnDirection(dx: CGFloat, button: Int) -> Bool? {
        let direction = dx < 0 ? LegacyModifier.dragLeft : LegacyModifier.dragRight
        guard let binding = bindings.resolveDrag(
            button: button, baseModifiers: 0, directionModifier: direction,
            fitMode: fitModeNumber, readsFromLeft: readsFromLeft),
            let action = binding.action else { return nil }
        switch action {
        case .nextPage: return true
        case .previousPage: return false
        default: return nil
        }
    }

    /// 検証用: HUD を指定方向の強調状態で表示する(--show-gesture-hud)。
    /// 実経路(handleDragTracking)を通すため割当名の解決も本番同様
    func debugShowGestureHUD(named direction: String) {
        let displacement: (dx: CGFloat, dy: CGFloat)? = switch direction {
        case "left": (-100, 0)
        case "right": (100, 0)
        case "up": (0, -100)
        case "down": (0, 100)
        default: nil
        }
        guard let displacement else { return }
        handleDragTracking(dx: displacement.dx, dy: displacement.dy,
                           button: 0, modifiers: 0, elapsed: 0.1)
    }

    // MARK: - ホイール(仕様書 §4.16)

    func handleScrollWheel(_ event: NSEvent) {
        guard book != nil else { return }
        let view = readerViewForInput
        // 連続ズーム中は 2 本指スクロールを常にパンへ振り替える(ページ送りや
        // 幅フィットの端到達めくりを抑止)。fitToScreen でも拡大後は pan が要る
        if view.isZoomed {
            view.scroll(by: CGPoint(x: -event.scrollingDeltaX, y: -event.scrollingDeltaY))
            return
        }
        if handleSwipeToTurn(event) { return }
        let mode = settings.canScrollMode

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
            // マウスドラッグのカール追従中はスワイプに状態を奪わせない
            // (interactiveCurlPhase を共有しているため、リセットすると
            // 進行中のオーバーレイが孤児化する)
            guard !mouseCurlTracking else { return false }
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
            driveInteractiveCurl(delta: swipeTrackingDeltaX,
                                 modifiers: LegacyModifier.encode(flags: event.modifierFlags),
                                 startThreshold: 12,
                                 direction: swipeTurnDirection(deltaX:))
            return true
        case .ended, .cancelled:
            guard swipeTrackingActive else { return false }
            swipeTrackingActive = false
            swipeConsumeMomentum = true
            if settleInteractiveCurlOnGestureEnd(finalDelta: swipeTrackingDeltaX) {
                return true
            }
            if abs(swipeTrackingDeltaX) > 60 {
                let virtualButton = swipeTrackingDeltaX > 0
                    ? VirtualButton.swipeRight : VirtualButton.swipeLeft
                handleGesture(virtualButton: virtualButton,
                              modifiers: LegacyModifier.encode(flags: event.modifierFlags),
                              leftHalf: readerViewForInput.isLeftHalf(
                                locationInWindow: event.locationInWindow))
            }
            return true
        default:
            return swipeTrackingActive  // 慣性イベント等はスワイプ中なら消費
        }
    }

    // MARK: - スワイプ追従カール(設定「ページカール」時のみ)

    /// ジェスチャ中の移動量からカールの進行度を駆動する(スワイプ/マウス
    /// ドラッグ共通)。向きの割当が「次/前のページ」の場合だけ追従し、
    /// それ以外の割当・修飾キー付きは従来動作(離した時に一括実行)のまま
    private func driveInteractiveCurl(delta: CGFloat, modifiers: Int,
                                      startThreshold: CGFloat,
                                      direction: (CGFloat) -> Bool?) {
        guard settings.pageTurnAnimation == .curl,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        switch interactiveCurlPhase {
        case .finished, .unavailable:
            return
        case nil:
            guard abs(delta) > startThreshold else { return }
            guard modifiers == 0, let forward = direction(delta) else {
                interactiveCurlPhase = .unavailable
                return
            }
            interactiveCurlPhase = .starting(forward: forward)
            interactiveCurlProgress = InteractiveCurlRules.progress(for: delta)
            Task { await self.startInteractiveCurl(forward: forward) }
        case .starting:
            interactiveCurlProgress = InteractiveCurlRules.progress(for: delta)
        case .active:
            interactiveCurlProgress = InteractiveCurlRules.progress(for: delta)
            readerViewForInput.updateInteractiveCurl(progress: interactiveCurlProgress)
        }
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
            // 端に達した: 従来動作(離した時の端処理=ループ/次の本)へ。
            // ジェスチャが既に終わっていた(settle が従来動作を抑止済み)なら、
            // ここで通常のページ送りへ委譲して端処理を発動させる — 放置すると
            // 端で無反応+残留 decision が次のカールを即時誤確定させる
            interactiveCurlPhase = .unavailable
            if let decision = interactiveCurlEndDecision {
                interactiveCurlEndDecision = nil
                interactiveCurlPhase = nil
                if decision {
                    perform(forward ? .nextPage : .previousPage, value: nil, leftHalf: nil)
                }
            }
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
    private func settleInteractiveCurlOnGestureEnd(finalDelta: CGFloat) -> Bool {
        switch interactiveCurlPhase {
        case nil, .unavailable:
            interactiveCurlPhase = nil
            return false
        case .finished:
            interactiveCurlPhase = nil
            return true
        case .starting:
            // 準備完了時(startInteractiveCurl の末尾)に判定を適用する
            interactiveCurlEndDecision = InteractiveCurlRules.completes(
                finalDelta: finalDelta, progress: 0)
            return true
        case .active(let forward):
            let complete = InteractiveCurlRules.completes(
                finalDelta: finalDelta, progress: interactiveCurlProgress)
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
        case .skip: skipPages(by: (value ?? 10).safeInt ?? 10)
        case .backSkip: skipPages(by: -((value ?? 10).safeInt ?? 10))
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
            let count = (value ?? 10).safeInt ?? 10
            skipPages(by: isNextSide ? count : -count)
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
