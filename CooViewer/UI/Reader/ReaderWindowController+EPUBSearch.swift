import AppKit
import SwiftUI
import Washi

/// バックグラウンド検索から MainActor へ渡す値だけを束ねる。
private struct EPUBSearchComputation: Sendable {
    let hits: [SearchHit]
    let isTruncated: Bool
}

/// 現在の読書セッションに属する本文検索と、厳密着地の表示を担う。
extension ReaderWindowController {
    // MARK: - 本文検索

    /// リフロー EPUB 専用のフローティング検索パネルを開く。
    @objc func showEPUBSearchMenu(_ sender: Any?) {
        guard let session = epubSession else { return }
        guard isEPUBMode, let window else { return }
        if let panel = session.search.panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let model = EPUBSearchModel()
        let searchView = EPUBSearchView(
            model: model,
            onQueryChange: { [weak self, weak session, weak model] query in
                guard let self, let session, let model,
                      self.ownsEPUBSession(session),
                      session.search.model === model else { return }
                self.startEPUBSearch(query: query, debounce: true)
            },
            onSearchNow: { [weak self, weak session, weak model] query in
                guard let self, let session, let model,
                      self.ownsEPUBSession(session),
                      session.search.model === model else { return }
                self.startEPUBSearch(query: query, debounce: false)
            },
            onSelect: { [weak self, weak session, weak model] index in
                guard let self, let session, let model,
                      self.ownsEPUBSession(session),
                      session.search.model === model else { return }
                self.selectEPUBSearchHit(at: index)
            },
            onNext: { [weak self, weak session, weak model] in
                guard let self, let session, let model,
                      self.ownsEPUBSession(session),
                      session.search.model === model else { return }
                self.goToEPUBSearchHit(forward: true)
            },
            onPrevious: { [weak self, weak session, weak model] in
                guard let self, let session, let model,
                      self.ownsEPUBSession(session),
                      session.search.model === model else { return }
                self.goToEPUBSearchHit(forward: false)
            },
            onClose: { [weak self, weak session, weak model] in
                guard let self, let session, let model,
                      self.ownsEPUBSession(session),
                      session.search.model === model else { return }
                session.search.panel?.performClose(nil)
            })
        let panel = NSPanel(contentViewController: NSHostingController(rootView: searchView))
        panel.styleMask = [.titled, .closable, .resizable, .utilityWindow]
        panel.title = String(localized: "Search")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.setContentSize(NSSize(width: 480, height: 500))
        panel.delegate = self
        // パネルがキーウインドウでも ⌘F/⌘G をリーダーの responder へ渡す。
        panel.nextResponder = self

        session.search.model = model
        session.search.panel = panel
        let parentFrame = window.frame
        let x = parentFrame.maxX - panel.frame.width - 24
        let y = parentFrame.maxY - panel.frame.height - 48
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    /// ⌘G と検索パネルのボタンから次のヒットへ移動する。
    @objc func findNextEPUBMenu(_ sender: Any?) {
        goToEPUBSearchHit(forward: true)
    }

    /// ⇧⌘G と検索パネルのボタンから前のヒットへ移動する。
    @objc func findPreviousEPUBMenu(_ sender: Any?) {
        goToEPUBSearchHit(forward: false)
    }

    /// AppKit 標準の「選択部分を検索に使用」(⌘E)を EPUB の検索パネルへ渡す。
    /// cooViewer-oxr.34 / 設計書 §2.4。
    @objc func useSelectionForEPUBFindMenu(_ sender: Any?) {
        guard let session = epubSession else { return }
        guard isEPUBMode, let term = session.latestSelectionText else { return }
        showEPUBSearchMenu(sender)
        guard let model = session.search.model else { return }
        model.query = term
        startEPUBSearch(query: term, debounce: false)
    }

    /// 入力連打をデバウンスし、Washi の同期検索を MainActor の外で実行する。
    private func startEPUBSearch(query: String, debounce: Bool) {
        guard let session = epubSession else { return }
        // CLI の即時検索後に届く同一の SwiftUI 変更通知は二重実行しない。
        if debounce, session.search.model?.pendingQuery == query { return }
        clearEPUBSearchHighlight()
        session.search.task?.cancel()
        session.search.queryEpoch += 1
        let epoch = session.search.queryEpoch
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            session.search.model?.clearResults()
            session.search.task = nil
            return
        }
        guard let publication = epubPublication,
              let model = session.search.model else { return }
        model.beginSearch(query: query)

        session.search.task = Task { [weak self, weak session, weak model] in
            guard let session, let model else { return }
            var didFinish = false
            defer {
                if session.search.queryEpoch == epoch {
                    session.search.task = nil
                    if !didFinish { model.clearResults() }
                }
            }
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, self?.ownsEPUBSession(session) == true,
                  session.search.queryEpoch == epoch,
                  session.search.model === model else { return }

            let worker = Task.detached(priority: .userInitiated) {
                () -> EPUBSearchComputation? in
                let allHits = publication.search(query)
                guard !Task.isCancelled else { return nil }
                let limited = EPUBSearchLogic.limited(allHits)
                var itemTexts: [Int: String] = [:]
                for hit in limited.values where itemTexts[hit.spineIndex] == nil {
                    guard !Task.isCancelled else { return nil }
                    itemTexts[hit.spineIndex] = (try? publication.extractText(
                        forSpineIndex: hit.spineIndex)) ?? ""
                }
                let hits = limited.values.map { hit in
                    let text = itemTexts[hit.spineIndex] ?? ""
                    // 想定外の抽出/範囲失敗でも一覧から落とさず、長さ 0 により
                    // Washi の nil → 従来 locator のフォールバックへ接続する。
                    let utf16Range = EPUBSearchLogic.utf16Range(
                        characterOffset: hit.characterOffset,
                        length: hit.length, in: text) ?? (0, 0)
                    return SearchHit(
                        spineIndex: hit.spineIndex,
                        progression: EPUBSearchLogic.progression(
                            characterOffset: hit.characterOffset,
                            itemTextLength: text.count),
                        utf16Offset: utf16Range.utf16Offset,
                        utf16Length: utf16Range.utf16Length,
                        snippet: hit.snippet)
                }
                return EPUBSearchComputation(
                    hits: hits, isTruncated: limited.isTruncated)
            }
            let computation = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let computation, let self,
                  self.ownsEPUBSession(session), session.search.queryEpoch == epoch,
                  session.search.model === model else { return }

            let pages = computation.hits.map { self.epubSearchPageNumber(for: $0) }
            model.finishSearch(query: query, hits: computation.hits,
                               pageNumbers: pages,
                               isTruncated: computation.isTruncated)
            didFinish = true
        }
    }

