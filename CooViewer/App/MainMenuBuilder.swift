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
        mainMenu.addItem(makeViewMenu())
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
        menu.addItem(withTitle: String(localized: "Settings…"),
                     action: nil,  // TODO(マイルストーン6): 設定ウインドウ
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
        // TODO(マイルストーン7): Open Recent / 同フォルダの本 / 最後に開いた本
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Close"),
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func makeViewMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "View"))
        // TODO(マイルストーン5): 読み方向・フィット・回転・ページ移動
        menu.addItem(withTitle: String(localized: "Enter Full Screen"),
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")

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
