import Washi

/// 画面外 WebKit 処理(リフローの census・画面サムネイル、FXL の複雑ページの
/// ラスタライズ)に適用する Washi の省エネ方針と寿命を 1 か所にまとめる
/// (設計書 §5 電力方針・§7.3)。Washi の既定は両方とも「従来どおり」なので、
/// 利用側で明示しない限り何も変わらない。
enum EPUBOffscreenSettings {
    /// 低電力モードまたは温度圧迫(serious / critical)で census の項目とサムネイルの
    /// ジョブを 50 ms ずつ間隔を空け、未開始の census は critical の間だけ延期する。
    /// アプリ本体の `PowerStateMonitor.shouldConserveEnergy` と同じ条件だが、Washi が
    /// OS 状態を直接評価するため温度圧迫の保持(ヒステリシス)は掛からない。
    /// QoS は下げず結果も変わらない(設計書 §5)。
    static let energyPolicy: EPUBOffscreenEnergyPolicy = .followSystem

    /// FXL ラスタライザが最後の描画からこの時間アイドルなら不可視ウインドウと
    /// WebContent プロセスを畳み、次の描画で作り直す。Washi の census /
    /// サムネイルの解放間隔 20 s(内部定数)と揃える: 複雑ページは先読み
    /// (`Book.schedulePrefetch`、既定では媒体別下限 12〜20 ページ)がまとめて要求し、
    /// 以後は PageCache が応えるので、20 s の無要求は読者が止まったことを意味し、
    /// 通常のめくり速度ではプロセス再生成を往復しない(設計書 §7.3)。
    static let rasterizerIdleReleaseInterval: Duration = .seconds(20)

    /// 共通の省エネ方針を適用したリーダービューを生成する(設計書 §5)。
    @MainActor
    static func makeReaderView() -> EPUBReaderView {
        let view = EPUBReaderView()
        view.offscreenEnergyPolicy = energyPolicy
        return view
    }

    /// 共通の省エネ方針を適用したアトラスを生成する(設計書 §5)。
    @MainActor
    static func makeAtlas(publication: EPUBPublication) -> EPUBScreenAtlas {
        let atlas = EPUBScreenAtlas(publication: publication)
        atlas.offscreenEnergyPolicy = energyPolicy
        return atlas
    }

    /// 共通のアイドル解放間隔を適用した FXL ラスタライザを生成する(設計書 §7.3)。
    @MainActor
    static func makeRasterizer(publication: EPUBPublication) -> EPUBPageRasterizer {
        let rasterizer = EPUBPageRasterizer(publication: publication)
        rasterizer.idleReleaseInterval = rasterizerIdleReleaseInterval
        return rasterizer
    }
}
