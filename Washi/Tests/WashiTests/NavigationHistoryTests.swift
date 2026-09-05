import AppKit
import XCTest
@testable import Washi

@MainActor
private final class NavigationHistoryDelegateSpy: EPUBReaderViewDelegate {
    var availabilityChanges: [Bool] = []

    func readerViewNavigationHistoryDidChange(_ view: EPUBReaderView) {
        availabilityChanges.append(view.canGoBack)
    }
}

@MainActor
final class NavigationHistoryTests: XCTestCase {
    private func makeReflowablePublication(
        name: String = "navigation-history"
    ) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/\(name).epub"))
    }

    private func makeFixedLayoutPublication() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.fxlComicEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/navigation-history-fxl.epub"))
    }

    /// cooViewer-oxr.31: 目次ジャンプは元位置を積み、Back はその locator へ戻る。
    func testTOCJumpRecordsOriginAndGoBackReturnsToFirstSpine() throws {
        let publication = try makeReflowablePublication()
        let origin = publication.locator(forSpineIndex: 0, progression: 0.375)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let delegate = NavigationHistoryDelegateSpy()
        view.delegate = delegate
        view.load(publication: publication, at: origin)

        view.go(to: try XCTUnwrap(publication.navigation.toc[safe: 1]))

        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertTrue(view.canGoBack)
        view.goBack()
        XCTAssertEqual(view.currentLocator.spineIndex, origin.spineIndex)
        XCTAssertEqual(view.currentLocator.progression,
                       origin.progression, accuracy: 0.0001)
        XCTAssertFalse(view.canGoBack)
        XCTAssertEqual(delegate.availabilityChanges, [true, false])
    }

    /// cooViewer-oxr.31: 通常のページ送りによる spine 遷移は履歴へ積まない。
    func testGoForwardDoesNotRecordNavigationHistory() throws {
        let publication = try makeFixedLayoutPublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        var settings = view.settings
        settings.pageTurnStyle = .none
        view.settings = settings
        view.load(publication: publication)

        view.goForward()

        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertFalse(view.canGoBack)
    }

    /// cooViewer-oxr.31: ホストが locator を指定するジャンプも元位置を積む。
    func testHostLocatorJumpRecordsOrigin() throws {
        let publication = try makeReflowablePublication()
        let origin = publication.locator(forSpineIndex: 0, progression: 0.25)
        let destination = publication.locator(
            forSpineIndex: 1, progression: 0.6)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.load(publication: publication, at: origin)

        view.go(to: destination)

        XCTAssertTrue(view.canGoBack)
        XCTAssertEqual(view.currentLocator.spineIndex, 1)
        view.goBack()
        XCTAssertEqual(view.currentLocator.spineIndex, origin.spineIndex)
        XCTAssertEqual(view.currentLocator.progression,
                       origin.progression, accuracy: 0.0001)
        XCTAssertFalse(view.canGoBack)
    }

    /// cooViewer-oxr.31: 本文から届く内部リンクも共通の履歴経路を通る。
    func testInternalLinkMessageRecordsOrigin() throws {
        let publication = try makeReflowablePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.load(publication: publication)

        view.handleScriptMessage(["type": "link", "href": "ch2.xhtml"])

        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertTrue(view.canGoBack)
        view.goBack()
        XCTAssertEqual(view.currentSpineIndex, 0)
        XCTAssertFalse(view.canGoBack)
    }

    /// cooViewer-oxr.31: 検索着地の UTF-16 範囲ジャンプも元位置を積む。
    func testTextRangeJumpRecordsOrigin() async throws {
        let publication = try makeReflowablePublication()
        let origin = publication.locator(forSpineIndex: 0, progression: 0.2)
        let destination = publication.locator(
            forSpineIndex: 1, progression: 0.4)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.load(publication: publication, at: origin)

        let navigation = Task { @MainActor in
            await view.go(
                to: destination, textRange: (utf16Offset: 0, utf16Length: 1))
        }
        await Task.yield()

        XCTAssertTrue(view.canGoBack)
        navigation.cancel()
        _ = await navigation.value
        view.goBack()
        XCTAssertEqual(view.currentLocator.spineIndex, origin.spineIndex)
        XCTAssertEqual(view.currentLocator.progression,
                       origin.progression, accuracy: 0.0001)
        XCTAssertFalse(view.canGoBack)
    }

    /// cooViewer-oxr.31: 51 回目の記録では最古だけを落とし、最新 50 件を戻れる。
    func testNavigationHistoryKeepsMostRecentFiftyOrigins() throws {
        let publication = try makeReflowablePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let delegate = NavigationHistoryDelegateSpy()
        view.delegate = delegate
        view.load(publication: publication)

        for step in 1...51 {
            view.go(to: publication.locator(
                forSpineIndex: 0, progression: Double(step) / 100))
        }
        for _ in 0..<50 {
            XCTAssertTrue(view.canGoBack)
            view.goBack()
        }

        XCTAssertFalse(view.canGoBack)
        XCTAssertEqual(view.currentLocator.progression, 0.01, accuracy: 0.0001)
        view.goBack()
        XCTAssertEqual(view.currentLocator.progression, 0.01, accuracy: 0.0001)
        XCTAssertEqual(delegate.availabilityChanges, [true, false])
    }

    /// cooViewer-oxr.31: 内部再読込では履歴を保ち、公開 load では消去する。
    func testReloadKeepsHistoryAndNewLoadClearsIt() throws {
        let first = try makeReflowablePublication(name: "history-first")
        let second = try makeReflowablePublication(name: "history-second")
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.load(publication: first)
        view.go(to: first.locator(forSpineIndex: 1))
        XCTAssertTrue(view.canGoBack)

        var settings = view.settings
        settings.allowsScriptedContent.toggle()
        view.settings = settings
        XCTAssertTrue(view.canGoBack)

        view.load(publication: second)
        XCTAssertFalse(view.canGoBack)
    }

    /// cooViewer-oxr.31: メディアオーバーレイ等の内部経路は明示的に記録を省ける。
    func testContainerPathNavigationCanBypassHistory() throws {
        let publication = try makeReflowablePublication()
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.load(publication: publication)

        view.goToContainerPath(
            publication.readingOrder[1].resolvedContainerPath,
            fragment: nil, recordsHistory: false)

        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertFalse(view.canGoBack)
        view.goToContainerPath(
            publication.readingOrder[0].resolvedContainerPath,
            fragment: nil)
        XCTAssertTrue(view.canGoBack)
        view.goBack()
        XCTAssertEqual(view.currentSpineIndex, 1)
        XCTAssertFalse(view.canGoBack)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
