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
    @AppStorage("WheelSensitivity") private var wheelSensitivity = 1.0
    @AppStorage("PrevPageMode") private var prevPageMode = 0
    @AppStorage("SlideshowDelay") private var slideshowDelay = 0.0

    var body: some View {
        TabView {
            general
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
            display
                .tabItem { Label(String(localized: "Display"), systemImage: "photo") }
            control
                .tabItem { Label(String(localized: "Control"), systemImage: "computermouse") }
        }
        .frame(width: 440)
        .padding(20)
    }

    private var general: some View {
        Form {
            Picker(String(localized: "Reading direction:"), selection: $readMode) {
                Text(String(localized: "Right to Left")).tag(0)
                Text(String(localized: "Left to Right")).tag(1)
                Text(String(localized: "Right to Left (single page)")).tag(2)
                Text(String(localized: "Left to Right (single page)")).tag(3)
            }
            Picker(String(localized: "Sort by:"), selection: $sortMode) {
                Text(String(localized: "Name")).tag(0)
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
            Picker(String(localized: "Restore last page:"), selection: $goToLastPage) {
                Text(String(localized: "Ask")).tag(0)
                Text(String(localized: "Always")).tag(1)
                Text(String(localized: "Never")).tag(2)
            }
            Toggle(String(localized: "Read subfolders"), isOn: $readSubFolder)
            Toggle(String(localized: "Remember settings per book"), isOn: $rememberBookSettings)
            Toggle(String(localized: "Open the last book at launch"), isOn: $openLastFolder)
            // 履歴から溢れた本のページも LastPages に残す(仕様書 §7.3)
            Toggle(String(localized: "Always remember the last page"),
                   isOn: $alwaysRememberLastPage)
            Stepper(String(localized: "Recent books to keep: \(openRecentLimit)"),
                    value: $openRecentLimit, in: 0...50)
        }
        .padding(.vertical, 8)
    }

    private var display: some View {
        Form {
            Toggle(String(localized: "Show page number"), isOn: $showNumber)
            Toggle(String(localized: "Show page bar"), isOn: $showPageBar)
            Picker(String(localized: "Interpolation:"), selection: $interpolation) {
                Text(String(localized: "Default")).tag(0)
                Text(String(localized: "None")).tag(1)
                Text(String(localized: "Low")).tag(2)
                Text(String(localized: "High")).tag(3)
            }
            ColorPicker(String(localized: "Background color:"),
                        selection: backgroundColorBinding, supportsOpacity: false)
            VStack(alignment: .leading) {
                Slider(value: singleSettingBinding, in: 0.4...1.0) {
                    Text(String(localized: "Spread threshold (width/height):"))
                }
                Text(String(format: "%.2f", Double(singleSetting) / 1000))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
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

    private var control: some View {
        Form {
            Picker(String(localized: "Scroll wheel:"), selection: $canScrollMode) {
                Text(String(localized: "Scroll only")).tag(0)
                Text(String(localized: "Scroll, then move within page")).tag(1)
                Text(String(localized: "Scroll, then turn page")).tag(2)
                Text(String(localized: "Always turn page")).tag(3)
            }
            VStack(alignment: .leading) {
                Slider(value: $wheelSensitivity, in: 0...2.0) {
                    Text(String(localized: "Wheel page-turn threshold:"))
                }
                Text(wheelSensitivity == 0
                     ? String(localized: "Disabled")
                     : String(format: "%.1f", wheelSensitivity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(String(localized: "When returning to previous page:"), selection: $prevPageMode) {
                Text(String(localized: "Show from top")).tag(0)
                Text(String(localized: "Show from bottom")).tag(1)
            }
            VStack(alignment: .leading) {
                Slider(value: $slideshowDelay, in: 0...30) {
                    Text(String(localized: "Slideshow interval (seconds):"))
                }
                Text(String(format: "%.1f", slideshowDelay))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}
