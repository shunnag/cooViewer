import AppKit
import SwiftUI

/// キー割り当ての編集タブ(仕様書 §5.1-5.5 の KeyArray/Mode2/Mode3 を編集)。
/// 保存は旧互換形式でそのまま UserDefaults へ書き戻し、閲覧側は
/// 設定変更通知で即座にリロードされる。
/// EN: Key-binding editor. Saves straight back in the legacy array format; the
/// EN: reader reloads immediately through the defaults-change notification.
struct KeyBindingsPane: View {
    /// 編集対象: (defaults キー名, 表示名, fitScreenMode 対応)
    /// EN: Editable arrays: (defaults key, tab label), one per fit-screen mode.
    private static let arrays: [(name: String, label: String)] = [
        ("KeyArray", String(localized: "Fit to Screen")),
        ("KeyArrayMode2", String(localized: "Fit to Screen Width")),
        ("KeyArrayMode3", String(localized: "No Scale / Width (divide)")),
    ]

    @State private var arrayIndex = 0
    @State private var bindings: [KeyBinding] = []

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $arrayIndex) {
                ForEach(Self.arrays.indices, id: \.self) { index in
                    Text(Self.arrays[index].label).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            List {
                ForEach(bindings.indices, id: \.self) { index in
                    bindingRow(at: index)
                }
                .onDelete { offsets in
                    bindings.remove(atOffsets: offsets)
                    save()
                }
            }
            // 配列切替時は List を作り直す(行数が減った直後に古い index の行が
            // 再評価されて範囲外参照になるのを防ぐ)
            // EN: rebuild the List when switching arrays so stale rows can't
            // EN: re-evaluate with an out-of-range index.
            .id(arrayIndex)

            HStack(spacing: 12) {
                KeyCaptureField { character, modifiers in
                    // 同じキー+修飾の既存行は置き換える(重複防止)
                    // EN: replace any existing row with the same key+modifiers.
                    bindings.removeAll { $0.key == character && $0.modifiers == modifiers }
                    bindings.append(KeyBinding(
                        legacyActionNumber: 0, key: character,
                        modifiers: modifiers, value: nil, switchAction: false))
                    save()
                }
                .frame(width: 220, height: 24)
                Spacer()
                Button(String(localized: "Reset to Defaults")) {
                    UserDefaults.standard.removeObject(forKey: Self.arrays[arrayIndex].name)
                    load()
                }
            }
            .padding([.horizontal, .bottom], 12)
        }
        .onAppear(perform: load)
        .onChange(of: arrayIndex) { load() }
    }

    @ViewBuilder
    private func bindingRow(at index: Int) -> some View {
        // 削除・配列差し替えの過渡状態でも範囲外参照しない
        // EN: guard against transient out-of-range access during deletes/reloads.
        if bindings.indices.contains(index) {
            bindingRowContent(at: index)
        }
    }

    private func bindingRowContent(at index: Int) -> some View {
        HStack(spacing: 8) {
            Text(ActionNames.displayName(for: bindings[index]))
                .font(.system(.body, design: .monospaced))
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)

            Picker("", selection: actionBinding(at: index)) {
                ForEach(ActionNames.allKeyActionNumbers, id: \.self) { number in
                    Text(ActionNames.keyActionName(number)).tag(number)
                }
            }
            .labelsHidden()

            TextField(String(localized: "Value"), text: valueBinding(at: index))
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .help(String(localized: "Pages / pixels / percent used by some actions."))

            Toggle("", isOn: switchBinding(at: index))
                .toggleStyle(.checkbox)
                .help(String(localized: "Swap with the symmetric action in left-to-right books."))

            Button {
                bindings.remove(at: index)
                save()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 行のバインディング

    private func actionBinding(at index: Int) -> Binding<Int> {
        Binding(
            get: { bindings.indices.contains(index) ? bindings[index].legacyActionNumber : 0 },
            set: { newValue in
                guard bindings.indices.contains(index) else { return }
                bindings[index].legacyActionNumber = newValue
                save()
            })
    }

    private func valueBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard bindings.indices.contains(index),
                      let value = bindings[index].value else { return "" }
                return value == value.rounded()
                    ? String(Int(value)) : String(value)
            },
            set: { newValue in
                guard bindings.indices.contains(index) else { return }
                bindings[index].value = Double(newValue)
                save()
            })
    }

    private func switchBinding(at index: Int) -> Binding<Bool> {
        Binding(
            get: { bindings.indices.contains(index) && bindings[index].switchAction },
            set: { newValue in
                guard bindings.indices.contains(index) else { return }
                bindings[index].switchAction = newValue
                save()
            })
    }

    // MARK: - 読み書き

    private func load() {
        let configuration = BindingConfiguration.load()
        bindings = switch arrayIndex {
        case 1: configuration.keyMode2
        case 2: configuration.keyMode3
        default: configuration.keyNormal
        }
    }

    private func save() {
        BindingConfiguration.saveKeyBindings(
            bindings, arrayName: Self.arrays[arrayIndex].name)
    }
}

/// キーの実押下を捕捉するフィールド(旧 COTextView 相当。仕様書 §3.1)。
/// クリックでフォーカスし、次のキー押下 1 回を修飾込みで通知する。
/// EN: Click-to-focus field that captures the next single key press (with
/// EN: modifiers) and reports it to add a binding.
private struct KeyCaptureField: NSViewRepresentable {
    let onCapture: (Character, Int) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
    }

    final class CaptureView: NSView {
        var onCapture: ((Character, Int) -> Void)?
        private var isCapturing = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            isCapturing = true
            return true
        }

        override func resignFirstResponder() -> Bool {
            isCapturing = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard let character = event.charactersIgnoringModifiers?.first else { return }
            onCapture?(character, LegacyModifier.encode(keyEvent: event))
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let background = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (isCapturing ? NSColor.controlAccentColor.withAlphaComponent(0.2)
                         : NSColor.controlBackgroundColor).setFill()
            background.fill()
            (isCapturing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            background.stroke()

            let text = isCapturing
                ? String(localized: "Press a key to add…")
                : String(localized: "Click here, then press a key")
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2,
                                 width: bounds.width, height: size.height),
                      withAttributes: attributes)
        }
    }
}
