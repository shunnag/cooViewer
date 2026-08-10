import AppKit

/// メニューバーをプログラムで構築する。
/// 旧実装の xib 内メニュー(仕様書 §8)に相当するが、識別はローカライズ済み
/// タイトル文字列の比較ではなくセレクタ/タグで行う。
/// EN: Builds the menu bar in code. Items are identified by selector/tag,
/// EN: never by comparing localized titles (a legacy fragility).
@MainActor
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeViewMenu())
        mainMenu.addItem(makeBrowseMenu())
        mainMenu.addItem(makeWindowMenu())
        mainMenu.addItem(makeHelpMenu())
        return mainMenu
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
                     keyEquivalent: "")
        menu.addItem(.separator())
        // 現在ページの実体ファイル(単体画像/書庫/PDF)を Finder で選択表示
        // EN: Reveal the page's on-disk file in the Finder.
        menu.addItem(withTitle: String(localized: "Show in Finder"),
                     action: #selector(ReaderWindowController.showInFinderMenu(_:)),
                     keyEquivalent: "R")  // ⇧⌘R
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
        // EN: fit modes, bound to Cmd-1...4.
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
        // EN: reading direction submenu.
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
        readModeItem.submenu = readModeMenu

        // 補間(なし/低/既定/高。f キーの切替アクションもここから)
        // EN: interpolation modes plus the toggle used by the default f key.
        let interpolationItem = menu.addItem(
            withTitle: String(localized: "Interpolation"), action: nil, keyEquivalent: "")
        let interpolationMenu = NSMenu()
        let interpolationTitles: [(String, Int)] = [
            (String(localized: "Default"), 0),
            (String(localized: "None"), 1),
            (String(localized: "Low"), 2),
            (String(localized: "High"), 3),
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
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Rotate Left"),
                     action: #selector(ReaderWindowController.rotateLeft(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Rotate Right"),
                     action: #selector(ReaderWindowController.rotateRight(_:)), keyEquivalent: "")
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