    /// ページ番号表示とジャンプ先で共有する唯一の近似 locator 生成経路。
    private func epubSearchLocator(for hit: SearchHit) -> EPUBLocator {
        EPUBLocator(spineIndex: hit.spineIndex, progression: hit.progression)
    }

    private func epubSearchPageNumber(for hit: SearchHit) -> Int? {
        epubBookmarkPageNumber(for: epubSearchLocator(for: hit))
    }

    /// census の完了・無効化に合わせて検索一覧のページ番号も更新する。
    func refreshEPUBSearchPageNumbers() {
        guard let session = epubSession else { return }
        guard let model = session.search.model else { return }
        model.updatePageNumbers(model.hits.map { epubSearchPageNumber(for: $0) })
    }

    private func selectEPUBSearchHit(at index: Int) {
        guard let session = epubSession else { return }
        guard let model = session.search.model, model.hits.indices.contains(index),
              let epubView else { return }
        let hit = model.hits[index]
        let locator = epubSearchLocator(for: hit)
        model.select(index)
        clearEPUBSearchHighlight()
        let token = session.search.landingEpoch
        session.search.landingTask = Task { [weak self, weak session, weak epubView, weak model] in
            guard let self, let session, let epubView, let model else { return }
            defer {
                if session.search.landingEpoch == token {
                    session.search.landingTask = nil
                }
            }
            guard !Task.isCancelled, self.ownsEPUBSession(session),
                  session.search.landingEpoch == token,
                  self.epubView === epubView, session.search.model === model
            else { return }
            // 着地由来の移動を待つ印(整定判定用)と、待機中に別の移動が起きたかを
            // 判定するための通算回数を控える
            session.search.pendingLanding = token
            let movesBefore = session.search.moveCount
            let landing = await epubView.go(
                to: locator,
                textRange: (utf16Offset: hit.utf16Offset,
                            utf16Length: hit.utf16Length))
            guard !Task.isCancelled, self.ownsEPUBSession(session),
                  session.search.landingEpoch == token,
                  self.epubView === epubView, session.search.model === model
            else { return }
            guard let landing else {
                // 待機中に別の移動(目次・しおり・利用者のページ送り等)が起きて Washi が
                // nil を返した場合、その移動を近似ジャンプで上書きしない(cooViewer-rso)
                guard session.search.moveCount == movesBefore else {
                    session.search.pendingLanding = nil
                    return
                }
                // 移動が無ければ地図が解決できない項目なので従来の近似位置へ。
                // session.search.pendingLanding はその移動の didMoveTo まで保持し、検証の
                // 整定判定が早まらないようにする(cooViewer-lsq)
                epubView.go(to: locator)
                return
            }
            session.search.lastLanding = landing
            self.showEPUBSearchHighlight(rects: landing.rects, in: epubView)
        }
    }

