import AppKit

/// Washi の脚注本文を選択可能なネイティブ文字ビューで表示する。
/// cooViewer-oxr.32 / 設計書 §2.4。
@MainActor
final class EPUBFootnotePopoverController: NSViewController {
    private let noteTitle: String
    private let noteText: String
    private let onMove: @MainActor () -> Void

    init(title: String, text: String, onMove: @escaping @MainActor () -> Void) {
        self.noteTitle = title
        self.noteText = text
        self.onMove = onMove
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 360, height: 240)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))

        let title = NSTextField(labelWithString: noteTitle)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.string = noteText
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: NSFont.systemFontSize)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
        }

        let moveButton = NSButton(
            title: String(localized: "Move"), target: self,
            action: #selector(moveToNote(_:)))
        moveButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [NSView(), moveButton])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [title, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    @objc private func moveToNote(_ sender: Any?) {
        onMove()
    }
}
