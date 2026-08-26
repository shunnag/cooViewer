import AppKit
import Sparkle
import SwiftUI
import Washi

/// 自動実行(XCTest / スナップショット検証)の判定。
/// テストホストがユーザーの実データ(最後に開いた本)に触ったり、
/// モーダル(Sparkle 許可・パスワード)で停止したりしないための共通ゲート
enum AutomatedRun {
    static var isXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    static var isSnapshot: Bool {
        CommandLine.arguments.contains("--snapshot")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var readerWindowController: ReaderWindowController?
    private var settingsWindow: NSWindow?
    private var activityWindow: NSWindow?
    private var activityMonitor: ActivityMonitor?
    /// 起動時に文書オープン(Finder ダブルクリック等)を受け取ったか。
    /// 受け取っていたら「前回の本を開く」(§6.1)は行わない
    private var didOpenDocumentAtLaunch = false
    /// ウインドウ生成前に届いた文書オープンの保留分(起動完了時に開く)
    private var pendingLaunchOpenURL: URL?
    /// --open 検証実行の起動直後だけ、AppKit が引数パスを文書として中継して
    /// くる分を無視する(起動完了から猶予を置いて解除)
    private var suppressRelayedDocumentOpens = CommandLine.arguments.contains("--open")
    /// 検証用スナップショットの一時ウインドウ(設定ウインドウとは別管理)
    private var debugPreviewWindow: NSWindow?

    /// Sparkle の自動更新(設計書 §配布)。フィード URL と EdDSA 公開鍵は
    /// Info.plist(SUFeedURL / SUPublicEDKey)。初回は Sparkle 標準の
    /// 許可ダイアログでユーザーが自動チェックを選ぶ。検証用スナップショット
    /// 実行(--snapshot)と XCTest 実行では、許可ダイアログ(モーダル)が
    /// 写り込み・ハングの原因になるため起動しない
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: !AutomatedRun.isSnapshot && !AutomatedRun.isXCTest,
        updaterDelegate: nil, userDriverDelegate: nil)

