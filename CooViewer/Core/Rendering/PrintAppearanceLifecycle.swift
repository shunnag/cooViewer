import Foundation

/// 網点処理のエンジンを準備・解放する契機(設計書 §5)。網かけの表示は全体で 1 つの設定なので、
/// プロセスで 1 つの記録を持ち、切 ↔ 入の変わり目でだけサービスへ伝える(強さの変更では何もしない)。
/// 入れたら準備を積み(最初のページをコンパイルで待たせないため)、切ったら作業域と GPU のパイプラインを
/// 手放す(設定が全体で 1 つなので、切った時点で全ての窓で切られている)。
///
/// 最初の観測は記録だけにする: 入れて起動したときの準備は AppDelegate.scheduleLaunchPrewarming が受け持ち、
/// 切って起動したときは共有のサービスに触れない。XCTest と書庫監査では何もしない
/// (コントローラのテストも applySettings を通るため。起動時の予熱と同じ規則)
@MainActor
final class PrintAppearanceLifecycle {
    static let shared = PrintAppearanceLifecycle()

    /// このプロセスでサービスへ伝えてよいか(XCTest・書庫監査では偽)
    nonisolated static var isAllowedInThisProcess: Bool {
        !AutomatedRun.isXCTest && !AutomatedRun.isArchiveAudit
    }

    private let isAllowed: () -> Bool
    private let prepare: () -> Void
    private let release: () -> Void
    /// 最後に観測した状態。nil はまだ観測していない
    private var lastEnabled: Bool?

    init(isAllowed: @escaping () -> Bool = { PrintAppearanceLifecycle.isAllowedInThisProcess },
         prepare: @escaping () -> Void = { PrintAppearanceService.shared.prepareIfNeeded() },
         release: @escaping () -> Void = { PrintAppearanceService.shared.releaseAll() }) {
        self.isAllowed = isAllowed
        self.prepare = prepare
        self.release = release
    }

    /// 設定の反映のたびに呼ぶ(applySettings)。変わり目でだけ準備または解放する
    func observe(enabled: Bool) {
        let previous = lastEnabled
        lastEnabled = enabled
        guard let previous, previous != enabled, isAllowed() else { return }
        if enabled {
            prepare()
        } else {
            release()
        }
    }
}
