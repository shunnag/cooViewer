import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
private final class InternalLinkDelegateSpy: EPUBReaderViewDelegate {
    var followsLinks = true
    var links: [EPUBInternalLink] = []
    var moveCount = 0

    func readerView(_ view: EPUBReaderView,
                    shouldFollowInternalLink link: EPUBInternalLink) -> Bool {
        links.append(link)
        return followsLinks
    }

    func readerView(_ view: EPUBReaderView, didMoveTo locator: EPUBLocator,
                    pageInItem: Int, pageCountInItem: Int) {
        moveCount += 1
    }
}

/// cooViewer-oxr.32: 内部リンクの委譲、注釈抽出、非表示設定を検証する。
@MainActor
final class InternalLinkTests: XCTestCase {
    private func makePublication(
        firstBody: String,
        secondBody: String? = nil,
        name: String
    ) throws -> EPUBPublication {
        var entries = EPUBFixtures.singleSpineEntries(bodyHTML: firstBody)
        if let secondBody {
            let packageIndex = try XCTUnwrap(
                entries.firstIndex { $0.name == "OEBPS/package.opf" })
            let package = String(decoding: entries[packageIndex].data, as: UTF8.self)
                .replacingOccurrences(
                    of: "</manifest>",
                    with: "<item id=\"notes\" href=\"text/notes.xhtml\" "
                        + "media-type=\"application/xhtml+xml\"/></manifest>")
                .replacingOccurrences(
                    of: "</spine>",
                    with: "<itemref idref=\"notes\"/></spine>")
            entries[packageIndex].data = Data(package.utf8)
            let xhtml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"
                      xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja">
                  <head><meta charset="UTF-8"/><title>Notes</title></head>
                  <body>\(secondBody)</body>
                </html>
                """
            entries.append(("OEBPS/text/notes.xhtml", Data(xhtml.utf8)))
        }
        return try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/\(name).epub"))
    }

    private func makeWindow(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000),
                                size: view.frame.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = view
        return window
    }

    private func close(_ window: NSWindow, view: EPUBReaderView) {
        view.cancelPageCensus()
        view.delegate = nil
        window.contentView = nil
        window.close()
    }

    private func waitUntil(
        timeout: Duration = .seconds(8),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func requireSendable<T: Sendable>(_ value: T) -> T { value }

    /// cooViewer-oxr.32: 公開初期化子が全リンク情報を保持し、Sendable である。
    func testInternalLinkInitializerPublishesEveryFieldAndIsSendable() {
        let rect = CGRect(x: 12, y: 34, width: 56, height: 18)
        let link = requireSendable(EPUBInternalLink(
            href: "notes.xhtml#n1",
            containerPath: "OEBPS/text/notes.xhtml",
            fragment: "n1",
            targetSpineIndex: 1,
            epubType: "noteref",
            role: "doc-noteref",
            isNoteReference: true,
            hasBacklink: true,
            targetEpubType: "footnote",
            anchorRect: rect))

        XCTAssertEqual(link.href, "notes.xhtml#n1")
        XCTAssertEqual(link.containerPath, "OEBPS/text/notes.xhtml")
        XCTAssertEqual(link.fragment, "n1")
        XCTAssertEqual(link.targetSpineIndex, 1)
        XCTAssertEqual(link.epubType, "noteref")
        XCTAssertEqual(link.role, "doc-noteref")
        XCTAssertTrue(link.isNoteReference)
        XCTAssertTrue(link.hasBacklink)
        XCTAssertEqual(link.targetEpubType, "footnote")
        XCTAssertEqual(link.anchorRect, rect)
    }

    /// cooViewer-oxr.32: delegate が拒否した内部リンクは位置も履歴も変えない。
    func testDelegateVetoPreservesPositionPageAndNavigationHistory() throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-internal-link-veto.epub"))
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let delegate = InternalLinkDelegateSpy()
        delegate.followsLinks = false
        view.delegate = delegate
        view.load(publication: publication)
        let beforeLocator = view.currentLocator
        let beforeSpine = view.currentSpineIndex
        let beforePage = view.pageInItem
        let beforePageCount = view.pageCountInItem
        let webView = try XCTUnwrap(
            view.subviews.first { $0 is WKWebView } as? WKWebView)
        let raw = CGRect(x: 12, y: 34, width: 56, height: 18)
        let localY = webView.isFlipped
            ? raw.minY : webView.bounds.height - raw.minY - raw.height
        let expectedRect = webView.convert(
            CGRect(x: raw.minX, y: localY,
                   width: raw.width, height: raw.height),
            to: view)

        view.handleScriptMessage([
            "type": "link",
            "href": "ch2.xhtml#n2",
            "epubType": "noteref",
            "role": "doc-noteref",
            "anchorId": "ref2",
            "anchorRect": [
                "x": Double(raw.minX), "y": Double(raw.minY),
                "w": Double(raw.width), "h": Double(raw.height),
            ],
            "backlink": true,
            "targetTag": "aside",
            "targetEpubType": "footnote",
        ])

        XCTAssertEqual(delegate.links.count, 1)
        let link = try XCTUnwrap(delegate.links.first)
        XCTAssertEqual(link.href, "ch2.xhtml#n2")
        XCTAssertEqual(link.containerPath,
                       publication.readingOrder[1].resolvedContainerPath)
        XCTAssertEqual(link.fragment, "n2")
        XCTAssertEqual(link.targetSpineIndex, 1)
        XCTAssertEqual(link.epubType, "noteref")
        XCTAssertEqual(link.role, "doc-noteref")
        XCTAssertTrue(link.isNoteReference)
        XCTAssertTrue(link.hasBacklink)
        XCTAssertEqual(link.targetEpubType, "footnote")
        let actualRect = try XCTUnwrap(link.anchorRect)
        XCTAssertEqual(actualRect.minX, expectedRect.minX, accuracy: 0.001)
        XCTAssertEqual(actualRect.minY, expectedRect.minY, accuracy: 0.001)
        XCTAssertEqual(actualRect.width, expectedRect.width, accuracy: 0.001)
        XCTAssertEqual(actualRect.height, expectedRect.height, accuracy: 0.001)

        XCTAssertEqual(view.currentLocator, beforeLocator)
        XCTAssertEqual(view.currentSpineIndex, beforeSpine)
        XCTAssertEqual(view.pageInItem, beforePage)
        XCTAssertEqual(view.pageCountInItem, beforePageCount)
        XCTAssertFalse(view.canGoBack)
    }

    /// cooViewer-oxr.32: Explicitly following a vetoed note link uses the
    /// default navigation path, lands on its target, and records Back history.
    func testFollowBypassesDelegateVetoAndRecordsHistoryOffscreen() async throws {
        let precedingText = (1...80).map { number in
            "<p>脚注前の本文 \(number) \(String(repeating: "長い本文。", count: 12))</p>"
        }.joined()
        let publication = try makePublication(
            firstBody: """
                <p xmlns:epub="http://www.idpf.org/2007/ops">
                  <a id="ref2" epub:type="noteref" role="doc-noteref"
                     href="notes.xhtml#n2">注2</a>
                </p>
                """,
            secondBody: precedingText + """
                <aside epub:type="footnote" role="doc-footnote">
                  <p id="n2">別章の脚注</p>
                </aside>
                """,
            name: "washi-follow-vetoed-note")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = view.settings
        settings.columnMode = .single
        settings.pageTurnStyle = .none
        settings.insets = .zero
        view.settings = settings
        let delegate = InternalLinkDelegateSpy()
        delegate.followsLinks = false
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        guard await waitUntil({ delegate.moveCount > 0 }) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }

        let moveCountBeforeFollowing = delegate.moveCount
        view.handleScriptMessage([
            "type": "link",
            "href": "notes.xhtml#n2",
            "epubType": "noteref",
            "role": "doc-noteref",
        ])

        XCTAssertEqual(delegate.links.count, 1)
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertFalse(view.canGoBack)
        let link = try XCTUnwrap(delegate.links.first)

        view.follow(link)

        let didLandOnNote = await waitUntil {
            delegate.moveCount > moveCountBeforeFollowing
                && view.currentSpineIndex == 1
                && view.pageInItem > 0
        }
        XCTAssertTrue(didLandOnNote)
        XCTAssertEqual(view.currentSpineIndex, link.targetSpineIndex)
        XCTAssertGreaterThan(view.pageInItem, 0)
        XCTAssertTrue(view.canGoBack)
        XCTAssertEqual(delegate.links.count, 1,
                       "follow(_:) must not ask the delegate again")
    }

    /// cooViewer-oxr.32: 同一文書の注釈はコンテナ全体を返し、戻りリンクを除く。
    func testSameDocumentNoteContentRemovesBacklinkAndPreservesHTML() async throws {
        let body = """
            <div xmlns:epub="http://www.idpf.org/2007/ops">
              <p><a id="ref1" epub:type="noteref" href="#n1">注1</a></p>
              <aside epub:type="footnote" role="doc-footnote">
                <p id="n1">脚注本文<em>強調箇所</em><a href="#ref1">戻る印</a></p>
                <p>同じ注釈コンテナの補足</p>
              </aside>
            </div>
            """
        let publication = try makePublication(
            firstBody: body, name: "washi-same-document-note")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let delegate = InternalLinkDelegateSpy()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        guard await waitUntil({ delegate.moveCount > 0 }) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }
        let link = EPUBInternalLink(
            href: "#n1",
            containerPath: publication.readingOrder[0].resolvedContainerPath,
            fragment: "n1",
            targetSpineIndex: 0,
            epubType: "noteref",
            role: nil,
            isNoteReference: true,
            hasBacklink: true,
            targetEpubType: "footnote",
            anchorRect: nil)

        let extracted = await view.noteContent(for: link)
        let note = try XCTUnwrap(extracted)
        _ = requireSendable(note)
        XCTAssertEqual(note.sourceSpineIndex, 0)
        XCTAssertTrue(note.text.contains("脚注本文"))
        XCTAssertTrue(note.text.contains("強調箇所"))
        XCTAssertTrue(note.text.contains("同じ注釈コンテナの補足"))
        XCTAssertFalse(note.text.contains("戻る印"))
        let html = try XCTUnwrap(note.html)
        XCTAssertTrue(html.contains("<em"))
        XCTAssertTrue(html.contains("強調箇所"))
        XCTAssertFalse(html.contains("#ref1"))
        XCTAssertFalse(html.contains("戻る印"))
    }

    /// cooViewer-oxr.32: 別 spine の注釈は WebKit なしで可読本文を抽出する。
    func testCrossDocumentNoteContentUsesHeadlessExtraction() async throws {
        let secondBody = """
            <section epub:type="endnote" role="doc-endnote">
              <p id="n2">別章の注<ruby>漢<rt>かん</rt></ruby><a href="#ref2">戻る印</a></p>
              <p>同じ注釈コンテナの補足</p>
            </section>
            """
        let publication = try makePublication(
            firstBody: "<p id=\"ref2\">第一章</p>",
            secondBody: secondBody,
            name: "washi-cross-document-note")
        let view = EPUBReaderView(frame: .zero)
        view.load(publication: publication)
        defer { view.cancelPageCensus() }
        let link = EPUBInternalLink(
            href: "notes.xhtml#n2",
            containerPath: publication.readingOrder[1].resolvedContainerPath,
            fragment: "n2",
            targetSpineIndex: 1,
            epubType: "noteref",
            role: "doc-noteref",
            isNoteReference: true,
            hasBacklink: true,
            targetEpubType: "endnote",
            anchorRect: nil)

        let extracted = await view.noteContent(for: link)
        let note = try XCTUnwrap(extracted)
        _ = requireSendable(note)
        XCTAssertEqual(note.sourceSpineIndex, 1)
        XCTAssertNil(note.html)
        XCTAssertTrue(note.text.contains("別章の注漢"))
        XCTAssertTrue(note.text.contains("同じ注釈コンテナの補足"))
        XCTAssertFalse(note.text.contains("かん"), "ルビ読みは可読本文から除く")
        XCTAssertFalse(note.text.contains("戻る印"))
    }

    /// cooViewer-oxr.32: 注釈 aside の表示設定は census の同一性へ含める。
    func testHidesFootnoteAsidesChangesPaginationCacheKeyAndCSS() {
        let base = EPUBReaderSettings()
        XCTAssertFalse(base.hidesFootnoteAsides)
        var hidden = base
        hidden.hidesFootnoteAsides = true

        let size = CGSize(width: 640, height: 400)
        XCTAssertNotEqual(
            EPUBScreenMetrics(viewportSize: size, settings: base).cacheKey,
            EPUBScreenMetrics(viewportSize: size, settings: hidden).cacheKey)
        let css = hidden.layoutAffectingCSS()
        XCTAssertTrue(css.contains(
            "@namespace epub url(http://www.idpf.org/2007/ops);"))
        XCTAssertTrue(css.contains(#"aside[epub|type~="footnote"]"#))
        XCTAssertTrue(css.contains(#"aside[epub|type~="endnote"]"#))
        XCTAssertTrue(css.contains(#"aside[epub|type~="rearnote"]"#))
        XCTAssertTrue(css.contains(#"aside[role="doc-footnote"]"#))
        XCTAssertTrue(css.contains(#"aside[role="doc-endnote"]"#))
    }

    /// cooViewer-oxr.32: 長い注釈 aside を隠す変更は現在項目を再ページ割りする。
    func testHidingLongFootnoteAsideReducesPageCount() async throws {
        let noteParagraphs = (1...120).map { number in
            "<p>脚注 \(number) \(String(repeating: "長い注釈本文。", count: 12))</p>"
        }.joined()
        let body = """
            <div xmlns:epub="http://www.idpf.org/2007/ops">
              <p>短い本文</p>
              <aside epub:type="footnote" role="doc-footnote">\(noteParagraphs)</aside>
            </div>
            """
        let publication = try makePublication(
            firstBody: body, name: "washi-long-footnote-pagination")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = view.settings
        settings.columnMode = .single
        settings.pageTurnStyle = .none
        view.settings = settings
        let delegate = InternalLinkDelegateSpy()
        view.delegate = delegate
        let window = makeWindow(containing: view)
        defer { close(window, view: view) }
        view.load(publication: publication)
        guard await waitUntil({ delegate.moveCount > 0 }) else {
            throw XCTSkip("WKWebView navigation is unavailable in this sandbox")
        }
        let visiblePageCount = view.pageCountInItem
        XCTAssertGreaterThan(visiblePageCount, 1)

        var hidden = view.settings
        hidden.hidesFootnoteAsides = true
        view.settings = hidden

        let didRepaginate = await waitUntil {
            view.pageCountInItem < visiblePageCount
        }
        XCTAssertTrue(didRepaginate)
        XCTAssertEqual(view.pageCountInItem, 1)
    }
}
