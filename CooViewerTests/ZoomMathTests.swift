import XCTest
@testable import cooViewer

/// 連続ピンチズームの状態遷移(純関数)の検証
final class ZoomMathTests: XCTestCase {
    func testUpdatedScaleHardClampsAtLowerBound() {
        // 1.0 未満へは行かない(縮小は表示モード側の役目)
        XCTAssertEqual(ZoomMath.updatedScale(current: 1.0, magnification: -0.5), 1.0)
        XCTAssertEqual(ZoomMath.updatedScale(current: 1.2, magnification: -0.9), 1.0)
    }

    func testUpdatedScaleMultipliesWithinRange() {
        XCTAssertEqual(ZoomMath.updatedScale(current: 2.0, magnification: 0.5), 3.0,
                       accuracy: 0.001)
    }

    func testUpdatedScaleRubberBandsAboveMax() {
        // 上限超は圧縮されて maxZoom を少し超えるだけ(硬い上限にしない)
        let over = ZoomMath.updatedScale(current: ZoomMath.maxZoom, magnification: 1.0)
        XCTAssertGreaterThan(over, ZoomMath.maxZoom)
        XCTAssertLessThan(over, ZoomMath.maxZoom + 1)
    }

    func testSettleTargetSnapsToOneNearBottom() {
        XCTAssertEqual(ZoomMath.settleTarget(scale: 1.05), 1.0)
        XCTAssertEqual(ZoomMath.settleTarget(scale: 1.5), 1.5)
    }

    func testSettleTargetClampsRubberBandToMax() {
        XCTAssertEqual(ZoomMath.settleTarget(scale: ZoomMath.maxZoom + 0.3),
                       ZoomMath.maxZoom)
    }

    func testSettleStepConvergesToTarget() {
        var scale: CGFloat = 3.0
        for _ in 0..<200 {
            scale = ZoomMath.settleStep(current: scale, target: 1.0)
            if scale == 1.0 { break }
        }
        XCTAssertEqual(scale, 1.0)
    }

    func testScaledContentSizeMultipliesAllPages() {
        let base = [CGSize(width: 100, height: 200), CGSize(width: 120, height: 200)]
        let size = ZoomMath.scaledContentSize(baseScaled: base, zoom: 2)
        XCTAssertEqual(size.width, 440)   // (100+120)*2
        XCTAssertEqual(size.height, 400)  // max(200,200)*2
    }

    func testAnchoredScrollOffsetKeepsCursorFixed() {
        // カーソル下のコンテンツ点(比率 0.5)が同じビュー点(300)に留まる
        let content = CGSize(width: 1000, height: 800)
        let available = CGSize(width: 400, height: 400)
        let offset = ZoomMath.anchoredScrollOffset(
            anchorRatio: CGPoint(x: 0.5, y: 0.5),
            cursor: CGPoint(x: 300, y: 300),
            contentSize: content, available: available)
        // pad=0(content>available), 0.5*1000-300 = 200
        XCTAssertEqual(offset.x, 200)
        XCTAssertEqual(offset.y, 100)  // 0.5*800-300
    }

    func testCapBucketSteps() {
        XCTAssertEqual(ZoomMath.capBucket(zoom: 1.0), 1)
        XCTAssertEqual(ZoomMath.capBucket(zoom: 1.8), 2)
        XCTAssertEqual(ZoomMath.capBucket(zoom: 3.5), 4)
    }
}
