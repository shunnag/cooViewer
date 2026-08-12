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
        XCTAssertEqual(PageTurnAnimation.curl.rawValue, 4)
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

    // MARK: - カール幾何(PageCurlGeometry)

    func testCurlStripsFlatAtStart() {
        // θ=0: 全ストリップ平ら(角 0、z=0)でノドから外側へ並ぶ
        let strips = PageCurlGeometry.strips(
            theta: 0, count: 4, stripLength: 10, towardRight: true)
        for (index, strip) in strips.enumerated() {
            XCTAssertEqual(strip.angle, 0, accuracy: 1e-9)
            XCTAssertEqual(strip.offsetX, CGFloat(index) * 10, accuracy: 1e-9)
            XCTAssertEqual(strip.offsetZ, 0, accuracy: 1e-9)
        }
    }

    func testCurlStripsFlatMirroredAtEnd() {
        // θ=π: 全ストリップ平らに反対側へ倒れ切る(角 π、z=0)
        let strips = PageCurlGeometry.strips(
            theta: .pi, count: 4, stripLength: 10, towardRight: true)
        for (index, strip) in strips.enumerated() {
            XCTAssertEqual(strip.angle, .pi, accuracy: 1e-9)
            XCTAssertEqual(strip.offsetX, CGFloat(index) * -10, accuracy: 1e-6)
            XCTAssertEqual(strip.offsetZ, 0, accuracy: 1e-6)
        }
    }

    func testCurlStripsLiftTowardViewerMidTurn() {
        // 途中(θ=π/2)は紙が持ち上がる(z > 0)。曲げで外側ほど角が大きい
        let strips = PageCurlGeometry.strips(
            theta: .pi / 2, count: 6, stripLength: 10, towardRight: false)
        XCTAssertTrue(strips.dropFirst().allSatisfy { $0.offsetZ > 0 })
        XCTAssertLessThan(strips.first!.angle, strips.last!.angle)
    }

    func testCurlLeftLeafAdvancesLeftward() {
        // 左へ伸びるリーフ(towardRight=false)は x が負方向へ連結される
        let strips = PageCurlGeometry.strips(
            theta: 0, count: 3, stripLength: 10, towardRight: false)
        XCTAssertEqual(strips.map(\.offsetX), [0, -10, -20])
    }

    func testBackfaceKeyTimeFindsCrossing() {
        // π/2 を最初に跨いだサンプル位置がキータイムになる
        let samples: [CGFloat] = [0, 0.5, 1.0, 1.6, 2.2, 3.0]
        XCTAssertEqual(PageCurlGeometry.backfaceKeyTime(angleSamples: samples),
                       3.0 / 5.0, accuracy: 1e-9)
        // 跨がなければ 1(切替なし)
        XCTAssertEqual(PageCurlGeometry.backfaceKeyTime(angleSamples: [0, 0.1]), 1)
    }

    func testEasedThetaEndpoints() {
        XCTAssertEqual(PageCurlGeometry.easedTheta(progress: 0), 0)
        XCTAssertEqual(PageCurlGeometry.easedTheta(progress: 1), .pi, accuracy: 1e-9)
        XCTAssertEqual(PageCurlGeometry.easedTheta(progress: 0.5), .pi / 2,
                       accuracy: 1e-9)
    }

    @MainActor
    func testSettingsAccessorDefaultsAndRoundtrip() {
        let suiteName = "PageTurnAnimationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        // 既定はなし(オフ)
        XCTAssertEqual(store.pageTurnAnimation, .none)
        store.pageTurnAnimation = .curl
        XCTAssertEqual(store.pageTurnAnimation, .curl)
        XCTAssertEqual(defaults.integer(forKey: "PageTurnAnimation"), 4)
        // 範囲外の保存値はなしへフォールバック
        defaults.set(99, forKey: "PageTurnAnimation")
        XCTAssertEqual(store.pageTurnAnimation, .none)
    }
}