    /// 古い矩形と進行中の厳密着地を同時に無効化する。
    /// リサイズ・設定変更・本切替の後から旧タスクが戻っても再表示させない。
    func clearEPUBSearchHighlight() {
        epubSession?.search.clearHighlight()
    }

    private func showEPUBSearchHighlight(rects: [CGRect], in view: EPUBReaderView) {
        guard let session = epubSession else { return }
        session.search.highlightHost?.removeFromSuperview()
        let host = EPUBSearchHighlightHostView(frame: view.bounds)
        host.show(rects: rects)
        // ルーペ表示中はレンズの下に置く(ハイライトがレンズ枠の上に描かれないように。
        // cooViewer-532)
        if let loupeHost = epubLoupeHost, loupeHost.superview === view {
            view.addSubview(host, positioned: .below, relativeTo: loupeHost)
        } else {
            view.addSubview(host)
        }
        session.search.highlightHost = host
    }

    private func goToEPUBSearchHit(forward: Bool) {
        guard let session = epubSession else { return }
        guard let model = session.search.model,
              let index = EPUBSearchLogic.selectionIndex(
                current: model.selectedIndex, count: model.hits.count,
                forward: forward) else {
            NSSound.beep()
            return
        }
        selectEPUBSearchHit(at: index)
    }

    /// Esc・モード切替・親窓終了の全経路から同じ状態を破棄する。
    func teardownEPUBSearch(closePanel: Bool = true) {
        epubSession?.search.teardown(closePanel: closePanel)
    }

    /// スナップショット CLI から検索を開始する。
    func debugSearchEPUB(_ query: String) {
        guard let session = epubSession else { return }
        showEPUBSearchMenu(nil)
        session.search.model?.query = query
        startEPUBSearch(query: query, debounce: false)
    }

    /// CLI 検証用: 実際の N/M ラベルと厳密着地の結果を一行へ整形する。
    func debugEPUBSearchLandingOutput() -> String? {
        guard let session = epubSession else { return nil }
        let displayedPage = session.pageLabelText?
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? "\(epubView.map { $0.pageInItem + 1 } ?? 0)/\(max(1, epubView?.pageCountInItem ?? 1))"
        guard session.search.highlightHost != nil, let landing = session.search.lastLanding else {
            // 厳密着地しなかった(近似フォールバックまたは移動なし)場合も実表示を出す
            return "[search-landing] exact=false page=\(displayedPage) "
                + "moves=\(session.search.moveCount) pending=\(session.search.pendingLanding != nil)"
        }
        return "[search-landing] exact=true page=\(displayedPage) "
            + "rects=\(landing.rects.count) text=\(landing.text)"
    }

}