    /// メニュー「アップデートを確認…」(MainMenuBuilder から使用)
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.registerDefaults()
        // 旧形式の本の状態(BookSettings/RecentItems/LastPages)を v2 へ
        // 一括インポート(初回のみ。旧キーは 1.x 用に凍結保持)
        BookHistoryStore.shared.migrateLegacyDataIfNeeded()
        NSApp.mainMenu = MainMenuBuilder.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ReaderWindowController()
        readerWindowController = controller
        controller.showWindow(nil)
        cleanUpCaches()
        if let pending = pendingLaunchOpenURL {
            // 起動前に届いていた文書オープンを確定する(§6.1)
            pendingLaunchOpenURL = nil
            controller.openBook(at: pending)
        } else {
            handleDebugArguments()
        }
        if suppressRelayedDocumentOpens {
            // AppKit の引数中継は起動シーケンス内で届く。猶予を置いて解除し、
            // 以後の(本物の)文書オープンは通常どおり受け付ける
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.suppressRelayedDocumentOpens = false
            }
        }
    }

    /// 起動時のキャッシュ掃除: 生存していないプロセスのスプール残骸
    /// (仕様書 §4.17 の temp 残り問題への対策)と古いサムネイルを回収する。
    private func cleanUpCaches() {
        Task.detached(priority: .utility) {
            // 旧 PNG サムネイルキャッシュは丸ごと削除(v2 HEIC で作り直す)
            ThumbnailCache.removeLegacyCacheDirectory()
            let root = ArchiveSource.spoolRoot()
            if let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) {
                // 生存判定を kill(pid,0)==0 だけで行うと、OS の pid 再利用で
                // 無関係な同一ユーザープロセスがその pid を握っているときに
                // 『生存』と誤判定し、暗号化祖先由来の復号済み平文スプールが
                // 回収されず残留する(監査 #4)。実際に生きている cooViewer の
                // pid 集合と照合する(Debug の ad-hoc ビルドも同じ bundle id)
                let livePids = Set(NSRunningApplication.runningApplications(
                    withBundleIdentifier: "jp.coo.cooViewer")
                    .map { $0.processIdentifier })
                for child in children {
                    let pid = child.lastPathComponent.split(separator: "-").first
                        .flatMap { pid_t($0) }
                    // 生きている cooViewer の分だけ残す
                    if let pid, livePids.contains(pid) { continue }
                    try? FileManager.default.removeItem(at: child)
                }
            }
            let cacheDays = await SettingsStore.shared.thumbnailCacheDays
            await ThumbnailCache.shared.trimDiskCache(olderThanDays: cacheDays)
            // 超解像キャッシュもサムネイルと同じ保持日数で回収する
            MLSuperResolver.trimDiskCache(olderThanDays: cacheDays)
        }
    }

    /// 動作検証用の隠し引数(スクリーンショット権限なしで描画結果を確認するため):
    /// --open <path> で本を開き、--snapshot <path> で 2 秒後に contentView を
    /// PNG 出力して終了する。
    private func handleDebugArguments() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--dump-first-responder"),
           index + 1 < arguments.count {
            // 検証用: キーウインドウの first responder 型名を書き出して終了
            // (EPUB⇔画像本のモード切替でフォーカスが戻るかの確認)
            let path = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                let name = self.readerWindowController?.window?.firstResponder
                    .map { String(describing: type(of: $0)) } ?? "nil"
                try? name.write(toFile: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        if let index = arguments.firstIndex(of: "--appearance"),
           index + 1 < arguments.count {
            // 検証用: 外観を強制(dark / light)。EPUB テーマ追従等の確認
            NSApp.appearance = NSAppearance(
                named: arguments[index + 1] == "dark" ? .darkAqua : .aqua)
        }
        if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count {
            // --at-page <1 始まり> で開始ページも指定できる(検証用)
            var page: Int?
            if let pageIndex = arguments.firstIndex(of: "--at-page"),
               pageIndex + 1 < arguments.count, let number = Int(arguments[pageIndex + 1]) {
                page = number - 1
            }
            readerWindowController?.openBook(
                at: URL(fileURLWithPath: arguments[index + 1]), atPage: page)
        } else if SettingsStore.shared.openLastFolder,
                  !AutomatedRun.isXCTest, !didOpenDocumentAtLaunch,
                  let recent = BookHistoryStore.shared.mostRecentBook() {
            // 起動時に前回の本を開く(仕様書 §6.1 OpenLastFolder、既定 YES)。
            // XCTest のホストとしての起動では開かない: ユーザーの実データに
            // 触れない・履歴を汚さない・モーダルでテストを止めないため
            readerWindowController?.openBook(at: URL(fileURLWithPath: recent.path))
        }
        if arguments.contains("--show-thumbnails") {
            // 本のロード完了を待ってからサムネイルオーバーレイを開く
            // (EPUB モードなら画面単位の一覧)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.toggleThumbnailOverlay()
            }
        }
        if arguments.contains("--show-bookmark-editor") {
            // 検証用: シートではなく通常ウインドウで表示する(シートの
            // NSHostingView は layer.render/cacheDisplay のどちらでも写らないため)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard let book = self.readerWindowController?.book else { return }
                let window = NSWindow(contentViewController: NSHostingController(
                    rootView: BookmarkEditorView(
                        bookmarks: [
                            .init(name: "bookmark1", pageIndex: 1),
                            .init(name: "お気に入りの見開き", pageIndex: 3),
                        ],
                        pageCount: book.pageCount,
                        onSave: { _ in }, onClose: {})))
                window.makeKeyAndOrderFront(nil)
                self.debugPreviewWindow = window
            }
        }
        // 検証用: --then-* のナビゲーション系フラグは**コマンドライン順に
        // 1 秒間隔で逐次実行**する(組合せ・繰り返しの検証: 例
        // --then-goto-percent 100 --then-next-page で巻末超えの着地確認)。
        // --then-previous-book / --then-next-book: 前/次の本へ(Ctrl+D 相当)
        // --then-next-page: ページ送り(EPUB はリフローのページ送りに分岐)
        // --then-goto-percent N: 比率ジャンプ(数字キー 0-9 の goToPercent 経路)
        var navigationSteps: [@MainActor () -> Void] = []
        var argIndex = 0
        while argIndex < arguments.count {
            switch arguments[argIndex] {
            case "--then-previous-book", "--then-next-book":
                let forward = arguments[argIndex] == "--then-next-book"
                navigationSteps.append { [weak self] in
                    self?.readerWindowController?.openAdjacentBook(forward: forward)
                }
            case "--then-next-page":
                navigationSteps.append { [weak self] in
                    self?.readerWindowController?.nextPage(nil)
                }
            case "--then-show-thumbnails":
                // サムネイル一覧のトグル(EPUB 入場後に開く検証用)
                navigationSteps.append { [weak self] in
                    self?.readerWindowController?.toggleThumbnailOverlay()
                }
            case "--then-rapid-thumbnails":
                // 検証用: サムネイル一覧を約 70ms 間隔で N 回トグルする
                // (t キー連打の再現。奇数なら開いた状態で終わる)
                if argIndex + 1 < arguments.count,
                   let count = Int(arguments[argIndex + 1]) {
                    argIndex += 1
                    // 連打は fire-and-forget(1 秒間隔の逐次実行の唯一の例外)。
                    // 撮影は rapidWait が所要時間ぶん遅延を補償する
                    navigationSteps.append { [weak self] in
                        Task { @MainActor in
                            for _ in 0..<max(0, count) {
                                self?.readerWindowController?.toggleThumbnailOverlay()
                                try? await Task.sleep(for: .milliseconds(70))
                            }
                        }
                    }
                }
            case "--then-play-narration":
                // 音声メディアオーバーレイ再生を開始(SMIL 同期ハイライトの検証用)
                navigationSteps.append { [weak self] in
                    self?.readerWindowController?.toggleMediaOverlayMenu(nil)
                }
            case "--then-show-bubble":
                // ページバーのホバーバブル表示(ホバーは再現不能のため)
                if argIndex + 1 < arguments.count,
                   let fraction = Double(arguments[argIndex + 1]) {
                    argIndex += 1
                    navigationSteps.append { [weak self] in
                        self?.readerWindowController?
                            .debugShowPageBarBubble(fraction: fraction)
                    }
                }
            case "--then-goto-percent":
                if argIndex + 1 < arguments.count,
                   let percent = Double(arguments[argIndex + 1]) {
                    argIndex += 1
                    navigationSteps.append { [weak self] in
                        self?.readerWindowController?.performEPUB(
                            .goToPercent, value: percent, leftHalf: nil)
                    }
                }
            default:
                break
            }
            argIndex += 1
        }
        if !navigationSteps.isEmpty {
            Task { @MainActor in
                for step in navigationSteps {
                    try? await Task.sleep(for: .seconds(1))
                    step()
                }
            }
        }
        if arguments.contains("--then-toggle-cover-single") {
            // 検証用: 表示後に「表紙を単ページで表示」を切り替え、現在の
            // 見開きが即座に組み直されることをスナップショットで確認する
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.toggleCoverSingleMenu(nil)
            }
        }
        if arguments.contains("--show-file-info") {
            // 検証用: ファイル情報パネルを開く(--snapshot はパネルを撮る)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.showFileInfo()
            }
        }
        if arguments.contains("--show-opening-progress") {
            // 検証用: オープン進捗 HUD を固定内容で表示(スナップショット撮影)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.debugShowOpeningProgress()
            }
        }
        if arguments.contains("--show-activity") {
            // 検証用: アクティビティ窓を開いて撮る(更新ループが本データを
            // 拾うまで少し早めに開く)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.4))
                self.showActivity(nil)
            }
        }
        if let index = arguments.firstIndex(of: "--zoom"), index + 1 < arguments.count,
           let scale = Double(arguments[index + 1]) {
            // 検証用: 中心を基点に指定倍率へ連続ズームした状態で撮る
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.readerViewForInput
                    .debugSetZoom(CGFloat(scale))
            }
        }
        if let index = arguments.firstIndex(of: "--show-gesture-hud"),
           index + 1 < arguments.count {
            // 検証用: ジェスチャ方向 HUD を表示した状態で撮影する
            // (方向は left|right|up|down。割当名は実際のバインディングを引く)
            let direction = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.debugShowGestureHUD(named: direction)
            }
        }
        if let index = arguments.firstIndex(of: "--show-password-dialog"),
           index + 1 < arguments.count {
            // 検証用: パスワードダイアログ(保存チェックボックス付き)を
            // レイアウトして撮る(runModal せずウインドウ内容を撮影)
            let path = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard let accessory = self.readerWindowController?
                    .debugPasswordAccessory()
                else { NSApp.terminate(nil); return }
                self.writeCachedSnapshot(of: accessory, to: path)
                NSApp.terminate(nil)
            }
        }
        if let index = arguments.firstIndex(of: "--then-open"), index + 1 < arguments.count {
            // 検証用: 最初の本(とサムネイル)を表示した後に別の本へ切り替える
            // (本の切替をまたぐサムネイル一覧の描画確認のため)
            let path = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.readerWindowController?.openBook(at: URL(fileURLWithPath: path))
            }
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            // 多段ナビゲーション指定時は 1 段ごとに 1 秒待ちを足す
            // (ステップは 1 秒間隔で逐次実行されるため、最後のステップの
            // 完了+読み込みの余裕を見て撮影する)
            let navSteps = arguments.filter {
                ["--then-previous-book", "--then-next-book",
                 "--then-next-page", "--then-goto-percent",
                 "--then-show-thumbnails", "--then-show-bubble",
                 "--then-play-narration", "--then-rapid-thumbnails"].contains($0)
            }.count
            // 連打ステップは自分の所要時間(N×70ms)+整定のぶん撮影を遅らせる
            var rapidWait = 0.0
            var scanIndex = 0
            while scanIndex < arguments.count {
                if arguments[scanIndex] == "--then-rapid-thumbnails",
                   scanIndex + 1 < arguments.count,
                   let count = Int(arguments[scanIndex + 1]) {
                    rapidWait += Double(count) * 0.07 + 2
                }
                scanIndex += 1
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2 + Double(navSteps) + rapidWait))
                // 検証用: サムネイル機構の内部状態を stdout へ出力
                // (--dump-thumbnail-stats。欠けセルの原因判別用)
                if arguments.contains("--dump-thumbnail-stats") {
                    let stats = await ThumbnailCache.shared.debugStats()
                    var protectedFlag = "n/a"
                    if let source = self.readerWindowController?.book?.source {
                        protectedFlag = String(await source.containsProtectedContent())
                    }
                    print("[thumbnail-stats] protected=\(protectedFlag)\n\(stats)")
                }
                // アクティビティ窓が開いていれば ImageRenderer で撮る
                // (NSHostingView + ScrollView はヘッドレスの cacheDisplay で
                // テキストが写らないため。FileInfoView と同じ流儀)
                if let monitor = self.activityMonitor {
                    let renderer = ImageRenderer(
                        content: ActivityView(monitor: monitor, embedInScroll: false)
                            .frame(width: 420)
                            .background(Color(nsColor: .windowBackgroundColor)))
                    renderer.scale = 2
                    if let cgImage = renderer.cgImage {
                        try? NSBitmapImageRep(cgImage: cgImage)
                            .representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                    NSApp.terminate(nil)
                    return
                }
                // しおり編集シート/ファイル情報パネルが開いていればそちらを撮る
                // (NSHostingView は反転補正)
                if self.readerWindowController?.isEPUBMode == true {
                    // EPUB モードは WKWebView のため layer.render に写らない。
                    // takeSnapshot 合成(EPUBReaderView.snapshot)で撮る
                    if let image = await self.readerWindowController?.epubDebugSnapshot(),
                       let tiff = image.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                    NSApp.terminate(nil)
                    return
                }
                if let sheet = self.readerWindowController?.bookmarkEditorWindow {
                    self.writeCachedSnapshot(of: sheet.contentView, to: path)
                } else if let details = self.readerWindowController?
                    .fileInfoDebugDetails {
                    // パネルはヘッドレスでは表示パスを通らずレイヤーが空のため、
                    // 内容ビューを ImageRenderer で直接描画する
                    let renderer = ImageRenderer(
                        content: FileInfoContent(details: details)
                            .frame(width: FileInfoView.contentWidth)
                            .background(Color(nsColor: .windowBackgroundColor)))
                    renderer.scale = 2
                    if let cgImage = renderer.cgImage {
                        let rep = NSBitmapImageRep(cgImage: cgImage)
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                } else {
                    self.writeSnapshot(of: self.readerWindowController?.window?.contentView,
                                       to: path)
                }
                NSApp.terminate(nil)
            }
        }
        if let index = arguments.firstIndex(of: "--snapshot-settings"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            showSettings(nil)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // サイドバーの NSVisualEffectView は layer.render に写らないため
                // cacheDisplay ベースで撮る(上下反転補正も不要になる)
                self.writeCachedSnapshot(of: self.settingsWindow?.contentView, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// draw(_:) ベースのビュー(SwiftUI シート等)は cacheDisplay で撮る
    private func writeCachedSnapshot(of targetView: NSView?, to path: String) {
        guard let view = targetView else { return }
        // ヘッドレス実行ではパネルが描画前のことがあるためレイアウトを確定させる
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    private func writeSnapshot(of targetView: NSView?, to path: String, flipped: Bool = false) {
        guard let view = targetView, let layer = view.layer else { return }
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: 2, y: 2)
        if flipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // 検証実行(--open)では AppKit が起動時に引数パスを文書として渡して
        // くることがあり、--at-page 指定なしの open が後追いで発行されて開始
        // ページ指定を上書きしてしまうため、起動直後の分だけ無視する
        // (恒久ガードにすると、その後の Finder からのオープンまで捨ててしまう)
        guard !suppressRelayedDocumentOpens else { return }
        guard let url = urls.first else { return }
        // 起動時のダブルクリック起動では didFinishLaunching(前回の本の
        // 自動オープン)より先に届くことがある。後から前回の本で上書き
        // されないよう記録する(仕様書 §6.1)
        didOpenDocumentAtLaunch = true
        if let controller = readerWindowController {
            controller.openBook(at: url)
        } else {
            // didFinishLaunching より先に届いた場合はウインドウがまだ無い。
            // 落とさず保留し、起動完了時に開く
            pendingLaunchOpenURL = url
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        readerWindowController?.saveStateBeforeTermination()
    }

    /// Dock アイコンクリック等での再オープン(ウインドウを閉じた後の再表示)
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            readerWindowController?.showWindow(nil)
        }
        return true
    }

    // MARK: - Actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            // 自動アップデート設定は起動済み updater 経由で即時反映する。未起動の
            // スナップショット/XCTest では nil を渡し UserDefaults 直読みに委ねる
            let settingsUpdater: SPUUpdater? =
                (AutomatedRun.isSnapshot || AutomatedRun.isXCTest) ? nil : updaterController.updater
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(updater: settingsUpdater)))
            window.title = String(localized: "Settings")
            // システム設定風のサイドバー+詳細構成のためリサイズ可
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 560))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// アクティビティ窓(バックグラウンド処理・メモリの計画と実態)。
    /// 開いている間だけ更新し、閉じたら停止する
    @objc func showActivity(_ sender: Any?) {
        if activityWindow == nil {
            let monitor = ActivityMonitor(controller: readerWindowController)
            activityMonitor = monitor
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: ActivityView(monitor: monitor,
                                       setAlwaysOnTop: { [weak self] on in
                                           self?.activityWindow?.level = on ? .floating : .normal
                                       })))
            window.title = String(localized: "Activity")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 420, height: 560))
            window.center()
            // 位置・サイズを保存(初回だけ中央、以降は AppKit の frame autosave で
            // 復元。リーダー窓と同じ流儀)。保存済みフレームがあれば center を上書き
            window.setFrameAutosaveName("ActivityWindow")
            // 保存済みの「常に最前面」を反映(onAppear でも設定するが初期化時にも)
            window.level = UserDefaults.standard.bool(forKey: "ActivityAlwaysOnTop")
                ? .floating : .normal
            window.delegate = self
            activityWindow = window
        }
        activityMonitor?.start()
        activityWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // アクティビティ窓を閉じたら更新ループを止める(actor への query 停止)
        if (notification.object as? NSWindow) === activityWindow {
            activityMonitor?.stop()
        }
    }

    @objc func openRecentBook(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        readerWindowController?.openBook(at: URL(fileURLWithPath: path))
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder, archive, or PDF to read.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readerWindowController?.openBook(at: url)
    }
}
