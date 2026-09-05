import Foundation
import XCTest
@testable import WashiCore

final class ImagePagePublicationTests: XCTestCase {
    // cooViewer-oxr.6: JS と同一の XHTML で、表紙最適化と通常本文の境界を検証する。
    func testSimpleImagePathUsesVisibleTextAndUniqueSources() throws {
        for fixture in EPUBFixtures.imagePageDetectionCases {
            let publication = try EPUBPublication(
                data: ZipBuilder.build(EPUBFixtures.imagePageEntries(bodyHTML: fixture.body)),
                displayURL: URL(fileURLWithPath: "/tmp/washi-image-detection.epub"))
            let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
            XCTAssertEqual(info.simpleImagePath,
                           fixture.expected ? "OEBPS/images/page.png" : nil, fixture.name)
        }
    }
}
