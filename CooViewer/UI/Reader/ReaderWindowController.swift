import AppKit

/// メインウインドウ。本のオープンフロー・表示更新・メニューアクションを担う。
/// 旧 Controller の表示/ナビゲーション部分に相当する(仕様書 §4.1-4.3)。
@MainActor
final class ReaderWindowController: NSWindowController {
    private(set) var book: Book?
    private let readerView = ReaderView()
    private let pageBar = PageBarView()
    private let pageLabel = NSTextField(labelWithString: "")

    let settings = SettingsStore.shared
    var bindings = BindingConfiguration.load()

    /// 入力ディスパッチ(+Input.swift)からのビューアクセス
    var readerViewForInput: ReaderView { readerView }

    private var cursorHideTimer: Timer?
    private var settingsObserver: (any NSObjectProtocol)?
    var slideshowTimer: Timer?
    var originalSizePanel: NSPanel?
    var thumbnailWindowController: ThumbnailWindowController?

    private lazy var brokenImage: CGImage? = Self.bundledCGImage(named: "broken")
    private lazy var emptyImage: CGImage? = Self.bundledCGImage(named: "empty")

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
        readerView.interpolation = settings.interpolation
        readerView.backgroundColor = settings.viewBackgroundColor
        if book != nil {
            pageLabel.isHidden = !settings.showNumber
            pageBar.isHidden = !settings.showPageBar
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
            guard await unlockIfNeeded(source) else { return }

            // 旧本の後始末(仕様書 §4.1.2 手順 4)
            stopSlideshow()
            saveCurrentBookState()

            let book = try await Book.open(source: source, sortMode: settings.sortMode)
            book.readMode = settings.readMode
            book.singleSetting = settings.singleSetting
            self.book = book

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
            pageLabel.isHidden = !settings.showNumber
            pageBar.isHidden = !settings.showPageBar
            await refreshDisplay()
        } catch {
            // 旧実装のエラー黙殺方針(仕様書 §4.17): ダイアログは出さない
            NSSound.beep()
        }
    }

    // MARK: - 終了処理(§7.7 の保存漏れを塞ぐ)

    func windowWillClose(_ notification: Notification) {
        stopSlideshow()
        saveCurrentBookState()
    }

    func saveStateBeforeTermination() {
        saveCurrentBookState()
    }

    /// パスワード書庫のロック解除。キャンセルで false(仕様書 §4.1.3)。
    /// 旧実装と異なり NSSecureTextField を使う(設計書 §13.4)。
    private func unlockIfNeeded(_ source: any BookSource) async -> Bool {
        while await source.isEncrypted() {
            let alert = NSAlert()
            alert.messageText = String(localized: "This archive is password-protected.")
            alert.informativeText = String(localized: "Enter the password to open it.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if await source.checkAndSetPassword(field.stringValue) {
                return true
            }
        }
        return true
    }

    // MARK: - 表示更新

    func refreshDisplay() async {
        guard let book else { return }
        let spread = await book.currentSpread()

        let images: [CGImage]
        if spread.indices.isEmpty {
            // 空の本は empty.png 1 ページ(仕様書 §4.17)
            images = [emptyImage].compactMap(\.self)
        } else {
            images = spread.images.map { $0 ?? brokenImage }.compactMap(\.self)
        }
        readerView.setPages(images, readsFromLeft: book.readMode.readsFromLeft)
        readerView.window?.makeFirstResponder(readerView)
        updatePageIndicators(spread: spread)
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

    /// 巻末超え(仕様書 §4.3.4)。1/2(次の本)はマイルストーン 7 で接続。
    func handleEndOfBook() {
        guard let book else { return }
        switch settings.loopCheck {
        case 0:
            book.goToFirst()
            Task { await refreshDisplay() }
        default:
            break
        }
    }

    func handleStartOfBook() {
        guard let book else { return }
        switch settings.loopCheck {
        case 0:
            Task {
                await book.goToLast()
                await refreshDisplay()
            }
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

    private static func bundledCGImage(named name: String) -> CGImage? {
        guard let image = NSImage(named: name) else { return nil }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
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
