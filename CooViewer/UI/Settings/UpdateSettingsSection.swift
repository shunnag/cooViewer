import SwiftUI
import Sparkle

/// 「アップデート」設定の橋渡し。Sparkle の SPUUpdater を包み、SwiftUI から
/// 自動チェックの有無・周期・自動ダウンロードを読み書きする。値を変えると
/// updater 側へ即時反映され(タイマー再スケジュール等)、Info.plist ではなく
/// UserDefaults(SUEnableAutomaticChecks 等)に永続化される。
/// updater が nil のとき(スナップショット/XCTest では起動しない)は UserDefaults を
/// 直接読み書きして UI だけ成立させる。
@MainActor
final class UpdaterViewModel: ObservableObject {
    /// ユーザーに提示する確認周期(秒)。毎日/毎週/毎月
    static let intervalOptions: [TimeInterval] = [86_400, 604_800, 2_592_000]

    private let updater: SPUUpdater?
    var canCheckNow: Bool { updater != nil }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            if let updater { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
            else { UserDefaults.standard.set(automaticallyChecksForUpdates, forKey: "SUEnableAutomaticChecks") }
        }
    }
    @Published var updateCheckInterval: TimeInterval {
        didSet {
            if let updater { updater.updateCheckInterval = updateCheckInterval }
            else { UserDefaults.standard.set(updateCheckInterval, forKey: "SUScheduledCheckInterval") }
        }
    }
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            if let updater { updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
            else { UserDefaults.standard.set(automaticallyDownloadsUpdates, forKey: "SUAutomaticallyUpdate") }
        }
    }
    let lastUpdateCheckDate: Date?

    init(updater: SPUUpdater?) {
        self.updater = updater
        let defaults = UserDefaults.standard
        // 初期値は updater(起動済み)優先、無ければ Sparkle の UserDefaults キー。
        // 代入は didSet を発火しない(init 内のため)ので updater へ書き戻さない
        automaticallyChecksForUpdates =
            updater?.automaticallyChecksForUpdates ?? defaults.bool(forKey: "SUEnableAutomaticChecks")
        automaticallyDownloadsUpdates =
            updater?.automaticallyDownloadsUpdates ?? defaults.bool(forKey: "SUAutomaticallyUpdate")
        let saved = updater?.updateCheckInterval ?? defaults.double(forKey: "SUScheduledCheckInterval")
        // Picker のタグと必ず一致させるため、保存値を最も近い選択肢へ丸める
        // (未設定=0 のときは既定の毎日)。表示のみで、ユーザーが触るまで書き戻さない
        updateCheckInterval = Self.snap(saved)
        lastUpdateCheckDate = updater?.lastUpdateCheckDate
    }

    /// 秒数を提示周期の最も近いものへ丸める(0 以下は毎日)
    static func snap(_ interval: TimeInterval) -> TimeInterval {
        guard interval > 0 else { return 86_400 }
        return intervalOptions.min { abs($0 - interval) < abs($1 - interval) } ?? 86_400
    }

    func checkNow() { updater?.checkForUpdates() }
}

/// 「一般」ペインの末尾に置く「ソフトウェアアップデート」セクション。
/// 自動確認の有無・周期・自動導入と、手動確認ボタン+最終確認日時を出す。
struct UpdateSettingsSection: View {
    @StateObject private var model: UpdaterViewModel

    init(updater: SPUUpdater?) {
        _model = StateObject(wrappedValue: UpdaterViewModel(updater: updater))
    }

    var body: some View {
        Section {
            Toggle(String(localized: "Automatically check for updates"),
                   isOn: $model.automaticallyChecksForUpdates)
            Picker(String(localized: "Frequency:"), selection: $model.updateCheckInterval) {
                Text(String(localized: "Daily")).tag(TimeInterval(86_400))
                Text(String(localized: "Weekly")).tag(TimeInterval(604_800))
                Text(String(localized: "Monthly")).tag(TimeInterval(2_592_000))
            }
            .disabled(!model.automaticallyChecksForUpdates)
            Toggle(String(localized: "Download and install updates automatically"),
                   isOn: $model.automaticallyDownloadsUpdates)
            .disabled(!model.automaticallyChecksForUpdates)
            HStack {
                Button(String(localized: "Check Now…")) { model.checkNow() }
                    .disabled(!model.canCheckNow)
                Spacer()
                if let date = model.lastUpdateCheckDate {
                    Text(String(localized: "Last checked: \(date.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "Software Update"))
        }
    }
}
