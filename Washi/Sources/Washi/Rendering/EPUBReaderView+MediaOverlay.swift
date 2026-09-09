import Foundation

/// メディアオーバーレイ(SMIL)再生の公開 API と、コントローラが使う内部フック。
/// 再生・一時停止・停止と、テキストのハイライト/ページ追従を仲介する
extension EPUBReaderView {
    /// media:active-class の既定(本が宣言していないとき)
    static let defaultActiveClass = "-epub-media-overlay-active"

    /// 現在の spine 項目がメディアオーバーレイ(音声同期)を持つか
    public var hasMediaOverlayForCurrentItem: Bool {
        publication?.mediaOverlay(forSpineIndex: currentSpineIndex) != nil
    }

    /// この本のどこかにメディアオーバーレイがあるか
    public var hasMediaOverlays: Bool {
        publication?.hasMediaOverlays ?? false
    }

    /// メディアオーバーレイを再生中か
    public var isPlayingMediaOverlay: Bool {
        mediaOverlayController?.isPlaying ?? false
    }

    /// メディアオーバーレイの再生を開始/再開する。現在の項目が音声を持たない
    /// ときは何もしない。項目末尾では次の音声付き項目へ連続再生する
    public func playMediaOverlay() {
        guard let publication, hasMediaOverlayForCurrentItem else { return }
        if let controller = mediaOverlayController {
            if controller.isPlaying { return }
            // 一時停止後に別の章へ移動していたら、その章の先頭から始め直す
            // (古い章の音声を再開しない)
            if controller.spineIndex == currentSpineIndex {
                controller.resume()
            } else {
                controller.play(fromSpineIndex: currentSpineIndex)
            }
            return
        }
        let activeClass = publication.metadata.mediaOverlayActiveClass
            ?? Self.defaultActiveClass
        let controller = MediaOverlayController(
            reader: self, publication: publication, activeClass: activeClass)
        controller.playbackRate = settings.mediaOverlayPlaybackRate
        controller.skippedTypes = settings.mediaOverlaySkippedTypes
        mediaOverlayController = controller
        controller.play(fromSpineIndex: currentSpineIndex)
    }

    /// Starts narration at the clip whose text is visible on the current page,
    /// instead of at the start of the chapter (cooViewer-oxr.46 C26).
    /// Falls back to the chapter start when nothing on the page is narrated.
    public func playMediaOverlayFromCurrentPage() async {
        guard let publication,
              let overlay = publication.mediaOverlay(forSpineIndex: currentSpineIndex)
        else { return }
        let identifiers = overlay.parallels.map { par -> String in
            guard let href = par.textHref else { return "" }
            let parts = href.split(separator: "#", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : ""
        }
        var parIndex = 0
        let candidates = identifiers.filter { !$0.isEmpty }
        if !candidates.isEmpty,
           let result = await callWashiReturning(
               "return __washi.firstVisibleIdentifier(ids);",
               arguments: ["ids": candidates]),
           let visible = result as? String,
           let index = identifiers.firstIndex(of: visible) {
            parIndex = index
        }
        playMediaOverlay(atSpineIndex: currentSpineIndex, parIndex: parIndex)
    }

    /// The media-overlay playback position (spine item + clip index), for a host
    /// that persists where the reader stopped listening. `nil` when idle.
    public var mediaOverlayPosition: (spineIndex: Int, parIndex: Int)? {
        mediaOverlayController.map(\.position)
    }

    /// Resumes narration at a saved position (see ``mediaOverlayPosition``).
    /// Returns false when the book has no overlay at that spine item.
    @discardableResult
    public func playMediaOverlay(atSpineIndex index: Int, parIndex: Int) -> Bool {
        guard let publication,
              publication.mediaOverlay(forSpineIndex: index) != nil else { return false }
        let activeClass = publication.metadata.mediaOverlayActiveClass
            ?? Self.defaultActiveClass
        let controller = mediaOverlayController
            ?? MediaOverlayController(reader: self, publication: publication,
                                      activeClass: activeClass)
        controller.playbackRate = settings.mediaOverlayPlaybackRate
        controller.skippedTypes = settings.mediaOverlaySkippedTypes
        mediaOverlayController = controller
        controller.play(fromSpineIndex: index, parIndex: parIndex)
        return true
    }

    /// 一時停止(ハイライトは残す)
    public func pauseMediaOverlay() {
        mediaOverlayController?.pause()
    }

    /// 停止してハイライトを消す
    public func stopMediaOverlay() {
        mediaOverlayController?.stop()
    }

    /// 再生⇔一時停止のトグル
    public func toggleMediaOverlayPlayback() {
        if isPlayingMediaOverlay { pauseMediaOverlay() } else { playMediaOverlay() }
    }

    // MARK: - コントローラ用の内部フック

    /// 指定断片へハイライトを移し、必要ならそのページへめくる(id=nil で解除)。
    /// 断片 id・クラス名は EPUB 由来(信頼できない)ので、文字列連結ではなく
    /// callAsyncJavaScript の引数として渡し WebKit に完全にエスケープさせる
    /// (手動 \\・' エスケープでは \n・\r・U+2028・U+2029 を取りこぼす)
    func mediaOverlayHighlight(fragmentID: String?, cssClass: String) {
        let idArg: Any
        if let fragmentID { idArg = fragmentID } else { idArg = NSNull() }
        callWashiAsync("return __washi.mediaOverlayHighlight(id, cls);",
                       arguments: ["id": idArg, "cls": cssClass])
    }

    /// 連続再生で次の項目へ移動する(先頭から表示)
    func navigateForMediaOverlay(toSpineIndex index: Int) {
        guard let publication,
              publication.readingOrder.indices.contains(index) else { return }
        goToContainerPath(publication.readingOrder[index].containerPath,
                          fragment: nil, recordsHistory: false)
    }

    /// 再生状態の変化を delegate へ通知
    func mediaOverlayPlayingChanged(_ isPlaying: Bool) {
        delegate?.readerView(self, isPlayingMediaOverlayDidChange: isPlaying)
    }

    /// 本の末尾まで再生し終えた
    func mediaOverlayDidFinish() {
        delegate?.readerViewMediaOverlayDidFinish(self)
    }
}
