import SwiftUI

/// マウス・ジェスチャ割り当ての編集ペイン(仕様書 §5.1-5.7 の MouseArray/Mode2/Mode3)。
/// 「できること別」方式: 機能(アクション)をカテゴリごとに列挙し、各行で
/// それを起動する入力(クリック/ドラッグ/ジェスチャ)を割り当てる —
/// macOS のキーボードショートカット設定と同じ向き。1 機能に複数の入力を
/// 割り当てられ、他の機能で使用中の入力を選ぶと付け替えになる。
/// 永続スキーマ(§13.2)と解決順(§5.3 モード固有→基本)は不変で、
/// UI の写像(MouseBindingCatalog)だけがトリガ⇄アクションを行き来する。
struct MouseBindingsPane: View {
    /// 編集対象の配列(defaults キーと対応)
    private enum Slot: Int, CaseIterable {
        case normal, mode2, mode3
        var arrayName: String {
            switch self {
            case .normal: "MouseArray"
            case .mode2: "MouseArrayMode2"
            case .mode3: "MouseArrayMode3"
            }
        }
    }

    /// 追加シートの対象アクション(sheet(item:) 用)
    private struct AddTarget: Identifiable {
        let id: Int
    }

    @State private var normal: [MouseBinding] = []
    @State private var mode2: [MouseBinding] = []
    @State private var mode3: [MouseBinding] = []
    @State private var overrideSlot: Slot = .mode2
    @State private var addTarget: AddTarget?
    @State private var confirmsBaseReset = false
    @State private var confirmsOverrideReset = false

