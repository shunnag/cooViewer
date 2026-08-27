import AppKit
import XCTest
@testable import Washi
@testable import WashiCore

/// 制御可能な census 差替(実 WKWebView を使わず交錯を固定する)。
@MainActor
private final class FakeCensus: ScreenPageCensusing {
    private(set) var invokeCount = 0
    private(set) var invalidateCount = 0
    private(set) var measuredKeys: [String] = []
    var cannedCounts: [Int] = [3, 4]
    /// この集合のキーは measure を継続でブロックする(release で解放)
    var blockedKeys: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    func measure(publication: EPUBPublication, optionsJSON: String,
                 contentSize: NSSize) async -> [Int]? {
        invokeCount += 1
        measuredKeys.append(optionsJSON)
        if blockedKeys.contains(optionsJSON) {
            await withCheckedContinuation { gates[optionsJSON] = $0 }
        }
        return cannedCounts
    }

    func invalidate() { invalidateCount += 1 }

    func release(_ key: String) {
        gates.removeValue(forKey: key)?.resume()
    }
}

@MainActor
final class EPUBScreenAtlasTests: XCTestCase {
    private func makePublication() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/atlas.epub"))
    }

    private func metrics(width: CGFloat) -> EPUBScreenMetrics {
        EPUBScreenMetrics(viewportSize: CGSize(width: width, height: 1000),
                          settings: EPUBReaderSettings())
    }

    /// 条件が満たされるまで MainActor を回して待つ(最大 ~2 秒)
    private func waitUntil(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<400 where !predicate() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testInvalidateRefusesFurtherWork() async throws {
        let fake = FakeCensus()
        let atlas = EPUBScreenAtlas(publication: try makePublication(), census: fake)
        atlas.invalidate()
        let counts = await atlas.screenCounts(metrics: metrics(width: 400))
        XCTAssertNil(counts)  // invalidate 後は nil
        XCTAssertEqual(fake.invokeCount, 0)  // census は呼ばれない
        let thumb = await atlas.thumbnail(
            spineIndex: 0, pageInItem: 0, metrics: metrics(width: 400),
            isDark: false, width: 100)
        XCTAssertNil(thumb)
        XCTAssertEqual(fake.invalidateCount, 1)
    }

    func testConcurrentSameKeyMergesOneMeasure() async throws {
        let fake = FakeCensus()
        let m = metrics(width: 400)
        fake.blockedKeys = [m.censusOptionsJSON]
        let atlas = EPUBScreenAtlas(publication: try makePublication(), census: fake)
        let a = Task { await atlas.screenCounts(metrics: m) }
        await waitUntil { fake.invokeCount == 1 }  // 1 本目が measure に入る
        let b = Task { await atlas.screenCounts(metrics: m) }  // 同キー → 合流
        await waitUntil { atlas.inFlightMeasureKeys().contains(m.censusOptionsJSON) }
        fake.release(m.censusOptionsJSON)
        let (ra, rb) = await (a.value, b.value)
        XCTAssertEqual(ra, [3, 4])
        XCTAssertEqual(rb, [3, 4])
        XCTAssertEqual(fake.invokeCount, 1)  // measure は 1 回だけ
    }

    /// 実行待ちの K1 を K2 が追い越したあと K1 が再要求されると、newest を K1 に
    /// 戻すため K1 の guard が通り、表示中メトリクスの counts が得られる
    func testReRequestOfRunningKeyRestoresNewest() async throws {
        let fake = FakeCensus()
        let k0 = metrics(width: 400)
        let k1 = metrics(width: 600)
        let k2 = metrics(width: 800)
        // K0 は FIFO を占有するためブロック(K1 は K0 の後ろで待つ)
        fake.blockedKeys = [k0.censusOptionsJSON]
        let atlas = EPUBScreenAtlas(publication: try makePublication(), census: fake)

        let t0 = Task { await atlas.screenCounts(metrics: k0) }
        await waitUntil { fake.invokeCount == 1 }  // K0 measure 入り(FIFO 先頭)
        let t1 = Task { await atlas.screenCounts(metrics: k1) }  // K0 の後ろで待機
        await waitUntil { atlas.inFlightMeasureKeys().contains(k1.censusOptionsJSON) }
        let t2 = Task { await atlas.screenCounts(metrics: k2) }  // newest=K2
        await waitUntil { atlas.inFlightMeasureKeys().contains(k2.censusOptionsJSON) }
        let t1again = Task { await atlas.screenCounts(metrics: k1) }  // 合流 → newest=K1 に復帰
        // K0 を解放 → FIFO が流れ K1 の guard が評価される
        fake.release(k0.censusOptionsJSON)

        let r1 = await t1.value
        let r1again = await t1again.value
        XCTAssertEqual(r1, [3, 4], "K1 は表示中メトリクスなので counts を返す")
        XCTAssertEqual(r1again, [3, 4])
        XCTAssertTrue(fake.measuredKeys.contains(k1.censusOptionsJSON),
                      "K1 の measure が実行されること")
        _ = await (t0.value, t2.value)
    }
}
