import AppKit
import WebKit
import XCTest
@testable import Washi

@MainActor
final class EPUBReaderViewRegressionTests: XCTestCase {
    private func makePublication() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/washi-reader-regression.epub"))
    }

    private func setupOptions(of view: EPUBReaderView) throws -> [String: Any] {
        let data = try XCTUnwrap(view.setupOptionsJSON().data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// spreadInsets 適用後の狭い実幅ではなく、基準余白の幅でライブ側も
    /// census と同じ見開き判定をする
    func testSetupSpreadMatchesScreenMetricsAcrossMismatchWindow() throws {
        var settings = EPUBReaderSettings()
        settings.insets = EPUBReaderInsets(
            top: 24, left: 56, bottom: 24, right: 56)
        settings.spreadInsets = EPUBReaderInsets(
            top: 24, left: 100, bottom: 24, right: 100)

        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 812, height: 900))
        view.settings = settings
        for width in [CGFloat(812), 850, 899] {
            view.frame.size.width = width
            let options = try setupOptions(of: view)
            let liveSpread = try XCTUnwrap(options["spread"] as? Bool)
            let metrics = EPUBScreenMetrics(
                viewportSize: view.bounds.size, settings: settings)
            XCTAssertEqual(liveSpread, metrics.pagesPerScreen == 2,
                           "viewport width: \(width)")
        }
    }

    /// meta refresh などの .other は期待外なら reader 経由へ戻し、直前に
    /// 記録した loadSpineItem 自身の .other は一度だけ通す
    func testUnexpectedOtherNavigationRoutesWithoutConsumingExpectedLoad() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml")
        XCTAssertEqual(
            gate.disposition(
                for: "OEBPS/text/ch1.xhtml", navigationType: .linkActivated),
            .routeThroughReader)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch2.xhtml", navigationType: .other),
            .routeThroughReader)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .allowExpectedLoad)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .routeThroughReader)
    }

    /// 高速な spine 移動で decide が前後しても、自分が発行した各ロードを
    /// 文書内遷移と誤認しない
    func testCompetingExpectedSpineLoadsAreBothAllowed() {
        var gate = SpineNavigationGate()
        gate.expect("OEBPS/text/ch1.xhtml")
        gate.expect("OEBPS/text/ch2.xhtml")
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch1.xhtml", navigationType: .other),
            .allowExpectedLoad)
        XCTAssertEqual(
            gate.disposition(for: "OEBPS/text/ch2.xhtml", navigationType: .other),
            .allowExpectedLoad)
    }

    /// JS へ復元先を適用した直後、最初の pageChanged より前に保存位置を
    /// 読んでも progression を失わない
    func testRestoreLocatorSurvivesSetupTargetApplication() throws {
        let publication = try makePublication()
        let locator = publication.locator(forSpineIndex: 1, progression: 0.625)
        let view = EPUBReaderView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.load(publication: publication, at: locator)

        view.applyPendingTargetAfterSetup()

        XCTAssertEqual(view.currentLocator.spineIndex, 1)
        XCTAssertEqual(view.currentLocator.progression, 0.625, accuracy: 0.0001)
    }
}