    var body: some View {
        Form {
            ForEach(ActionNames.mouseActionCategories.indices, id: \.self) { index in
                let category = ActionNames.mouseActionCategories[index]
                Section {
                    ForEach(category.numbers, id: \.self) { action in
                        actionRow(action)
                    }
                } header: {
                    Text(category.title)
                } footer: {
                    if index == 0 {
                        Text(String(localized: "Actions marked “(by side)” decide forward/back by which half of the view you use. “+” adds an input; choosing one that’s in use moves it here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                DisclosureGroup(String(localized: "Per-view-mode overrides (advanced)")) {
                    overrideEditor
                }
            } footer: {
                Text(String(localized: "Trackpad feature toggles (swipe to turn pages, smart zoom, quick loupe) are in “Control”."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(String(localized: "Reset base settings…")) { confirmsBaseReset = true }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .sheet(item: $addTarget) { target in
            AddMouseInputSheet(action: target.id, existing: normal) { binding in
                var array = normal
                // 同じ入力の既存行は置き換える=他の機能からの付け替え
                array.removeAll {
                    $0.button == binding.button && $0.modifiers == binding.modifiers
                }
                array.append(binding)
                setArray(array, for: .normal)
            }
        }
        .alert(String(localized: "Reset the base mouse settings to defaults?"),
               isPresented: $confirmsBaseReset) {
            Button(String(localized: "Reset"), role: .destructive) {
                let defaults = UserDefaults.standard
                defaults.removeObject(forKey: Slot.normal.arrayName)
                defaults.removeObject(forKey: "MouseArrayUserEdited")
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

    // MARK: - できること別の行

    /// 機能 1 つ分: 名前+割当チップ列+追加ボタン(+必要時のみ数値行)。
    /// Form の Section+ForEach では 1 要素=複数ビューの行が丸ごと消える
    /// 描画不具合に当たったため、必ず単一の VStack にまとめる
    private func actionRow(_ action: Int) -> some View {
        let indices = MouseBindingCatalog.assignmentIndices(for: action, in: normal)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ActionNames.mouseActionName(action))
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
                    .help(String(localized: "Add an input for this action"))
                }
            }
            if !indices.isEmpty, let unit = ActionNames.mouseValueUnit(action) {
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

    /// 割当済み入力のチップ。クリックで入替トグル(対象アクションのみ)と削除
    private func assignmentChip(at index: Int, action: Int) -> some View {
        Menu {
            if ActionNames.mouseSwitchActionEligible.contains(action) {
                Toggle(String(localized: "Swap forward/backward in left-to-right books"),
                       isOn: switchBinding(at: index, in: .normal))
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
            let binding = normal.indices.contains(index) ? normal[index] : nil
            Text(binding.map {
                ActionNames.mouseTriggerName(button: $0.button, modifiers: $0.modifiers)
            } ?? "")
            .font(.callout)
        }
        .fixedSize()
    }

    /// 数値は機能単位で編集し全割当行へ適用(仕様書のスキーマは行ごとだが、
    /// 入力ごとに別の量を持たせる意味はないため)
    private func valueBinding(forAction action: Int) -> Binding<String> {
        Binding(
            get: {
                let indices = MouseBindingCatalog.assignmentIndices(for: action, in: normal)
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
                MouseBindingCatalog.setValue(Double(newValue), forAction: action,
                                             in: &array)
                setArray(array, for: .normal)
            })
    }

    // MARK: - 表示モードごとの上書き(トリガ中心のまま。上級向け)

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

            Text(String(localized: "Inherited from base"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(MouseBindingCatalog.inheritedButtons(override: overrides),
                    id: \.self) { button in
                inheritedRow(button: button)
            }

            Button(String(localized: "Reset this mode’s overrides…")) {
                confirmsOverrideReset = true
            }
        }
    }

    /// 上書きセットの行(トリガ名+動作ポップアップ+削除)
    @ViewBuilder
    private func overrideRow(at index: Int) -> some View {
        let overrides = array(for: overrideSlot)
        if overrides.indices.contains(index) {
            let binding = overrides[index]
            HStack(spacing: 8) {
                Picker(ActionNames.mouseTriggerName(button: binding.button,
                                                    modifiers: binding.modifiers),
                       selection: actionBinding(at: index, in: overrideSlot)) {
                    ForEach(ActionNames.allMouseActionNumbers, id: \.self) { number in
                        Text(ActionNames.mouseActionName(number)).tag(number)
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
            if ActionNames.mouseValueUnit(binding.legacyActionNumber) != nil {
                overrideValueRow(at: index)
            }
            if ActionNames.mouseSwitchActionEligible.contains(binding.legacyActionNumber) {
                Toggle(String(localized: "Swap forward/backward in left-to-right books"),
                       isOn: switchBinding(at: index, in: overrideSlot))
                    .font(.callout)
                    .padding(.leading, 16)
            }
        }
    }

    private func overrideValueRow(at index: Int) -> some View {
        let action = array(for: overrideSlot)[index].legacyActionNumber
        let unit = ActionNames.mouseValueUnit(action)
        return HStack(spacing: 6) {
            Text(String(localized: "Amount:"))
                .font(.callout)
            TextField("", text: rowValueBinding(at: index, in: overrideSlot),
                      prompt: Text(unit?.defaultValue ?? ""))
                .labelsHidden()
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
            Text(unit?.unit ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 16)
    }

    /// 継承行: 「基本設定のとおり(現在: X)」を選ぶと上書き行が消え、
    /// 具体アクションを選ぶとその場で上書き行が生まれる(解決順の可視化)
    private func inheritedRow(button: Int) -> some View {
        let baseName = MouseBindingCatalog.index(of: button, in: normal)
            .map { ActionNames.mouseActionName(normal[$0].legacyActionNumber) }
            ?? String(localized: "None")
        let selection = Binding<Int>(
            get: { -1 },
            set: { newValue in
                guard newValue != -1 else { return }
                var array = array(for: overrideSlot)
                MouseBindingCatalog.assign(&array, button: button, action: newValue)
                setArray(array, for: overrideSlot)
            })
        return Picker(ActionNames.catalogTriggerName(button: button), selection: selection) {
            Text(String(localized: "Follows the base setting (currently: \(baseName))")).tag(-1)
            ForEach(ActionNames.allMouseActionNumbers, id: \.self) { number in
                Text(ActionNames.mouseActionName(number)).tag(number)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 行のバインディング

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
                if !ActionNames.mouseSwitchActionEligible.contains(newValue) {
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

    private func array(for slot: Slot) -> [MouseBinding] {
        switch slot {
        case .normal: normal
        case .mode2: mode2
        case .mode3: mode3
        }
    }

    private func setArray(_ value: [MouseBinding], for slot: Slot) {
        switch slot {
        case .normal: normal = value
        case .mode2: mode2 = value
        case .mode3: mode3 = value
        }
        BindingConfiguration.saveMouseBindings(value, arrayName: slot.arrayName)
    }

    private func load() {
        let configuration = BindingConfiguration.load()
        normal = configuration.mouseNormal
        mode2 = configuration.mouseMode2
        mode3 = configuration.mouseMode3
    }
}

/// 「入力を追加」シート: 対象の機能は固定で、入力(操作の種類+ボタン+
/// 修飾キー)だけを選ぶ。他の機能で使用中の入力を選ぶと付け替えになる旨を
/// その場で表示する
private struct AddMouseInputSheet: View {
    /// トリガ種別。クリック/ドラッグ 5 種は実ボタンと組み、マルチタッチは
    /// 仮想ボタン(1000-8000)へ写像する(仕様書 §5.1-5.2)
    // ピンチ(pinchIn/pinchOut)は常に連続ズームに固定で、バインディングとして
    // は発火しないためトリガの選択肢に含めない(設計書 §2.4 連続ピンチズーム)
    enum TriggerKind: Int, CaseIterable, Identifiable {
        case click, drag, dragLeft, dragRight, dragUp, dragDown
        case swipeRight, swipeLeft, swipeUp, swipeDown
        case rotateRight, rotateLeft

        var id: Int { rawValue }
        var usesButton: Bool { rawValue <= TriggerKind.dragDown.rawValue }

        var kindModifier: Int {
            switch self {
            case .click: 0
            case .drag: LegacyModifier.drag
            case .dragLeft: LegacyModifier.dragLeft
            case .dragRight: LegacyModifier.dragRight
            case .dragUp: LegacyModifier.dragUp
            case .dragDown: LegacyModifier.dragDown
            default: 0
            }
        }

        var virtualButton: Int? {
            switch self {
            case .swipeRight: VirtualButton.swipeRight
            case .swipeLeft: VirtualButton.swipeLeft
            case .swipeUp: VirtualButton.swipeUp
            case .swipeDown: VirtualButton.swipeDown
            case .rotateRight: VirtualButton.rotateRight
            case .rotateLeft: VirtualButton.rotateLeft
            default: nil
            }
        }

        var label: String {
            switch self {
            case .click: String(localized: "Click")
            case .drag: String(localized: "Drag (any direction)")
            case .dragLeft: String(localized: "Drag Left")
            case .dragRight: String(localized: "Drag Right")
            case .dragUp: String(localized: "Drag Up")
            case .dragDown: String(localized: "Drag Down")
            default: ActionNames.mouseTriggerBaseName(
                button: virtualButton ?? 0, kindModifier: 0)
            }
        }
    }

    let action: Int
    let existing: [MouseBinding]
    let onAdd: (MouseBinding) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind: TriggerKind = .click
    @State private var button = 0
    @State private var withShift = false
    @State private var withOption = false
    @State private var withControl = false

    /// 現在の選択が組み立てるトリガ
    private var selectedTrigger: (button: Int, modifiers: Int) {
        let flags = (withShift ? LegacyModifier.shift : 0)
            + (withOption ? LegacyModifier.option : 0)
            + (withControl ? LegacyModifier.control : 0)
        return (kind.virtualButton ?? button, kind.kindModifier + flags)
    }

    /// 選択中の入力が既に割り当てられている別の機能(あれば付け替え予告)
    private var conflictActionName: String? {
        let trigger = selectedTrigger
        guard let existing = existing.first(where: {
            $0.button == trigger.button && $0.modifiers == trigger.modifiers
        }), existing.legacyActionNumber != action else { return nil }
        return ActionNames.mouseActionName(existing.legacyActionNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Add an input for “\(ActionNames.mouseActionName(action))”"))
                .font(.headline)
            Form {
                Picker(String(localized: "Input type:"), selection: $kind) {
                    ForEach(TriggerKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                if kind.usesButton {
                    Picker(String(localized: "Button:"), selection: $button) {
                        ForEach(0...10, id: \.self) { number in
                            Text(ActionNames.mouseButtonDisplayName(number)).tag(number)
                        }
                    }
                } else {
                    Text(String(localized: "Gestures don’t use a button."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text(String(localized: "Modifier keys:"))
                    Toggle("shift", isOn: $withShift).toggleStyle(.checkbox)
                    Toggle("option", isOn: $withOption).toggleStyle(.checkbox)
                    Toggle("control", isOn: $withControl).toggleStyle(.checkbox)
                }
            }
            .formStyle(.columns)
            if let conflictActionName {
                Text(String(localized: "This input is currently assigned to “\(conflictActionName)” and will be moved here."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                Button(String(localized: "Add")) {
                    let trigger = selectedTrigger
                    onAdd(MouseBinding(
                        legacyActionNumber: action,
                        button: trigger.button,
                        modifiers: trigger.modifiers,
                        value: nil, switchAction: false))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }
}
