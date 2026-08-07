import AppKit

/// メインウインドウ。本のオープンフロー・表示更新・メニューアクションを担う。
/// 旧 Controller の表示/ナビゲーション部分に相当する(仕様書 §4.1-4.3)。
@MainActor
final class ReaderWindowController: NSWindowController {
    private(set) var book: Book?
    private let readerView = ReaderView()
    private let pageBar = PageBarView()
    private let pageLabel = NSTextField(labelWithString: "")
    /// 開けなかった本の理由等をウインドウ中央に表示するラベル
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    let settings = SettingsStore.shared
    var bindings = BindingConfiguration.load()

    /// 入力ディスパッチ(+Input.swift)からのビューアクセス
    var readerViewForInput: ReaderView { readerView }

    private var cursorHideTimer: Timer?
    private var settingsObserver: (any NSObjectProtocol)?
    var slideshowTimer: Timer?
    /// 2 本指スワイプ(ページ間スワイプ)の追跡状態(+Input.swift)
    var swipeTrackingActive = false
    var swipeTrackingDeltaX: CGFloat = 0
    var originalSizePanel: NSPanel?
    var thumbnailWindowController: ThumbnailWindowController?

    /// 壊れページ用の実行時生成プレースホルダ(多言語対応。旧 broken.png の置換)
    private lazy var brokenPlaceholder: CGImage? = PlaceholderImage.make(
        text: String(localized: "This page could not be loaded."))

    /// 開けなかった本の理由(空の本の汎用メッセージと区別するため保持)
    private var lockedBookReason: String?

