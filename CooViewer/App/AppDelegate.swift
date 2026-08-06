import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var readerWindowController: ReaderWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ReaderWindowController()
        readerWindowController = controller
        controller.showWindow(nil)
        handleDebugArguments()
    }

    /// 動作検証用の隠し引数(スクリーンショット権限なしで描画結果を確認するため):
    /// --open <path> で本を開き、--snapshot <path> で 2 秒後に contentView を
    /// PNG 出力して終了する。
    private func handleDebugArguments() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count {
            readerWindowController?.openBook(at: URL(fileURLWithPath: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                self.writeSnapshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    private func writeSnapshot(to path: String) {
        guard let view = readerWindowController?.window?.contentView,
              let layer = view.layer else { return }
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        readerWindowController?.openBook(at: url)
    }

    // MARK: - Actions

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
