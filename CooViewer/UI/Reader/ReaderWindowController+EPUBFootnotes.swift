import AppKit
import Washi

/// 内部リンクの脚注表示。保留したリンクは同じ読書セッションだけへ戻す。
extension ReaderWindowController {
    // MARK: - 脚注ポップオーバー

    /// 本切替・退出・次の注参照で、旧 publication の非同期結果を残さない。
    /// cooViewer-oxr.32 / 設計書 §2.4。
    func dismissEPUBFootnote() {
        epubSession?.dismissFootnote()
    }

    private func presentEPUBFootnote(
        _ content: EPUBNoteContent,
        for link: EPUBInternalLink,
        in view: EPUBReaderView
    ) {
        guard let session = epubSession else { return }
        session.footnotePopover?.performClose(nil)

        let noteLabel = String(localized: "Note")
        let target = link.fragment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = target.flatMap { $0.isEmpty ? nil : "\(noteLabel) — #\($0)" }
            ?? noteLabel
        let placement = EPUBFootnotePopoverGeometry.placement(
            anchorRect: link.anchorRect,
            lastClickLocation: session.lastClickLocation,
            in: view.bounds)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = EPUBFootnotePopoverController(
            title: title,
            text: content.text,
            onMove: { [weak self, weak session, weak view, weak popover] in
                guard let self, let session, let view,
                      self.ownsEPUBSession(session), self.epubView === view,
                      session.footnotePopover === popover else { return }
                popover?.performClose(nil)
                if session.footnotePopover === popover {
                    session.footnotePopover = nil
                }
                // Washi 1.16.0 の公開 API。通常の internal-link 履歴もここで積む。
                view.follow(link)
            })
        session.footnotePopover = popover
        popover.show(
            relativeTo: placement.anchorRect,
            of: view,
            preferredEdge: placement.preferredEdge)
    }

    func readerView(
        _ view: EPUBReaderView,
        shouldFollowInternalLink link: EPUBInternalLink
    ) -> Bool {
        guard let session = epubSession, acceptsEPUBCallback(from: view) else { return true }
        guard EPUBFootnotePolicy.shouldPopover(
            link: link, isEnabled: settings.epubFootnotePopover) else {
            return true
        }

        dismissEPUBFootnote()
        if link.anchorRect.map({ !$0.isNull && !$0.isEmpty }) != true,
           let window {
            // internal link は didClick(non-link 専用)を通らない。Washi が矩形を
            // 解決できなかった場合も「最後のクリック位置」を現在のポインタから
            // 補い、中央への不意な表示を避ける(cooViewer-oxr.32、設計書 §2.4)。
            session.lastClickLocation = view.convert(
                window.mouseLocationOutsideOfEventStream, from: nil)
        }
        // Washi の delegate 判定は同期、本文抽出は async のため候補リンクだけを
        // いったん保留する。抽出不能なら follow(_:) へ戻して通常移動と同じ結果にする。
        // cooViewer-oxr.32 / 設計書 §2.4。
        session.footnoteTask = Task { [weak self, weak session, weak view] in
            guard let self, let session, let view else { return }
            let content = await view.noteContent(for: link)
            guard !Task.isCancelled, self.ownsEPUBSession(session),
                  self.epubView === view else {
                return
            }
            session.footnoteTask = nil
            guard let content else {
                view.follow(link)
                return
            }
            self.presentEPUBFootnote(content, for: link, in: view)
        }
        return false
    }

}