    /// 表示更新の世代。連打時に古い await 結果が新しい表示を上書きしないための番号
    private var displayGeneration = 0

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "cooViewer"
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 300, height: 200)
        window.setFrameAutosaveName("ReaderWindow")
        window.isReleasedWhenClosed = false  // 閉じても解放せず再表示できるように
        self.init(window: window)

        setUpContentViews(in: window)
        window.center()
        window.delegate = self
        readerView.delegate = self
        applySettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applySettings()
            }
        }
    }

    /// 設定を即時反映する(設計書 §2.4: 旧 Cancel ロールバック方式からの仕様変更)
    func applySettings() {
        bindings = BindingConfiguration.load()  // 編集タブの変更を即時反映
        readerView.interpolation = settings.interpolation
        readerView.backgroundColor = settings.viewBackgroundColor
        // 開けなかった本(空)ではオーバーレイを出さない
        if let book, book.pageCount > 0 {
            pageLabel.isHidden = !settings.showNumber
            pageBar.isHidden = !settings.showPageBar
            // 見開きしきい値の変更は現表示を再判定する(仕様書 §6.3)
            if book.singleSetting != settings.singleSetting {
                book.singleSetting = settings.singleSetting
                Task { await refreshDisplay() }
            }
        }
    }

    private func setUpContentViews(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        readerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(readerView)

        // ページバー/ページ番号は既定で左上(仕様書 §6.1 PageBarPosition/PageNumPosition=0)
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .white
        pageLabel.backgroundColor = .black.withAlphaComponent(0.8)
        pageLabel.drawsBackground = true
        pageLabel.wantsLayer = true
        pageLabel.layer?.cornerRadius = 4
        pageLabel.layer?.masksToBounds = true
        pageLabel.isHidden = true
        contentView.addSubview(pageLabel)

        pageBar.translatesAutoresizingMaskIntoConstraints = false
        pageBar.isHidden = true
        contentView.addSubview(pageBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .white
        statusLabel.isHidden = true
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            readerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            readerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            readerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            pageLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            pageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),

            pageBar.topAnchor.constraint(equalTo: pageLabel.bottomAnchor, constant: 4),
            pageBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            pageBar.widthAnchor.constraint(equalToConstant: 200),
            pageBar.heightAnchor.constraint(equalToConstant: 15),

            statusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        pageBar.onJump = { [weak self] fraction in
            guard let self, let book = self.book else { return }
            if book.goToPercent(fraction) == .moved {
                Task { await self.refreshDisplay() }
            }
        }
    }

    // MARK: - 本を開く

    /// URL から本を開く。単一画像は親フォルダに読み替える(仕様書 §4.1.2 手順 2)。
    func openBook(at url: URL, atPage page: Int? = nil, atLastPage: Bool = false) {
        Task {
            await openBookFlow(url: url, atPage: page, atLastPage: atLastPage)
        }
    }

    private func openBookFlow(url: URL, atPage: Int?, atLastPage: Bool) async {
        // ウインドウが閉じられた後の「最近使った本」「関連付けから開く」でも
        // 必ず再表示する(仕様書 §4.1.2 手順 1: window 前面化)
        showWindow(nil)

        var bookURL = url
        var initialPageName: String?

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return }
        if !isDirectory.boolValue, !SupportedTypes.isBookFile(url),
           SupportedTypes.isImageFile(url.lastPathComponent) {
            bookURL = url.deletingLastPathComponent()
            initialPageName = url.lastPathComponent
        }

        do {
            let source = try await BookSourceFactory.make(
                for: bookURL, readSubFolders: settings.readSubFolder)
            switch await unlock(source) {
            case .unlocked:
                break
            case .cancelled:
                presentLockedPlaceholder(
                    source: source,
                    reason: String(localized: "Password entry was canceled."))
                return
            case .attemptsExceeded:
                presentLockedPlaceholder(
                    source: source,
                    reason: String(localized: "Too many failed password attempts."))
                return
            }

            // 旧本の後始末(仕様書 §4.1.2 手順 4)
            stopSlideshow()
            saveCurrentBookState()

            let book = try await Book.open(source: source, sortMode: settings.sortMode,
                                           cacheByteLimit: settings.pageCacheByteLimit)
            book.readMode = settings.readMode
            book.singleSetting = settings.singleSetting
            self.book = book

            // 書庫のローカルスプール等を開始(パスワード解除後。設計書 キャッシュ節)
            await source.beginBackgroundPreparation()

            let skipPageRestore = initialPageName != nil || atPage != nil || atLastPage
            await restoreBookState(for: book, skipPageRestore: skipPageRestore)

            if let initialPageName,
               let index = book.entries.firstIndex(where: { $0.name == initialPageName }) {
                book.goTo(index: index)
            } else if let atPage {
                book.goTo(index: atPage)
            } else if atLastPage {
                await book.goToLast()
            }
            window?.title = book.displayName
            lockedBookReason = nil
            statusLabel.isHidden = true
            pageLabel.isHidden = !settings.showNumber
            pageBar.isHidden = !settings.showPageBar
            await refreshDisplay()
        } catch {
            // 旧実装のエラー黙殺方針(仕様書 §4.17): ダイアログは出さない
            NSSound.beep()
        }
    }

    /// 開けなかった本(パスワードのキャンセル/試行超過)を「現在の本」として
    /// 空の状態で表示する。これによりページ送りや「次の本」でこの本を
    /// 飛ばして先へ進める。履歴・設定には記録しない。
    private func presentLockedPlaceholder(source: any BookSource, reason: String) {
        stopSlideshow()
        saveCurrentBookState()
        let placeholder = Book(source: source, entries: [])
        book = placeholder
        lockedBookReason = reason
        window?.title = placeholder.displayName
        readerView.setPages([], readsFromLeft: false)
        showBookStatusMessage(reason)
    }

    // MARK: - 終了処理(§7.7 の保存漏れを塞ぐ)

    func windowWillClose(_ notification: Notification) {
        stopSlideshow()
        saveCurrentBookState()
    }

    func saveStateBeforeTermination() {
        saveCurrentBookState()
    }

    private enum UnlockResult {
        case unlocked
        case cancelled
        case attemptsExceeded
    }

    /// パスワード書庫のロック解除(仕様書 §4.1.3)。
    /// 旧実装の「正解かキャンセルまで無限に再表示」をやめ、3 回で打ち切る。
    private func unlock(_ source: any BookSource) async -> UnlockResult {
        // UI 検証用の隠しフック(モーダルを出さずキャンセル扱いにする)
        if ProcessInfo.processInfo.environment["COOVIEWER_UI_TEST_CANCEL_PASSWORD"] != nil,
           await source.isEncrypted() {
            return .cancelled
        }
        let maxAttempts = 3
        var attemptsLeft = maxAttempts
        while await source.isEncrypted() {
            guard attemptsLeft > 0 else { return .attemptsExceeded }
            let alert = NSAlert()
            alert.messageText = String(localized: "This archive is password-protected.")
            alert.informativeText = attemptsLeft == maxAttempts
                ? String(localized: "Enter the password to open it.")
                : String(localized: "Wrong password. \(attemptsLeft) attempts left.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
            if await source.checkAndSetPassword(field.stringValue) {
                return .unlocked
            }
            attemptsLeft -= 1
        }
        return .unlocked
    }

    // MARK: - 表示更新

    func refreshDisplay() async {
        guard let book else { return }
        displayGeneration += 1
        let generation = displayGeneration
        let spread = await book.currentSpread()
        // 連打等でより新しい表示更新が始まっていたら、この結果は捨てる
        guard generation == displayGeneration, book === self.book else { return }

        if spread.indices.isEmpty {
            // ページのない本: 理由をウインドウ中央に表示する
            // (旧 empty.png 方式 §4.17 を多言語メッセージに置換)
            readerView.setPages([], readsFromLeft: book.readMode.readsFromLeft)
            showBookStatusMessage(
                lockedBookReason
                    ?? String(localized: "This book contains no displayable images."))
            updatePageIndicators(spread: spread)
            return
        }
        statusLabel.isHidden = true
        // 壊れページは理由入りプレースホルダで表示(ページ数は保つ。§4.17)
        let images = spread.images.map { $0 ?? brokenPlaceholder }.compactMap(\.self)
        // 非同期の合間に本が入れ替わった場合に備えて範囲を検証する(範囲外は
        // インデックスをそのままキーにする。クラッシュ報告 Index out of range 対策)
        let ids = spread.indices.map { index in
            book.entries.indices.contains(index) ? book.entries[index].id : index
        }
        readerView.setPages(images, ids: ids,
                            readsFromLeft: book.readMode.readsFromLeft)
        readerView.window?.makeFirstResponder(readerView)
        updatePageIndicators(spread: spread)
        if readerView.isLoupeEnabled {
            requestLoupeHighResolution()
        }
    }

    /// ページのない本(空/開けなかった)の理由と操作案内を中央に表示する
    private func showBookStatusMessage(_ reason: String) {
        statusLabel.stringValue = reason + "\n"
            + String(localized: "Turn the page or use Next Book to continue.")
        statusLabel.isHidden = false
        pageLabel.isHidden = true
        pageBar.isHidden = true
    }

    private func updatePageIndicators(spread: Book.Spread) {
        guard let book, book.pageCount > 0 else {
            pageLabel.stringValue = ""
            pageBar.progress = 0
            return
        }
        let shown = spread.indices.map { String($0 + 1) }
        let numbers = shown.count == 2 ? "\(shown[0])-\(shown[1])" : (shown.first ?? "-")
        pageLabel.stringValue = " \(numbers)/\(book.pageCount) "
        let lastShown = (spread.indices.last ?? 0) + 1
        pageBar.progress = Double(lastShown) / Double(book.pageCount)
        pageBar.readsFromLeft = book.readMode.readsFromLeft
    }

    // MARK: - ナビゲーション

    private func showNext() {
        guard let book else { return }
        switch book.moveNext() {
        case .moved:
            Task { await refreshDisplay() }
        case .hitEnd:
            handleEndOfBook()
        case .hitStart:
            break
        }
    }

    private func showPrevious() {
        guard let book else { return }
        Task {
            switch await book.movePrevious() {
            case .moved:
                await refreshDisplay()
            case .hitStart:
                handleStartOfBook()
            case .hitEnd:
                break
            }
        }
    }

    /// 巻末超え(仕様書 §4.3.4)
    func handleEndOfBook() {
        guard let book else { return }
        // 開けなかった本(空)はループ設定に関わらずスキップして次へ
        if book.pageCount == 0 {
            openAdjacentBook(forward: true)
            return
        }
        switch settings.loopCheck {
        case 0:
            book.goToFirst()
            Task { await refreshDisplay() }
        case 1, 2:
            // 前方は 1/2 とも「次の本の先頭」(仕様書 §4.3.4)
            openAdjacentBook(forward: true)
        default:
            break
        }
    }

    func handleStartOfBook() {
        guard let book else { return }
        if book.pageCount == 0 {
            openAdjacentBook(forward: false)
            return
        }
        switch settings.loopCheck {
        case 0:
            Task {
                await book.goToLast()
                await refreshDisplay()
            }
        case 1:
            // 前の本の先頭へ(GoToLastPage 復元が働き得る。仕様書 §4.3.4)
            openAdjacentBook(forward: false)
        case 2:
            // 前の本を必ず末尾から(復元バイパス。仕様書 §4.3.4)
            openAdjacentBook(forward: false, openLast: true)
        default:
            break
        }
    }

    /// ジャンプ系アクション後の再表示(+Input.swift から使用)
    func refreshAfterJump() {
        Task { await refreshDisplay() }
    }

    /// 前ページへ戻り、PrevPageMode=1 ならページ末尾から表示(仕様書 §6.1)
    func performPreviousFromEnd() {
        guard let book else { return }
        Task {
            switch await book.movePrevious() {
            case .moved:
                await refreshDisplay()
                if settings.prevPageMode == 1 {
                    readerView.scrollToEnd()
                }
            case .hitStart:
                handleStartOfBook()
            case .hitEnd:
                break
            }
        }
    }

    // MARK: - メニューアクション

    @objc func nextPage(_ sender: Any?) { showNext() }
    @objc func previousPage(_ sender: Any?) { showPrevious() }

    @objc func halfNextPage(_ sender: Any?) {
        guard let book else { return }
        if book.moveHalfNext() == .moved {
            Task { await refreshDisplay() }
        }
    }

    @objc func halfPreviousPage(_ sender: Any?) {
        guard let book else { return }
        if book.moveHalfPrevious() == .moved {
            Task { await refreshDisplay() }
        }
    }

    @objc func goToFirstPage(_ sender: Any?) {
        book?.goToFirst()
        Task { await refreshDisplay() }
    }

    @objc func goToLastPage(_ sender: Any?) {
        Task {
            await book?.goToLast()
            await refreshDisplay()
        }
    }

    @objc func changeFitMode(_ sender: NSMenuItem) {
        guard let mode = ReaderView.FitMode(rawValue: sender.tag) else { return }
        readerView.fitMode = mode
    }

    @objc func changeReadMode(_ sender: NSMenuItem) {
        guard let book, let mode = ReadMode(rawValue: sender.tag) else { return }
        book.readMode = mode
        Task { await refreshDisplay() }
    }

    @objc func cycleReadMode(_ sender: Any?) {
        guard let book else { return }
        book.readMode = book.readMode.cycled
        Task { await refreshDisplay() }
    }

    @objc func rotateLeft(_ sender: Any?) {
        readerView.rotation += 1  // 仕様書 §4.15: rotateLeft はインクリメント
    }

    @objc func rotateRight(_ sender: Any?) {
        readerView.rotation -= 1
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(changeFitMode(_:)):
            menuItem.state = readerView.fitMode.rawValue == menuItem.tag ? .on : .off
            return true
        case #selector(changeReadMode(_:)):
            menuItem.state = book?.readMode.rawValue == menuItem.tag ? .on : .off
            return book != nil
        case #selector(nextPage(_:)), #selector(previousPage(_:)),
             #selector(halfNextPage(_:)), #selector(halfPreviousPage(_:)),
             #selector(goToFirstPage(_:)), #selector(goToLastPage(_:)),
             #selector(cycleReadMode(_:)), #selector(showThumbnailsMenu(_:)):
            return book != nil
        default:
            return true
        }
    }

    // MARK: - フルスクリーンのカーソル自動非表示(仕様書 §3.3)

    func windowDidEnterFullScreen(_ notification: Notification) {
        scheduleCursorHide()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        cursorHideTimer?.invalidate()
        cursorHideTimer = nil
    }

    func noteMouseMoved() {
        guard window?.styleMask.contains(.fullScreen) == true else { return }
        scheduleCursorHide()
    }

    private func scheduleCursorHide() {
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            Task { @MainActor in
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    // MARK: -

}

// MARK: - NSWindowDelegate

extension ReaderWindowController: NSWindowDelegate {}

// MARK: - NSMenuItemValidation

extension ReaderWindowController: NSMenuItemValidation {}

// MARK: - ReaderViewDelegate

extension ReaderWindowController: ReaderViewDelegate {
    func readerView(_ view: ReaderView, didReceiveDropped url: URL) {
        openBook(at: url)
    }

    func readerViewMouseMoved(_ view: ReaderView) {
        noteMouseMoved()
    }

    func readerView(_ view: ReaderView, handleKey event: NSEvent) -> Bool {
        handleKeyEvent(event)
    }

    func readerView(_ view: ReaderView, clickedButton button: Int,
                    modifiers: Int, leftHalf: Bool) {
        handleClick(button: button, modifiers: modifiers, leftHalf: leftHalf)
    }

    func readerView(_ view: ReaderView, gesture virtualButton: Int, modifiers: Int) {
        handleGesture(virtualButton: virtualButton, modifiers: modifiers)
    }

    func readerView(_ view: ReaderView, dragGesture directionModifier: Int, baseModifiers: Int) {
        handleDragGesture(directionModifier: directionModifier, baseModifiers: baseModifiers)
    }

    func readerViewShouldDragScroll(_ view: ReaderView, modifiers: Int) -> Bool {
        shouldDragScroll(modifiers: modifiers)
    }

    func readerView(_ view: ReaderView, scrollWheel event: NSEvent) {
        handleScrollWheel(event)
    }
}
