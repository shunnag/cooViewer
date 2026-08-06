import AppKit

@MainActor
final class ReaderWindowController: NSWindowController {
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
        window.contentView = ReaderView()
        window.setFrameAutosaveName("ReaderWindow")
        window.center()
        self.init(window: window)
    }
}
