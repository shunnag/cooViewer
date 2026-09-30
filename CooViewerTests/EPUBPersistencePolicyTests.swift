import Foundation
import Washi
import XCTest

@testable import cooViewer

/// 本の切替中に旧 WKWebView の通知を新 URL へ保存しないことを検証する
/// （cooViewer-oxr.23、設計書 §2.4）。
final class EPUBPersistencePolicyTests: XCTestCase {
    func testCallbackPersistenceRequiresIdenticalPublication() throws {
        let data = makeEPUBData()
        let url = URL(fileURLWithPath: "/test/persistence.epub")
        let current = try EPUBPublication(data: data, displayURL: url)
        let other = try EPUBPublication(data: data, displayURL: url)

        XCTAssertTrue(EPUBPersistencePolicy.shouldPersist(
            callbackPublication: current, currentPublication: current))
        XCTAssertFalse(EPUBPersistencePolicy.shouldPersist(
            callbackPublication: other, currentPublication: current))
        XCTAssertFalse(EPUBPersistencePolicy.shouldPersist(
            callbackPublication: nil, currentPublication: current))
    }

    func testMaxLatencySavesInitiallyAndAtThirtySeconds() {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(EPUBPersistencePolicy.shouldSaveNow(
            lastSave: nil, now: origin))
        XCTAssertFalse(EPUBPersistencePolicy.shouldSaveNow(
            lastSave: origin, now: origin.addingTimeInterval(29.999)))
        XCTAssertTrue(EPUBPersistencePolicy.shouldSaveNow(
            lastSave: origin, now: origin.addingTimeInterval(30)))
    }

    func testContinuousNotificationsDoNotRetryEveryFailedSave() {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)
        var schedule = EPUBSaveSchedule()
        var attempts = 0
        // 1 秒に 4 回の移動通知が 2 分続き、ストレージが保存に失敗する場合。
        for step in 0...480 {
            let now = origin.addingTimeInterval(Double(step) / 4)
            if schedule.shouldSaveNow(at: now) {
                attempts += 1
                schedule.recordAttempt(at: now, succeeded: false)
            }
        }
        XCTAssertEqual(attempts, 5)
        XCTAssertNil(schedule.lastSuccessfulSaveAt)
    }

    func testSuccessfulRetryStartsANewSavePeriod() {
        let origin = Date(timeIntervalSinceReferenceDate: 1_000)
        var schedule = EPUBSaveSchedule()
        schedule.recordAttempt(at: origin, succeeded: false)
        XCTAssertFalse(schedule.shouldSaveNow(at: origin.addingTimeInterval(29.999)))
        let recovered = origin.addingTimeInterval(30)
        XCTAssertTrue(schedule.shouldSaveNow(at: recovered))
        schedule.recordAttempt(at: recovered, succeeded: true)
        XCTAssertEqual(schedule.lastSuccessfulSaveAt, recovered)
        XCTAssertFalse(schedule.shouldSaveNow(at: recovered.addingTimeInterval(29.999)))
        XCTAssertTrue(schedule.shouldSaveNow(at: recovered.addingTimeInterval(30)))
    }

    private func makeEPUBData() -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/package.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let package = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
          unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">persistence-policy</dc:identifier>
            <dc:title>保存判定</dc:title><dc:language>ja</dc:language>
          </metadata>
          <manifest><item id="c" href="c.xhtml"
            media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="c"/></spine>
        </package>
        """
        let chapter = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>本文</title></head>
          <body><p>本文</p></body></html>
        """
        return TestFixtures.storedZip(entries: [
            (Array("mimetype".utf8), Data("application/epub+zip".utf8)),
            (Array("META-INF/container.xml".utf8), Data(container.utf8)),
            (Array("OEBPS/package.opf".utf8), Data(package.utf8)),
            (Array("OEBPS/c.xhtml".utf8), Data(chapter.utf8)),
        ])
    }
}
