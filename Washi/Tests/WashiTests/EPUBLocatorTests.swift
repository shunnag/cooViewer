import Foundation
import XCTest
@testable import WashiCore

final class EPUBLocatorTests: XCTestCase {
    /// cooViewer-oxr.73: 合成 Codable が initializer の progression
    /// clamp を迂回していた経路を固定する。
    func testDecodeClampsPersistedProgression() throws {
        let decoder = JSONDecoder()
        let high = try decoder.decode(
            EPUBLocator.self,
            from: Data(#"{"spineIndex":2,"progression":1e300}"#.utf8))
        let low = try decoder.decode(
            EPUBLocator.self,
            from: Data(#"{"spineIndex":2,"progression":-3}"#.utf8))

        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN")
        let nan = try decoder.decode(
            EPUBLocator.self,
            from: Data(#"{"spineIndex":2,"progression":"NaN"}"#.utf8))

        XCTAssertEqual(high.progression, 1)
        XCTAssertEqual(low.progression, 0)
        XCTAssertEqual(nan.progression, 0)
    }

    /// cooViewer-oxr.73: 公開 setter を保ちつつ、代入も初期化・復号と
    /// 同じ不変条件へ揃える。
    func testProgressionSetterClampsHostileValues() {
        var locator = EPUBLocator(spineIndex: 0)
        locator.progression = 1e300
        XCTAssertEqual(locator.progression, 1)
        locator.progression = -3
        XCTAssertEqual(locator.progression, 0)
        locator.progression = .nan
        XCTAssertEqual(locator.progression, 0)
    }
}
