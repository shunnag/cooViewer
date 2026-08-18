import AppKit
import SwiftUI

/// キー割り当ての編集ペイン(仕様書 §5.1-5.5 の KeyArray/Mode2/Mode3)。
/// 「できること別」方式: 機能をカテゴリごとに列挙し、各行にキーを割り当てる
/// (マウスとジェスチャのペインと同型)。キーの追加は実押下の捕捉で行う。
/// 永続スキーマ(§13.2)と解決順(§5.3 モード固有→基本)は不変。
struct KeyBindingsPane: View {
    private enum Slot: Int, CaseIterable {
        case normal, mode2, mode3
        var arrayName: String {
            switch self {
            case .normal: "KeyArray"
            case .mode2: "KeyArrayMode2"
            case .mode3: "KeyArrayMode3"
            }
        }
    }

    private struct AddTarget: Identifiable {
        let id: Int
    }

    @State private var normal: [KeyBinding] = []
    @State private var mode2: [KeyBinding] = []
    @State private var mode3: [KeyBinding] = []
    @State private var overrideSlot: Slot = .mode2
    @State private var addTarget: AddTarget?
    @State private var showsOverrideAdd = false
    @State private var confirmsBaseReset = false
    @State private var confirmsOverrideReset = false

    var body: some View {
        Form {
            ForEach(ActionNames.keyActionCategories.indices, id: \.self) { index in
                let category = ActionNames.keyActionCategories[index]
                Section {
                    ForEach(category.numbers, id: \.self) { action in
                        actionRow(action)
                    }
                } header: {
                    Text(category.title)
                } footer: {
                    if index == 0 {
                        Text(String(localized: "“+” captures a key press. Choosing a key that’s in use moves it here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                DisclosureGroup(String(localized: "Per-view-mode overrides (advanced)")) {
                    overrideEditor
                }
            }

            Section {
                Button(String(localized: "Reset base settings…")) { confirmsBaseReset = true }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .sheet(item: $addTarget) { target in
            AddKeyInputSheet(fixedAction: target.id, existing: normal) { binding in
                upsert(binding, into: .normal)
            }
        }
        .sheet(isPresented: $showsOverrideAdd) {
            AddKeyInputSheet(fixedAction: nil, existing: array(for: overrideSlot)) { binding in
                upsert(binding, into: overrideSlot)
            }
        }
        .alert(String(localized: "Reset the base key settings to defaults?"),
               isPresented: $confirmsBaseReset) {
            Button(String(localized: "Reset"), role: .destructive) {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: Slot.normal.arrayName)
                defaults.removeObject(forKey: "KeyArrayUserEdited")
                load()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Per-view-mode overrides are kept."))
        }
        .alert(String(localized: "Reset this mode’s overrides to defaults?"),
               isPresented: $confirmsOverrideReset) {
            Button(String(localized: "Reset"), role: .destructive) {
                UserDefaults.standard.removeObject(forKey: overrideSlot.arrayName)
                load()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "The base settings are not changed."))
        }
    }

    /// 同じキー+修飾の既存行を置き換えて追加する(=付け替え)
    private func upsert(_ binding: KeyBinding, into slot: Slot) {
        var array = array(for: slot)
        array.removeAll { $0.key == binding.key && $0.modifiers == binding.modifiers }
        array.append(binding)
        setArray(array, for: slot)
    }

    // MARK: - できること別の行

    /// 機能 1 つ分。Form の Section+ForEach では 1 要素=複数ビューの行が
    /// 丸ごと消える描画不具合があるため、必ず単一の VStack にまとめる
    /// (MouseBindingsPane と同じ回避策)
    private func actionRow(_ action: Int) -> some View {
        let indices = KeyBindingCatalog.assignmentIndices(for: action, in: normal)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ActionNames.keyActionName(action))
                Spacer(minLength: 16)
                TrailingFlowLayout(spacing: 6) {
                    ForEach(indices, id: \.self) { index in
                        assignmentChip(at: index, action: action)
                    }
                    Button {
                        addTarget = AddTarget(id: action)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Add a key for this action"))
                }
            }
            // %ジャンプ(39)はキーごとに値が異なるため機能単位の一括編集はしない
            if action != 39, !indices.isEmpty,
               let unit = ActionNames.keyValueUnit(action) {
                HStack(spacing: 6) {
                    Text(String(localized: "Amount:"))
                        .font(.callout)
                    TextField("", text: valueBinding(forAction: action),
                              prompt: Text(unit.defaultValue))
                        .labelsHidden()
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text(unit.unit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Leave blank to use the default."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 16)
            }
        }
    }

    /// 割当済みキーのチップ。クリックで入替トグル・%ジャンプの値・削除
    private func assignmentChip(at index: Int, action: Int) -> some View {
        Menu {
            if ActionNames.keySwitchActionEligible.contains(action) {
                Toggle(String(localized: "Swap forward/backward in left-to-right books"),
                       isOn: switchBinding(at: index, in: .normal))
            }
            if action == 39 {
                Picker(String(localized: "Percent"),
                       selection: percentBinding(at: index)) {
                    ForEach(0...10, id: \.self) { step in
                        Text("\(step * 10)%").tag(Double(step * 10))
                    }
                }
            }
            Button(role: .destructive) {
                var array = normal
                guard array.indices.contains(index) else { return }
                array.remove(at: index)
                setArray(array, for: .normal)
            } label: {
                Text(String(localized: "Remove this assignment"))
            }
        } label: {
            Text(chipLabel(at: index, action: action))
                .font(.callout)
        }
        .fixedSize()
    }

    private func chipLabel(at index: Int, action: Int) -> String {
        guard normal.indices.contains(index) else { return "" }
        let binding = normal[index]
        var label = ActionNames.displayName(for: binding)
        if action == 39, let value = binding.value, let percent = value.safeInt {
            label += " → \(percent)%"
        }
        return label
    }

    private func percentBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: {
                normal.indices.contains(index) ? (normal[index].value ?? 0) : 0
            },
            set: { newValue in
                var array = normal
                guard array.indices.contains(index) else { return }
                array[index].value = newValue
                setArray(array, for: .normal)
            })
    }

    private func valueBinding(forAction action: Int) -> Binding<String> {
        Binding(
            get: {
                let indices = KeyBindingCatalog.assignmentIndices(for: action, in: normal)
                guard let first = indices.first, let value = normal[first].value else {
                    return ""
                }
                if value == value.rounded(), let intValue = value.safeInt {
                    return String(intValue)
                }
                return String(value)
            },
            set: { newValue in
                var array = normal
                KeyBindingCatalog.setValue(Double(newValue), forAction: action, in: &array)
                setArray(array, for: .normal)
            })
    }

    // MARK: - 表示モードごとの上書き(上級)

    private var overrideEditor: some View {
        Group {
            Text(String(localized: "Use this to change behavior only in a specific view mode. Inputs not overridden here use the base settings above. Fit to Screen always uses the base settings."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $overrideSlot) {
                Text(String(localized: "Fit to Screen Width")).tag(Slot.mode2)
                Text(String(localized: "No Scale / Width (divide)")).tag(Slot.mode3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let overrides = array(for: overrideSlot)
            if !overrides.isEmpty {
                Text(String(localized: "This mode’s assignments"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(overrides.indices, id: \.self) { index in
                    overrideRow(at: index)
                }
            }
            Text(String(localized: "Keys not listed here follow the base settings."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(String(localized: "Add a key…")) { showsOverrideAdd = true }
            Button(String(localized: "Reset this mode’s overrides…")) {
                confirmsOverrideReset = true
            }
        }
    }

    /// 上書きセットの行(キー表記+動作ポップアップ+削除。単一 VStack)
    @ViewBuilder
    private func overrideRow(at index: Int) -> some View {
        let overrides = array(for: overrideSlot)
        if overrides.indices.contains(index) {
            let binding = overrides[index]
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker(ActionNames.displayName(for: binding),
                           selection: actionBinding(at: index, in: overrideSlot)) {
                        ForEach(ActionNames.allKeyActionNumbers, id: \.self) { number in
                            Text(ActionNames.keyActionName(number)).tag(number)
                        }
                    }
                    Button {
                        var updated = overrides
                        updated.remove(at: index)
                        setArray(updated, for: overrideSlot)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Remove this assignment"))
                }
                if let unit = ActionNames.keyValueUnit(binding.legacyActionNumber) {
                    HStack(spacing: 6) {
                        Text(String(localized: "Amount:"))
                            .font(.callout)
                        TextField("", text: rowValueBinding(at: index, in: overrideSlot),
                                  prompt: Text(unit.defaultValue))
                            .labelsHidden()
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Text(unit.unit)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 16)
                }
                if ActionNames.keySwitchActionEligible
                    .contains(binding.legacyActionNumber) {
                    Toggle(String(localized: "Swap forward/backward in left-to-right books"),
                           isOn: switchBinding(at: index, in: overrideSlot))
                        .font(.callout)
                        .padding(.leading, 16)
                }
            }
        }
    }

    private func actionBinding(at index: Int, in slot: Slot) -> Binding<Int> {
        Binding(
            get: {
                let array = array(for: slot)
                return array.indices.contains(index) ? array[index].legacyActionNumber : 0
            },
            set: { newValue in
                var array = array(for: slot)
                guard array.indices.contains(index) else { return }
                array[index].legacyActionNumber = newValue
                if !ActionNames.keySwitchActionEligible.contains(newValue) {
                    array[index].switchAction = false
                }
                setArray(array, for: slot)
            })
    }

    private func rowValueBinding(at index: Int, in slot: Slot) -> Binding<String> {
        Binding(
            get: {
                let array = array(for: slot)
                guard array.indices.contains(index), let value = array[index].value else {
                    return ""
                }
                if value == value.rounded(), let intValue = value.safeInt {
                    return String(intValue)
                }
                return String(value)
            },
            set: { newValue in
                var array = array(for: slot)
                guard array.indices.contains(index) else { return }
                array[index].value = Double(newValue)
                setArray(array, for: slot)
            })
    }

    private func switchBinding(at index: Int, in slot: Slot) -> Binding<Bool> {
        Binding(
            get: {
                let array = array(for: slot)
                return array.indices.contains(index) && array[index].switchAction
            },
            set: { newValue in
                var array = array(for: slot)
                guard array.indices.contains(index) else { return }
                array[index].switchAction = newValue
                setArray(array, for: slot)
            })
    }

    // MARK: - 読み書き

    private func array(for slot: Slot) -> [KeyBinding] {
        switch slot {
        case .normal: normal
        case .mode2: mode2
        case .mode3: mode3
        }
    }

    private func setArray(_ value: [KeyBinding], for slot: Slot) {
        switch slot {
        case .normal: normal = value
        case .mode2: mode2 = value
        case .mode3: mode3 = value
        }
        BindingConfiguration.saveKeyBindings(value, arrayName: slot.arrayName)
    }

    private func load() {
        let configuration = BindingConfiguration.load()
        normal = configuration.keyNormal
        mode2 = configuration.keyMode2
        mode3 = configuration.keyMode3
    }
}

/// 「キーを追加」シート: 実押下を捕捉し、使用中のキーなら付け替えを予告する。
/// fixedAction=nil のとき(表示モード上書き用)は動作も選ぶ
private struct AddKeyInputSheet: View {
    let fixedAction: Int?
    let existing: [KeyBinding]
    let onAdd: (KeyBinding) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var captured: KeyBinding?
    @State private var action = 0

    /// 捕捉済みキーが既に別の機能へ割り当てられていれば、その機能名
    private var conflictActionName: String? {
        guard let captured,
              let index = KeyBindingCatalog.index(ofKey: captured.key,
                                                  modifiers: captured.modifiers,
                                                  in: existing) else { return nil }
        let current = existing[index].legacyActionNumber
        guard current != (fixedAction ?? action) else { return nil }
        return ActionNames.keyActionName(current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(fixedAction.map {
                String(localized: "Add a key for “\(ActionNames.keyActionName($0))”")
            } ?? String(localized: "Add a key…"))
                .font(.headline)
            KeyCaptureField { key, modifiers in
                captured = KeyBinding(legacyActionNumber: fixedAction ?? action,
                                      key: key, modifiers: modifiers,
                                      value: nil, switchAction: false)
            }
            .frame(width: 320, height: 26)
            if let captured {
                Text(ActionNames.displayName(for: captured))
                    .font(.system(.body, design: .monospaced))
            }
            if fixedAction == nil {
                Picker(String(localized: "Action:"), selection: $action) {
                    ForEach(ActionNames.allKeyActionNumbers, id: \.self) { number in
                        Text(ActionNames.keyActionName(number)).tag(number)
                    }
                }
            }
            if let conflictActionName {
                Text(String(localized: "This key is currently assigned to “\(conflictActionName)” and will be moved here."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Add")) {
                    guard var captured else { return }
                    captured.legacyActionNumber = fixedAction ?? action
                    onAdd(captured)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(captured == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }
}

/// キーの実押下を捕捉するフィールド(旧 COTextView 相当。仕様書 §3.1)。
/// クリックでフォーカスし、次のキー押下 1 回を修飾込みで通知する。
struct KeyCaptureField: NSViewRepresentable {
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
