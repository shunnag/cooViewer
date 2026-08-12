import XCTest
@testable import cooViewer

/// ページめくり効果の向きロジックと設定アクセサのテスト
final class PageTurnAnimationTests: XCTestCase {
    /// 旧データ互換ではないが、保存値の意味は固定(並べ替え禁止)
    func testRawValuesAreStable() {
        XCTAssertEqual(PageTurnAnimation.none.rawValue, 0)
        XCTAssertEqual(PageTurnAnimation.fade.rawValue, 1)
        XCTAssertEqual(PageTurnAnimation.slide.rawValue, 2)
        XCTAssertEqual(PageTurnAnimation.zoomFade.rawValue, 3)
        XCTAssertEqual(PageTurnAnimation.flip.rawValue, 4)
    }

    func testEntersFromLeftFollowsReadingDirection() {
        // 右→左読み: 進むと新ページは左から、戻ると右から
        XCTAssertTrue(PageTurnAnimation.entersFromLeft(
            forward: true, readsFromLeft: false))
        XCTAssertFalse(PageTurnAnimation.entersFromLeft(
            forward: false, readsFromLeft: false))
        // 左→右読み: 進むと右から、戻ると左から
        XCTAssertFalse(PageTurnAnimation.entersFromLeft(
            forward: true, readsFromLeft: true))
        XCTAssertTrue(PageTurnAnimation.entersFromLeft(
            forward: false, readsFromLeft: true))
    }

    @MainActor
    func testSettingsAccessorDefaultsAndRoundtrip() {
        let suiteName = "PageTurnAnimationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        // 既定はなし(オフ)
        XCTAssertEqual(store.pageTurnAnimation, .none)
        store.pageTurnAnimation = .flip
        XCTAssertEqual(store.pageTurnAnimation, .flip)
        XCTAssertEqual(defaults.integer(forKey: "PageTurnAnimation"), 4)
        // 範囲外の保存値はなしへフォールバック
        defaults.set(99, forKey: "PageTurnAnimation")
        XCTAssertEqual(store.pageTurnAnimation, .none)
    }
}
