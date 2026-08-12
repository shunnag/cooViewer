import AppKit

/// メニューバーをプログラムで構築する。
/// 旧実装の xib 内メニュー(仕様書 §8)に相当するが、識別はローカライズ済み
/// タイトル文字列の比較ではなくセレクタ/タグで行う。
@MainActor
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeEditMenu())
        mainMenu.addItem(makeViewMenu())
        mainMenu.addItem(makeBrowseMenu())
        mainMenu.addItem(makeWindowMenu())
        mainMenu.addItem(makeHelpMenu())
        return mainMenu
    }

    /// 編集メニュー(旧 §8.1 と同じ標準構成。ターゲットは FirstResponder)。
    /// これが無いとパスワード・しおり名・ページ番号などのテキスト欄で
    /// ⌘C/⌘V 等のキーが効かない(キー等価はメニュー経由で配送されるため)
    private static func makeEditMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(withTitle: String(localized: "Undo"),
                     action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: String(localized: "Redo"),
                     action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Cut"),
                     action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: String(localized: "Copy"),
                     action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: String(localized: "Paste"),
                     action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: String(localized: "Delete"),
                     action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Select All"),
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeAppMenu() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "About cooViewer"),
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Check for Updates…"),
                     action: #selector(AppDelegate.checkForUpdates(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"),
                     action: #selector(AppDelegate.showSettings(_:)),
                     keyEquivalent: ",")
        menu.addItem(.separator())
        let servicesItem = menu.addItem(withTitle: String(localized: "Services"),
                                        action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Hide cooViewer"),
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: String(localized: "Hide Others"),
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: String(localized: "Show All"),
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit cooViewer"),
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeFileMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(withTitle: String(localized: "Open…"),
                     action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        let recentItem = menu.addItem(withTitle: String(localized: "Open Recent"),
                                      action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: String(localized: "Open Recent"))
        recentMenu.delegate = RecentBooksMenuDelegate.shared
        recentItem.submenu = recentMenu
        menu.addItem(withTitle: String(localized: "Open the Last Book"),
                     action: #selector(ReaderWindowController.openLastBookMenu(_:)),
                     keyEquivalent: "O")  // ⇧⌘O(旧 §8.1 と同じ)
        menu.addItem(.separator())
        // 現在ページの実体ファイル(単体画像/書庫/PDF)を Finder で選択表示
        menu.addItem(withTitle: String(localized: "Show in Finder"),
                     action: #selector(ReaderWindowController.showInFinderMenu(_:)),
                     keyEquivalent: "R")  // ⇧⌘R
        // Option 押下で現れる代替項目: 見開きのもう一方のページを表示
        let otherPage = menu.addItem(
            withTitle: String(localized: "Show the Other Page in Finder"),
            action: #selector(ReaderWindowController.showOtherPageInFinderMenu(_:)),
            keyEquivalent: "R")
        otherPage.keyEquivalentModifierMask = [.command, .shift, .option]
        otherPage.isAlternate = true
        menu.addItem(withTitle: String(localized: "Show File Info"),
                     action: #selector(ReaderWindowController.showFileInfoMenu(_:)),
                     keyEquivalent: "i")  // ⌘I(Finder の「情報を見る」に合わせる)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close"),
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeViewMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "View"))

        // 表示モード(仕様書 §3.2: ⌘1-4)
        let fitTitles: [(String, Int)] = [
            (String(localized: "Fit to Screen"), 0),
            (String(localized: "Fit to Screen Width"), 1),
            (String(localized: "No Scale"), 2),
            (String(localized: "Fit to Screen Width (divide)"), 3),
        ]
        for (index, (title, tag)) in fitTitles.enumerated() {
            let item = menu.addItem(withTitle: title,
                                    action: #selector(ReaderWindowController.changeFitMode(_:)),
                                    keyEquivalent: "\(index + 1)")
            item.tag = tag
        }
        menu.addItem(.separator())

        // 読み方向(仕様書 §4.4.1)
        let readModeItem = menu.addItem(withTitle: String(localized: "Reading Direction"),
                                        action: nil, keyEquivalent: "")
        let readModeMenu = NSMenu()
        let readTitles: [(String, Int)] = [
            (String(localized: "Right to Left"), 0),
            (String(localized: "Left to Right"), 1),
            (String(localized: "Right to Left (single page)"), 2),
            (String(localized: "Left to Right (single page)"), 3),
        ]
        for (title, tag) in readTitles {
            let item = readModeMenu.addItem(
                withTitle: title,
                action: #selector(ReaderWindowController.changeReadMode(_:)),
                keyEquivalent: "")
            item.tag = tag
        }
        // 表紙(先頭ページ)を単ページで表示(新機能・既定オフ。見開き時のみ効果)
        readModeMenu.addItem(.separator())
        readModeMenu.addItem(
            withTitle: String(localized: "Show the Cover Page Alone"),
            action: #selector(ReaderWindowController.toggleCoverSingleMenu(_:)),
            keyEquivalent: "")
        readModeItem.submenu = readModeMenu

        // 補間=描画品質 5 段階(基礎補間+ML 高画質化の統合。
        // タグは RenderQuality の rawValue。f キーの切替アクションもここから)
        let interpolationItem = menu.addItem(
            withTitle: String(localized: "Interpolation"), action: nil, keyEquivalent: "")
        let interpolationMenu = NSMenu()
        let interpolationTitles: [(String, Int)] = [
            (String(localized: "None"), RenderQuality.none.rawValue),
            (String(localized: "Standard"), RenderQuality.standard.rawValue),
            (String(localized: "High"), RenderQuality.high.rawValue),
            (String(localized: "Very High (ML denoise)"), RenderQuality.mlDenoise.rawValue),
            (String(localized: "Maximum (×4 ML upscale)"), RenderQuality.mlSuperRes.rawValue),
        ]
        for (title, tag) in interpolationTitles {
            let item = interpolationMenu.addItem(
                withTitle: title,
                action: #selector(ReaderWindowController.changeInterpolation(_:)),
                keyEquivalent: "")
            item.tag = tag
        }
        interpolationMenu.addItem(.separator())
        interpolationMenu.addItem(
            withTitle: String(localized: "Toggle Interpolation"),
            action: #selector(ReaderWindowController.toggleInterpolationMenu(_:)),
            keyEquivalent: "")
        interpolationItem.submenu = interpolationMenu

        // ページめくり効果(新機能・既定なし。設定「表示」ペインと同じ値)
        let turnItem = menu.addItem(withTitle: String(localized: "Page Turn Effect"),
                                    action: nil, keyEquivalent: "")
        let turnMenu = NSMenu()
        let turnTitles: [(String, Int)] = [
            (String(localized: "None"), 0),
            (String(localized: "Fade"), 1),
            (String(localized: "Slide"), 2),
            (String(localized: "Zoom Fade"), 3),
            (String(localized: "Page Curl"), 4),
        ]
        for (title, tag) in turnTitles {
            let item = turnMenu.addItem(
                withTitle: title,
                action: #selector(ReaderWindowController.changePageTurnAnimation(_:)),
                keyEquivalent: "")
            item.tag = tag
        }
        turnItem.submenu = turnMenu
        menu.addItem(.separator())
        // 回転のキーは旧 §8.1 と同じ ⌘5/⌘6
        menu.addItem(withTitle: String(localized: "Rotate Left"),
                     action: #selector(ReaderWindowController.rotateLeft(_:)),
                     keyEquivalent: "5")
        menu.addItem(withTitle: String(localized: "Rotate Right"),
                     action: #selector(ReaderWindowController.rotateRight(_:)),
                     keyEquivalent: "6")
        menu.addItem(.separator())
        // ルーペ(旧実装はキーのみ。メニューからも切り替えられるようにする)
        menu.addItem(withTitle: String(localized: "Loupe"),
                     action: #selector(ReaderWindowController.toggleLoupeMenu(_:)),
                     keyEquivalent: "l")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Enter Full Screen"),
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeBrowseMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Browse"))
        menu.addItem(withTitle: String(localized: "Next Page"),
                     action: #selector(ReaderWindowController.nextPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Previous Page"),
                     action: #selector(ReaderWindowController.previousPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Half Page Forward"),
                     action: #selector(ReaderWindowController.halfNextPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Half Page Backward"),
                     action: #selector(ReaderWindowController.halfPreviousPage(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "First Page"),
                     action: #selector(ReaderWindowController.goToFirstPage(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Last Page"),
                     action: #selector(ReaderWindowController.goToLastPage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Add/Remove Bookmark"),
                     action: #selector(ReaderWindowController.addRemoveBookmarkMenu(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Next Bookmark"),
                     action: #selector(ReaderWindowController.nextBookmarkMenu(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Previous Bookmark"),
                     action: #selector(ReaderWindowController.previousBookmarkMenu(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Edit Bookmarks…"),
                     action: #selector(ReaderWindowController.editBookmarksMenu(_:)),
                     keyEquivalent: "")
        let bookmarkListItem = menu.addItem(
            withTitle: String(localized: "Go to Bookmark"), action: nil, keyEquivalent: "")
        let bookmarkListMenu = NSMenu()
        bookmarkListMenu.delegate = BookmarkListMenuDelegate.shared
        bookmarkListItem.submenu = bookmarkListMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Show Thumbnails"),
                     action: #selector(ReaderWindowController.showThumbnailsMenu(_:)),
                     keyEquivalent: "t")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Next Book"),
                     action: #selector(ReaderWindowController.nextBookMenu(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Previous Book"),
                     action: #selector(ReaderWindowController.previousBookMenu(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Slideshow"),
                     action: #selector(ReaderWindowController.toggleSlideshowMenu(_:)),
                     keyEquivalent: "")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeWindowMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(withTitle: String(localized: "Minimize"),
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: String(localized: "Zoom"),
                     action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeHelpMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "Help"))
        menu.addItem(withTitle: String(localized: "cooViewer Help"),
                     action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        NSApp.helpMenu = menu

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
