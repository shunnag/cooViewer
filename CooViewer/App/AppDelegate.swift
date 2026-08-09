import AppKit
import Sparkle
import SwiftUI

/// 自動実行(XCTest / スナップショット検証)の判定。
/// テストホストがユーザーの実データ(最後に開いた本)に触ったり、
/// モーダル(Sparkle 許可・パスワード)で停止したりしないための共通ゲート
/// EN: Detects automated runs (XCTest / snapshot verification) so the app
/// EN: never touches the user's real books or blocks on modals there.
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var readerWindowController: ReaderWindowController?
    private var settingsWindow: NSWindow?
    /// 起動時に文書オープン(Finder ダブルクリック等)を受け取ったか。
    /// 受け取っていたら「前回の本を開く」(§6.1)は行わない
    /// EN: Whether a document open arrived during launch; suppresses the
    /// EN: "reopen last book" path so it cannot clobber the requested book.
    private var didOpenDocumentAtLaunch = false
    /// ウインドウ生成前に届いた文書オープンの保留分(起動完了時に開く)
    /// EN: Document open that arrived before the window existed; opened
    /// EN: once launching finishes.
    private var pendingLaunchOpenURL: URL?
    /// --open 検証実行の起動直後だけ、AppKit が引数パスを文書として中継して
    /// くる分を無視する(起動完了から猶予を置いて解除)
    /// EN: Suppresses AppKit's launch-time argv-relay document opens in
    /// EN: --open verification runs; cleared shortly after launch.
    private var suppressRelayedDocumentOpens = CommandLine.arguments.contains("--open")
    /// 検証用スナップショットの一時ウインドウ(設定ウインドウとは別管理)
    /// EN: Debug-only preview window; must never shadow the settings window.
    private var debugPreviewWindow: NSWindow?

    /// Sparkle の自動更新(設計書 §配布)。フィード URL と EdDSA 公開鍵は
    /// Info.plist(SUFeedURL / SUPublicEDKey)。初回は Sparkle 標準の
    /// 許可ダイアログでユーザーが自動チェックを選ぶ。検証用スナップショット
    /// 実行(--snapshot)と XCTest 実行では、許可ダイアログ(モーダル)が
    /// 写り込み・ハングの原因になるため起動しない
    /// EN: Sparkle auto-update; feed URL and EdDSA key live in Info.plist,
    /// EN: and Sparkle's standard permission prompt governs automatic checks.
    /// EN: Snapshot and XCTest runs keep the updater stopped — its modal
    /// EN: permission prompt would pollute snapshots and hang test runs.
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: !AutomatedRun.isSnapshot && !AutomatedRun.isXCTest,
        updaterDelegate: nil, userDriverDelegate: nil)

    /// メニュー「アップデートを確認…」(MainMenuBuilder から使用)
    /// EN: Menu action for "Check for Updates…".
    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        SettingsStore.shared.registerDefaults()
        // 旧形式の本の状態(BookSettings/RecentItems/LastPages)を v2 へ
        // 一括インポート(初回のみ。旧キーは 1.x 用に凍結保持)
        // EN: One-time import of legacy book state into the v2 store.
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
            // EN: Commit the document open deferred from before launch.
            pendingLaunchOpenURL = nil
            controller.openBook(at: pending)
        } else {
            handleDebugArguments()
        }
        if suppressRelayedDocumentOpens {
            // AppKit の引数中継は起動シーケンス内で届く。猶予を置いて解除し、
            // 以後の(本物の)文書オープンは通常どおり受け付ける
            // EN: The argv relay arrives within the launch sequence; lift the
            // EN: suppression after a grace period.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.suppressRelayedDocumentOpens = false
            }
        }
    }

    /// 起動時のキャッシュ掃除: 生存していないプロセスのスプール残骸
    /// (仕様書 §4.17 の temp 残り問題への対策)と古いサムネイルを回収する。
    /// EN: Startup cleanup: delete spool leftovers of dead processes and trim
    /// EN: thumbnails older than the configured retention.
    private func cleanUpCaches() {
        Task.detached(priority: .utility) {
            // 旧 PNG サムネイルキャッシュは丸ごと削除(v2 HEIC で作り直す)
            // EN: Drop the legacy PNG thumbnail cache; v2 rebuilds as HEIC.
            ThumbnailCache.removeLegacyCacheDirectory()
            let root = ArchiveSource.spoolRoot()
            if let children = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) {
                for child in children {
                    let pid = child.lastPathComponent.split(separator: "-").first
                        .flatMap { Int32($0) }
                    // EN: keep directories owned by still-running processes.
                    if let pid, kill(pid, 0) == 0 { continue }  // 生存プロセスの分は残す
                    try? FileManager.default.removeItem(at: child)
                }
            }
            await ThumbnailCache.shared.trimDiskCache(
                olderThanDays: SettingsStore.shared.thumbnailCacheDays)
        }
    }

    /// 動作検証用の隠し引数(スクリーンショット権限なしで描画結果を確認するため):
    /// --open <path> で本を開き、--snapshot <path> で 2 秒後に contentView を
    /// PNG 出力して終了する。
    /// EN: Hidden verification flags (--open / --snapshot / --show-thumbnails /
    /// EN: --show-bookmark-editor / --snapshot-settings) used to check rendering
    /// EN: without screen-recording permission.
    private func handleDebugArguments() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count {
            // --at-page <1 始まり> で開始ページも指定できる(検証用)
            // EN: Optional --at-page <1-based> picks the starting page.
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
            // EN: reopen the most recent book on launch (OpenLastFolder, default
            // EN: on) — but never as an XCTest host, which must not touch the
            // EN: user's real books, pollute history, or block on modals.
            readerWindowController?.openBook(at: URL(fileURLWithPath: recent.path))
        }
        if arguments.contains("--show-thumbnails") {
            // 本のロード完了を待ってからサムネイルオーバーレイを開く
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.showThumbnail()
            }
        }
        if arguments.contains("--show-bookmark-editor") {
            // 検証用: シートではなく通常ウインドウで表示する(シートの
            // NSHostingView は layer.render/cacheDisplay のどちらでも写らないため)
            // EN: preview in a plain window; sheet-hosted SwiftUI content does not
            // EN: render into offline snapshots.
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
        if arguments.contains("--then-previous-book") || arguments.contains("--then-next-book") {
            // 検証用: 最初の本を表示した後に前/次の本へ移動する(Ctrl+D 相当。
            // 階層ナビゲーションのスナップショット検証のため)
            // EN: Verification flags driving previous/next-book navigation.
            let forward = arguments.contains("--then-next-book")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.readerWindowController?.openAdjacentBook(forward: forward)
            }
        }
        if let index = arguments.firstIndex(of: "--then-open"), index + 1 < arguments.count {
            // 検証用: 最初の本(とサムネイル)を表示した後に別の本へ切り替える
            // (本の切替をまたぐサムネイル一覧の描画確認のため)
            // EN: Verification flag: switch to a second book after the first one
            // EN: (and its thumbnail overlay) is up, to check cross-book rendering.
            let path = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.readerWindowController?.openBook(at: URL(fileURLWithPath: path))
            }
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // しおり編集シートが開いていればそちらを撮る(NSHostingView は反転補正)
                // EN: capture the bookmark sheet when open, else the reader view.
                if let sheet = self.readerWindowController?.bookmarkEditorWindow {
                    self.writeCachedSnapshot(of: sheet.contentView, to: path)
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
                // NSHostingView 配下は layer.render で上下反転するため補正する
                // EN: layer.render draws NSHostingView trees upside down; compensate.
                self.writeSnapshot(of: self.settingsWindow?.contentView, to: path,
                                   flipped: true)
                NSApp.terminate(nil)
            }
        }
    }

    /// draw(_:) ベースのビュー(SwiftUI シート等)は cacheDisplay で撮る
    /// EN: cacheDisplay-based capture for views that draw via draw(_:).
    private func writeCachedSnapshot(of targetView: NSView?, to path: String) {
        guard let view = targetView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    /// EN: Renders a view's layer tree into a 2x PNG (no screen recording needed).
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
        // EN: At launch AppKit may relay argument paths as document opens,
        // EN: which would re-open the book without --at-page. Suppress only
        // EN: the launch window — a permanent guard would also swallow later
        // EN: genuine Finder opens sent to the running instance.
        guard !suppressRelayedDocumentOpens else { return }
        guard let url = urls.first else { return }
        // 起動時のダブルクリック起動では didFinishLaunching(前回の本の
        // 自動オープン)より先に届くことがある。後から前回の本で上書き
        // されないよう記録する(仕様書 §6.1)
        // EN: Launch-by-document can arrive before didFinishLaunching; record
        // EN: it so the "reopen last book" path does not clobber this open.
        didOpenDocumentAtLaunch = true
        if let controller = readerWindowController {
            controller.openBook(at: url)
        } else {
            // didFinishLaunching より先に届いた場合はウインドウがまだ無い。
            // 落とさず保留し、起動完了時に開く
            // EN: Arrived before the window exists; defer instead of dropping.
            pendingLaunchOpenURL = url
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        readerWindowController?.saveStateBeforeTermination()
    }

    /// Dock アイコンクリック等での再オープン(ウインドウを閉じた後の再表示)
    /// EN: Re-show the reader window when the Dock icon is clicked after close.
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
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView()))
            window.title = String(localized: "Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
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
