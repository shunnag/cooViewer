import XCTest
// 表示層 Washi を **import せず** 解析層だけで完結することの証明
// (ヘッドレス利用: CLI・索引・サーバから WashiCore 単体で使える)
import WashiCore

final class WashiCoreHeadlessTests: XCTestCase {
    /// WashiCore の公開 API だけで EPUB を開き、メタデータ・本文検索・
    /// 表紙デコード・読書位置解決まで一通り使える
    func testParseLayerIsSelfSufficient() throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/headless.epub"))
        XCTAssertEqual(publication.metadata.mainTitle, "吾輩は猫である")
        XCTAssertEqual(publication.metadata.authors, ["夏目漱石"])
        XCTAssertFalse(publication.search("猫").isEmpty)
        XCTAssertFalse(try publication.extractText(forSpineIndex: 0).isEmpty)
        XCTAssertNotNil(publication.coverImage(maxPixelSize: 8))
        // EPUBLocator は WashiCore の型(表示層に依存しない)
        let locator = publication.locator(forSpineIndex: 1, progression: 0.5)
        XCTAssertEqual(publication.resolve(locator)?.spineIndex, 1)
    }
}
