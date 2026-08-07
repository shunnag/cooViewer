import SwiftUI

/// 設定画面(旧 PreferenceController の主要項目。仕様書 §6)。
/// 旧実装の「Cancel で全ロールバック」方式と異なり即時反映(設計書 §2.4)。
/// キー/マウス割り当てエディタは今後の課題(既定+旧設定の読み込みは動作する)。
struct SettingsView: View {
    @AppStorage("ReadMode") private var readMode = 0
    @AppStorage("SortMode") private var sortMode = 0
    @AppStorage("LoopCheck") private var loopCheck = 0
    @AppStorage("GoToLastPage") private var goToLastPage = 0
    @AppStorage("ReadSubFolder") private var readSubFolder = false
    @AppStorage("RememberBookSettings") private var rememberBookSettings = false
    @AppStorage("OpenLastFolder") private var openLastFolder = true
    @AppStorage("AlwaysRememberLastPage") private var alwaysRememberLastPage = false
    @AppStorage("OpenRecentLimit") private var openRecentLimit = 10

    @AppStorage("SingleSetting") private var singleSetting = 740
    @AppStorage("Interpolation") private var interpolation = 0
    @AppStorage("ShowNumber") private var showNumber = true
    @AppStorage("ShowPageBar") private var showPageBar = true

    @AppStorage("CanScrollMode") private var canScrollMode = 0
    @AppStorage("SwipeToTurnPage") private var swipeToTurnPage = true
    @AppStorage("FlipSwipeDirection") private var flipSwipeDirection = true
    @AppStorage("WheelSensitivity") private var wheelSensitivity = 1.0
    @AppStorage("PrevPageMode") private var prevPageMode = 0
    @AppStorage("SlideshowDelay") private var slideshowDelay = 0.0

    var body: some View {
        TabView {
            generalPane
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            displayPane
                .tabItem { Label(String(localized: "Display"), systemImage: "photo") }
            controlPane
                .tabItem { Label(String(localized: "Control"), systemImage: "computermouse") }
            KeyBindingsPane()
                .tabItem { Label(String(localized: "Key Bindings"), systemImage: "keyboard") }
        }
        .frame(width: 640, height: 500)
    }

    // MARK: - 一般

    private var generalPane: some View {
        Form {
            Section {
                Picker(String(localized: "Reading direction:"), selection: $readMode) {
                    Text(String(localized: "Right to Left")).tag(0)
                    Text(String(localized: "Left to Right")).tag(1)
                    Text(String(localized: "Right to Left (single page)")).tag(2)
                    Text(String(localized: "Left to Right (single page)")).tag(3)
                }
                Picker(String(localized: "Sort by:"), selection: $sortMode) {
                    Text(String(localized: "Name (numeric aware)")).tag(0)
                    Text(String(localized: "Name (simple)")).tag(4)
                    Text(String(localized: "Creation date")).tag(2)
                    Text(String(localized: "Modification date")).tag(3)
                    Text(String(localized: "Shuffle")).tag(1)
                }
                Picker(String(localized: "At the end of a book:"), selection: $loopCheck) {
                    Text(String(localized: "Loop")).tag(0)
                    Text(String(localized: "Open the next book (first page)")).tag(1)
                    Text(String(localized: "Open the next book (backward: last page)")).tag(2)
                    Text(String(localized: "Do nothing")).tag(3)
                }
            }
            Section {
                Picker(String(localized: "Restore last page:"), selection: $goToLastPage) {
                    Text(String(localized: "Ask")).tag(0)
                    Text(String(localized: "Always")).tag(1)
                    Text(String(localized: "Never")).tag(2)
                }
                // 履歴から溢れた本のページも LastPages に残す(仕様書 §7.3)
                Toggle(String(localized: "Always remember the last page"),
                       isOn: $alwaysRememberLastPage)
                Toggle(String(localized: "Open the last book at launch"), isOn: $openLastFolder)
                Stepper(String(localized: "Recent books to keep: \(openRecentLimit)"),
                        value: $openRecentLimit, in: 0...50)
            }
            Section {
                Toggle(String(localized: "Read subfolders"), isOn: $readSubFolder)
                Toggle(String(localized: "Remember settings per book"),
                       isOn: $rememberBookSettings)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 表示

    private var displayPane: some View {
        Form {
            Section {
                Toggle(String(localized: "Show page number"), isOn: $showNumber)
                Toggle(String(localized: "Show page bar"), isOn: $showPageBar)
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(String(localized: "Interpolation:"), selection: $interpolation) {
                        Text(String(localized: "Default")).tag(0)
                        Text(String(localized: "None")).tag(1)
                        Text(String(localized: "Low")).tag(2)
                        Text(String(localized: "High")).tag(3)
                    }
                    .help(interpolationDescription)
                    // 選択中モードの処理内容(ツールチップと同文)
                    Text(interpolationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ColorPicker(String(localized: "Background color:"),
                            selection: backgroundColorBinding, supportsOpacity: false)
                sliderRow(
                    label: String(localized: "Spread threshold (width/height):"),
                    value: singleSettingBinding, range: 0.4...1.0,
                    display: String(format: "%.2f", Double(singleSetting) / 1000)
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 操作

    private var controlPane: some View {
        Form {
            Section {
                Toggle(String(localized: "Turn pages with a trackpad swipe"),
                       isOn: $swipeToTurnPage)
                Toggle(String(localized: "Reverse swipe direction"),
                       isOn: $flipSwipeDirection)
                    .disabled(!swipeToTurnPage)
                Picker(String(localized: "Scroll wheel:"), selection: $canScrollMode) {
                    Text(String(localized: "Scroll only")).tag(0)
                    Text(String(localized: "Scroll, then move within page")).tag(1)
                    Text(String(localized: "Scroll, then turn page")).tag(2)
                    Text(String(localized: "Always turn page")).tag(3)
                }
                sliderRow(
                    label: String(localized: "Wheel page-turn threshold:"),
                    value: $wheelSensitivity, range: 0...2.0,
                    display: wheelSensitivity == 0
                        ? String(localized: "Disabled")
                        : String(format: "%.1f", wheelSensitivity)
                )
            }
            Section {
                Picker(String(localized: "When returning to previous page:"),
                       selection: $prevPageMode) {
                    Text(String(localized: "Show from top")).tag(0)
                    Text(String(localized: "Show from bottom")).tag(1)
                }
                sliderRow(
                    label: String(localized: "Slideshow interval (seconds):"),
                    value: $slideshowDelay, range: 0...30,
                    display: String(format: "%.1f", slideshowDelay)
                )
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 部品

    /// ラベル+スライダー+現在値の 1 行(値は幅固定でガタつかないように)
    private func sliderRow(
        label: String, value: Binding<Double>,
        range: ClosedRange<Double>, display: String
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .frame(width: 180)
                Text(display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    /// 補間モードごとの処理内容(設計書 §5 描画品質)
    private var interpolationDescription: String {
        switch interpolation {
        case 1: String(localized: "None: pixels are scaled as-is (for pixel art).")
        case 2: String(localized: "Low: fast GPU scaling only.")
        case 3: String(localized:
            "High: high-quality downscaling plus MetalFX upscaling for enlargement.")
        default: String(localized:
            "Default: high-quality downscaling that reduces moiré on screentones.")
        }
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: SettingsStore.shared.viewBackgroundColor) },
            set: { SettingsStore.shared.viewBackgroundColor = NSColor($0) }
        )
    }

    private var singleSettingBinding: Binding<Double> {
        Binding(
            get: { Double(singleSetting) / 1000 },
            set: { singleSetting = Int($0 * 1000) }
        )
    }
}
