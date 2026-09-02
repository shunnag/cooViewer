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
    var cannedCountsByKey: [String: [Int]] = [:]
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
        return cannedCountsByKey[optionsJSON] ?? cannedCounts
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

    private func makeSpreadPublication(
        _ spread: RenditionSpread, bodyHTML: String = "<p>本文</p>"
    ) throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(
                EPUBFixtures.reflowSpreadEntries(
                    renditionSpread: spread, bodyHTML: bodyHTML),
                method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/atlas-\(spread.rawValue).epub"))
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
        let plan = await atlas.screenPlan(metrics: metrics(width: 400))
        XCTAssertNil(plan)
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

    func testNonAutoSpreadFixturesParseDocumentWideDeclaration() throws {
        for spread in [RenditionSpread.none, .both, .landscape] {
            let publication = try makeSpreadPublication(spread)
            XCTAssertEqual(publication.metadata.rendition.spread, spread)
        }
    }

    func testScreenPlanMeasuresAndReturnsDerivedSpreadAtomically() async throws {
        let fake = FakeCensus()
        let publication = try makeSpreadPublication(.both)
        let atlas = EPUBScreenAtlas(publication: publication, census: fake)
        let base = metrics(width: 640)
        let derived = base.applyingRenditionSpread(.both)

        let measuredPlan = await atlas.screenPlan(metrics: base)
        let plan = try XCTUnwrap(measuredPlan)

        XCTAssertEqual(plan.counts, [3, 4])
        XCTAssertEqual(plan.pagesPerScreen, 2)
        XCTAssertEqual(fake.measuredKeys, [derived.censusOptionsJSON])
        let data = try XCTUnwrap(fake.measuredKeys.first?.data(using: .utf8))
        let options = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(options["spread"] as? Bool, true)
    }

    func testAutoScreenPlanMatchesLegacyCountsAndReusesCache() async throws {
        let fake = FakeCensus()
        let publication = try makeSpreadPublication(.auto)
        let atlas = EPUBScreenAtlas(publication: publication, census: fake)
        let base = metrics(width: 800)

        let legacy = await atlas.screenCounts(metrics: base)
        let plan = await atlas.screenPlan(metrics: base)

        XCTAssertEqual(base.applyingRenditionSpread(.auto).cacheKey,
                       base.cacheKey)
        XCTAssertEqual(plan?.counts, legacy)
        XCTAssertEqual(plan?.pagesPerScreen, base.pagesPerScreen)
        XCTAssertEqual(fake.invokeCount, 1)
        XCTAssertEqual(fake.measuredKeys, [base.censusOptionsJSON])
    }

    /// 旧 API は基底キー、新 API は書籍の派生キーを使う差分オラクル
    func testLegacyCountsAndScreenPlanUseDifferentSpreadPlans() async throws {
        let fake = FakeCensus()
        let longBody = "<p>\(String(repeating: "長い本文。", count: 2_000))</p>"
        let publication = try makeSpreadPublication(.both, bodyHTML: longBody)
        let atlas = EPUBScreenAtlas(publication: publication, census: fake)
        let base = metrics(width: 640)
        let derived = base.applyingRenditionSpread(.both)
        fake.cannedCountsByKey = [
            base.censusOptionsJSON: [4],
            derived.censusOptionsJSON: [8],
        ]

        let legacy = await atlas.screenCounts(metrics: base)
        let plan = await atlas.screenPlan(metrics: base)

        XCTAssertEqual(legacy, [4])
        XCTAssertEqual(plan?.counts, [8])
        XCTAssertEqual(plan?.pagesPerScreen, 2)
        XCTAssertEqual(fake.measuredKeys,
                       [base.censusOptionsJSON, derived.censusOptionsJSON])
    }

    /// 実 census でも both の論理ページ数が単ページ計画より増えることを比較する
    func testRealCensusDifferentialOracleForBothFixture() async throws {
        let longBody = "<p>\(String(repeating: "長い本文。", count: 3_000))</p>"
        let publication = try makeSpreadPublication(.both, bodyHTML: longBody)
        let atlas = EPUBScreenAtlas(publication: publication)
        defer { atlas.invalidate() }
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        let base = EPUBScreenMetrics(
            viewportSize: CGSize(width: 640, height: 400), settings: settings)

        let measuredLegacy = await atlas.screenCounts(metrics: base)
        let measuredPlan = await atlas.screenPlan(metrics: base)
        let legacy = try XCTUnwrap(measuredLegacy)
        let plan = try XCTUnwrap(measuredPlan)
        let singleCount = try XCTUnwrap(legacy.first)
        let spreadCount = try XCTUnwrap(plan.counts.first)

        XCTAssertEqual(plan.pagesPerScreen, 2)
        XCTAssertGreaterThan(spreadCount, singleCount)
        let ratio = Double(spreadCount) / Double(singleCount)
        XCTAssertGreaterThan(ratio, 1.5)
        XCTAssertLessThan(ratio, 3.0)
    }
}
