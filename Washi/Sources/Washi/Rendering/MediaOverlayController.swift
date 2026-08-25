import AVFoundation
import Foundation

/// メディアオーバーレイ(SMIL)の音声同期再生エンジン。
/// par(text 断片 + audio クリップ)を順に再生し、テキストへ active-class を
/// 付けてページを追従させる。項目末尾では次のオーバーレイへ連続再生する
/// (オーディオブック用途)。EPUBReaderView が所有し、そこから駆動する
@MainActor
final class MediaOverlayController {
    private weak var reader: EPUBReaderView?
    private let publication: EPUBPublication
    /// 再生中テキストへ付ける CSS クラス(media:active-class か既定)
    private let activeClass: String

    private var overlay: MediaOverlay?
    /// 再生中の spine 項目(ホストが現在項目と突き合わせて古い章の再開を防ぐ)
    private(set) var spineIndex = 0
    private var parIndex = 0
    private var player: AVAudioPlayer?
    private var loadedAudioPath: String?
    private var ticker: Timer?
    private(set) var isPlaying = false
    /// 項目末尾で次項目のオーバーレイへ連続再生するか(既定 true)
    var continuesToNextItem = true

    init(reader: EPUBReaderView, publication: EPUBPublication,
         activeClass: String) {
        self.reader = reader
        self.publication = publication
        self.activeClass = activeClass
    }

    /// 指定 spine 項目のオーバーレイを先頭から再生する(既に再生中なら停止して開始)
    func play(fromSpineIndex index: Int) {
        stopAudio()
        spineIndex = index
        parIndex = 0
        overlay = publication.mediaOverlay(forSpineIndex: index)
        guard let overlay, !overlay.parallels.isEmpty else {
            finish()
            return
        }
        _ = overlay
        startCurrentPar(seek: true)
        setPlaying(true)
    }

    /// 一時停止(ハイライトは残す)
    func pause() {
        player?.pause()
        ticker?.invalidate(); ticker = nil
        setPlaying(false)
    }

    /// 一時停止からの再開
    func resume() {
        guard overlay != nil, player != nil else {
            play(fromSpineIndex: spineIndex)
            return
        }
        player?.play()
        startTicker()
        setPlaying(true)
    }

    /// 停止してハイライトを消す
    func stop() {
        stopAudio()
        clearHighlight()
        overlay = nil
        setPlaying(false)
    }

    // MARK: - 内部

    private func stopAudio() {
        ticker?.invalidate(); ticker = nil
        player?.stop()
        player = nil
        loadedAudioPath = nil
    }

    /// 現在の par を鳴らす(必要なら音声を読み込み・シーク)+ ハイライト。
    /// 音声が無い/読み込めない par(テキストのみ・DRM・欠落・非対応形式)は
    /// 空回りせず短い間だけハイライトして次へ進める(無限ストール防止)
    private func startCurrentPar(seek: Bool) {
        guard let overlay, overlay.parallels.indices.contains(parIndex) else {
            finish()
            return
        }
        let par = overlay.parallels[parIndex]
        if let audioHref = par.audioHref,
           let audioPath = ContainerPath.resolve(base: overlay.basePath,
                                                 href: audioHref) {
            if audioPath != loadedAudioPath {
                loadAudio(path: audioPath)
            }
            if let player {
                if seek { player.currentTime = par.clipBegin }
                player.play()
                highlight(par: par)
                startTicker()
                return
            }
        }
        // 音声を用意できない par: ハイライトだけして一定時間後に次へ
        highlight(par: par)
        scheduleSilentAdvance()
    }

    /// 音声の無い/失敗した par を、決まった短い間ののち次へ送る一発タイマー
    private func scheduleSilentAdvance() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.advancePar()
            }
        }
    }

    private func loadAudio(path: String) {
        guard let (data, _) = try? publication.resource(at: path),
              let newPlayer = try? AVAudioPlayer(data: data) else {
            player = nil
            loadedAudioPath = nil
            return
        }
        newPlayer.prepareToPlay()
        player = newPlayer
        loadedAudioPath = path
    }

    private func startTicker() {
        ticker?.invalidate()
        // 25ms 間隔で clipEnd 到達を監視して par を進める
        ticker = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard isPlaying, let overlay, let player,
              overlay.parallels.indices.contains(parIndex) else { return }
        let par = overlay.parallels[parIndex]
        let end = par.clipEnd ?? player.duration
        // クリップ終端(または音声終端)に達したら次の par へ
        if player.currentTime >= end - 0.005 || !player.isPlaying {
            advancePar()
        }
    }

    private func advancePar() {
        guard let overlay else { return }
        let next = parIndex + 1
        if next < overlay.parallels.count {
            let prevAudio = overlay.parallels[parIndex].audioHref
            parIndex = next
            let par = overlay.parallels[next]
            // 同一音声で連続するクリップなら再生を止めずハイライトだけ更新
            let sameAudio = par.audioHref == prevAudio
            let contiguous = sameAudio && player != nil
                && abs((player!.currentTime) - par.clipBegin) < 0.25
            if contiguous {
                highlight(par: par)
            } else {
                startCurrentPar(seek: true)
            }
        } else {
            finishItem()
        }
    }

    /// 現在項目のオーバーレイ終了。連続再生なら次の該当項目へ
    private func finishItem() {
        stopAudio()
        guard continuesToNextItem,
              let nextIndex = nextSpineIndexWithOverlay(after: spineIndex) else {
            finish()
            return
        }
        reader?.navigateForMediaOverlay(toSpineIndex: nextIndex)
        spineIndex = nextIndex
        parIndex = 0
        overlay = publication.mediaOverlay(forSpineIndex: nextIndex)
        guard overlay?.parallels.isEmpty == false else { finish(); return }
        startCurrentPar(seek: true)
    }

    private func finish() {
        stopAudio()
        clearHighlight()
        setPlaying(false)
        reader?.mediaOverlayDidFinish()
    }

    private func nextSpineIndexWithOverlay(after index: Int) -> Int? {
        let order = publication.readingOrder
        var i = index + 1
        while i < order.count {
            if order[i].item.mediaOverlay != nil { return i }
            i += 1
        }
        return nil
    }

    private func highlight(par: MediaOverlay.Parallel) {
        let fragment = par.textHref.flatMap {
            $0.split(separator: "#", maxSplits: 1).count == 2
                ? String($0.split(separator: "#", maxSplits: 1)[1]) : nil
        }
        reader?.mediaOverlayHighlight(fragmentID: fragment, cssClass: activeClass)
    }

    private func clearHighlight() {
        reader?.mediaOverlayHighlight(fragmentID: nil, cssClass: activeClass)
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        reader?.mediaOverlayPlayingChanged(playing)
    }
}
