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

/// サムネイルへ渡った派生後の描画条件を記録する差替。
@MainActor
private final class FakeThumbnailRenderer: ScreenThumbnailRendering {
    private(set) var optionsJSON: String?
    private(set) var contentSize: NSSize?
    private(set) var invalidateCount = 0

    func thumbnail(spineIndex: Int, pageInItem: Int, optionsJSON: String,
                   contentSize: NSSize, snapshotWidth: CGFloat) async -> CGImage? {
        self.optionsJSON = optionsJSON
        self.contentSize = contentSize
        return nil
    }

    func invalidate() { invalidateCount += 1 }
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
        let a = Task { await atlas.screenPlan(metrics: m) }
        await waitUntil { fake.invokeCount == 1 }  // 1 本目が measure に入る
        let b = Task { await atlas.screenPlan(metrics: m) }  // 同キー → 合流
        await waitUntil { atlas.inFlightMeasureKeys().contains(m.censusOptionsJSON) }
        fake.release(m.censusOptionsJSON)
        let (ra, rb) = await (a.value, b.value)
        XCTAssertEqual(ra?.counts, [3, 4])
        XCTAssertEqual(rb?.counts, [3, 4])
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

        let t0 = Task { await atlas.screenPlan(metrics: k0) }
        await waitUntil { fake.invokeCount == 1 }  // K0 measure 入り(FIFO 先頭)
        let t1 = Task { await atlas.screenPlan(metrics: k1) }  // K0 の後ろで待機
        await waitUntil { atlas.inFlightMeasureKeys().contains(k1.censusOptionsJSON) }
        let t2 = Task { await atlas.screenPlan(metrics: k2) }  // newest=K2
        await waitUntil { atlas.inFlightMeasureKeys().contains(k2.censusOptionsJSON) }
        let t1again = Task { await atlas.screenPlan(metrics: k1) }  // 合流 → newest=K1 に復帰
        // K0 を解放 → FIFO が流れ K1 の guard が評価される
        fake.release(k0.censusOptionsJSON)

        let r1 = await t1.value
        let r1again = await t1again.value
        XCTAssertEqual(r1?.counts, [3, 4], "K1 は表示中メトリクスなので counts を返す")
        XCTAssertEqual(r1again?.counts, [3, 4])
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

    func testAutoScreenPlanReusesCacheWithoutChangingMetrics() async throws {
        let fake = FakeCensus()
        let publication = try makeSpreadPublication(.auto)
        let atlas = EPUBScreenAtlas(publication: publication, census: fake)
        let base = metrics(width: 800)

        let first = await atlas.screenPlan(metrics: base)
        let second = await atlas.screenPlan(metrics: base)

        XCTAssertEqual(base.applyingRenditionSpread(.auto).cacheKey,
                       base.cacheKey)
        XCTAssertEqual(first?.counts, [3, 4])
        XCTAssertEqual(second?.counts, first?.counts)
        XCTAssertEqual(first?.pagesPerScreen, base.pagesPerScreen)
        XCTAssertEqual(second?.pagesPerScreen, base.pagesPerScreen)
        XCTAssertEqual(fake.invokeCount, 1)
        XCTAssertEqual(fake.measuredKeys, [base.censusOptionsJSON])
    }

    /// auto 本と both 本の計画がそれぞれ基底キーと派生キーを使う差分オラクル
    func testAutoAndBothScreenPlansUseDifferentSpreadPlans() async throws {
        let fake = FakeCensus()
        let longBody = "<p>\(String(repeating: "長い本文。", count: 2_000))</p>"
        let autoAtlas = EPUBScreenAtlas(
            publication: try makeSpreadPublication(.auto, bodyHTML: longBody),
            census: fake)
        let bothAtlas = EPUBScreenAtlas(
            publication: try makeSpreadPublication(.both, bodyHTML: longBody),
            census: fake)
        let base = metrics(width: 640)
        let derived = base.applyingRenditionSpread(.both)
        fake.cannedCountsByKey = [
            base.censusOptionsJSON: [4],
            derived.censusOptionsJSON: [8],
        ]

        let autoPlan = await autoAtlas.screenPlan(metrics: base)
        let bothPlan = await bothAtlas.screenPlan(metrics: base)

        XCTAssertEqual(autoPlan?.counts, [4])
        XCTAssertEqual(autoPlan?.pagesPerScreen, 1)
        XCTAssertEqual(bothPlan?.counts, [8])
        XCTAssertEqual(bothPlan?.pagesPerScreen, 2)
        XCTAssertEqual(fake.measuredKeys,
                       [base.censusOptionsJSON, derived.censusOptionsJSON])
    }

    func testThumbnailUsesPublicationDerivedMetrics() async throws {
        let fakeCensus = FakeCensus()
        let fakeThumbnail = FakeThumbnailRenderer()
        let publication = try makeSpreadPublication(.both)
        let atlas = EPUBScreenAtlas(
            publication: publication, census: fakeCensus,
            renderer: fakeThumbnail)
        let base = metrics(width: 640)
        let derived = base.applyingRenditionSpread(.both)

        _ = await atlas.thumbnail(
            spineIndex: 0, pageInItem: 0, metrics: base,
            isDark: false, width: 100)

        XCTAssertEqual(fakeThumbnail.optionsJSON,
                       derived.themedOptionsJSON(isDark: false))
        XCTAssertEqual(fakeThumbnail.contentSize, derived.contentSize)
        let data = try XCTUnwrap(fakeThumbnail.optionsJSON?.data(using: .utf8))
        let options = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(options["spread"] as? Bool, true)
    }

    /// 実 census でも both の論理ページ数が単ページ計画より増えることを比較する
    func testRealCensusDifferentialOracleForBothFixture() async throws {
        let longBody = "<p>\(String(repeating: "長い本文。", count: 3_000))</p>"
        let autoAtlas = EPUBScreenAtlas(publication:
            try makeSpreadPublication(.auto, bodyHTML: longBody))
        let bothAtlas = EPUBScreenAtlas(publication:
            try makeSpreadPublication(.both, bodyHTML: longBody))
        defer {
            autoAtlas.invalidate()
            bothAtlas.invalidate()
        }
        var settings = EPUBReaderSettings()
        settings.insets = .zero
        let base = EPUBScreenMetrics(
            viewportSize: CGSize(width: 640, height: 400), settings: settings)

        let measuredAuto = await autoAtlas.screenPlan(metrics: base)
        let measuredBoth = await bothAtlas.screenPlan(metrics: base)
        let autoPlan = try XCTUnwrap(measuredAuto)
        let bothPlan = try XCTUnwrap(measuredBoth)
        let singleCount = try XCTUnwrap(autoPlan.counts.first)
        let spreadCount = try XCTUnwrap(bothPlan.counts.first)

        XCTAssertEqual(autoPlan.pagesPerScreen, 1)
        XCTAssertEqual(bothPlan.pagesPerScreen, 2)
        XCTAssertGreaterThan(spreadCount, singleCount)
        let ratio = Double(spreadCount) / Double(singleCount)
        XCTAssertGreaterThan(ratio, 1.5)
        XCTAssertLessThan(ratio, 3.0)
    }
}
