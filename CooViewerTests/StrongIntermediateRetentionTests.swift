import CoreGraphics
import Dispatch
import XCTest
@testable import cooViewer

private extension ImageResampler {
    /// actor の待ち時間が表示経路へ戻る退行を検出するため、試験中だけ実行を塞ぐ。
    func blockForRetentionTest(entered: XCTestExpectation, release: DispatchSemaphore) {
        entered.fulfill()
        release.wait()
    }
}

final class StrongIntermediateRetentionTests: XCTestCase {
    func testRetentionProtectsCurrentAndBothAdjacentSpreads() {
        XCTAssertEqual(StrongIntermediateRetentionPolicy.retainedIndices(
            currentIndex: 10, displayCount: 2, pageCount: 30,
            previousIsPair: true, nextIsPair: true), 8..<14)
        XCTAssertEqual(StrongIntermediateRetentionPolicy.retainedIndices(
            currentIndex: 10, displayCount: 1, pageCount: 30,
            previousIsPair: false, nextIsPair: false), 9..<12)
        XCTAssertEqual(StrongIntermediateRetentionPolicy.retainedIndices(
            currentIndex: 10, displayCount: 1, pageCount: 30,
            previousIsPair: nil, nextIsPair: nil), 8..<13)
        XCTAssertEqual(StrongIntermediateRetentionPolicy.retainedIndices(
            currentIndex: 0, displayCount: 1, pageCount: 1,
            previousIsPair: nil, nextIsPair: nil), 0..<1)
        XCTAssertEqual(StrongIntermediateRetentionPolicy.retainedIndices(
            currentIndex: 29, displayCount: 2, pageCount: 30,
            previousIsPair: true, nextIsPair: nil), 27..<30)
        XCTAssertTrue(StrongIntermediateRetentionPolicy.retainedIndices(
            currentIndex: -1, displayCount: 2, pageCount: 30,
            previousIsPair: nil, nextIsPair: nil).isEmpty)
    }

    func testMovingRetentionDropsOnlyDistantIntermediateAndKeepsFinalResults() async throws {
        let source = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20))
        let filtered = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20, red: 0.8))
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), noiseReductionOverride: { _, _ in filtered })
        let target = CGSize(width: 10, height: 10)
        let oldResult = await resampler.resample(source, to: target, cacheKey: "book#1",
            upscaleWithMetalFX: false, noiseReduction: .strong)
        let old = try XCTUnwrap(oldResult)
        _ = await resampler.resample(source, to: target, cacheKey: "book#2",
            upscaleWithMetalFX: false, noiseReduction: .strong)
        let before = await resampler.stats()
        XCTAssertEqual(before.count, 4)
        await resampler.retainStrongIntermediates(bookKey: "book", pageKeys: ["book#2"], revision: 2)
        // 遅着した旧位置の要求で、現在・隣接の中間結果を追い出さない(設計書 §7.3)。
        await resampler.retainStrongIntermediates(bookKey: "book", pageKeys: ["book#1"], revision: 1)
        let trimmed = await resampler.stats()
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(before.usedBytes - trimmed.usedBytes, filtered.bytesPerRow * filtered.height)
        let hit = await resampler.cached(source, to: target, cacheKey: "book#1",
            upscaleWithMetalFX: false, noiseReduction: .strong)
        XCTAssertTrue(old === hit)
        _ = await resampler.resample(source, to: CGSize(width: 11, height: 11), cacheKey: "book#2",
            upscaleWithMetalFX: false, noiseReduction: .strong)
        let nearby = await resampler.stats()
        XCTAssertEqual(nearby.reducedSourceCount, before.reducedSourceCount)
        _ = await resampler.resample(source, to: CGSize(width: 11, height: 11), cacheKey: "book#1",
            upscaleWithMetalFX: false, noiseReduction: .strong)
        let distant = await resampler.stats()
        XCTAssertEqual(distant.reducedSourceCount, before.reducedSourceCount + 1)
        // 遠方の新サイズ要求も完成画像だけを残し、中間画像は復活させない。
        XCTAssertEqual(distant.count, 5)
    }

    func testRetainingOneBookDoesNotEvictAnotherBooksCurrentIntermediate() async throws {
        let source = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20))
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), noiseReductionOverride: { image, _ in image })
        for key in ["bookA#1", "bookA#2", "bookAB#1"] {
            _ = await resampler.resample(source, to: CGSize(width: 10, height: 10), cacheKey: key,
                upscaleWithMetalFX: false, noiseReduction: .strong)
        }
        let before = await resampler.stats()
        XCTAssertEqual(before.count, 6)
        await resampler.retainStrongIntermediates(bookKey: "bookAB", pageKeys: ["bookAB#1"], revision: 1)
        await resampler.retainStrongIntermediates(bookKey: "bookA", pageKeys: ["bookA#2"], revision: 100)
        // 本 A より小さい連番でも、本 B にとって新しい要求は採用する(設計書 §7.3)。
        let accepted = await resampler.retainStrongIntermediates(
            bookKey: "bookAB", pageKeys: ["bookAB#1"], revision: 2)
        XCTAssertTrue(accepted)
        let retained = await resampler.stats()
        XCTAssertEqual(retained.count, 5)
        for key in ["bookAB#1", "bookA#2"] {
            _ = await resampler.resample(source, to: CGSize(width: 11, height: 11), cacheKey: key,
                upscaleWithMetalFX: false, noiseReduction: .strong)
        }
        let resized = await resampler.stats()
        XCTAssertEqual(resized.reducedSourceCount, before.reducedSourceCount)
        _ = await resampler.resample(source, to: CGSize(width: 11, height: 11), cacheKey: "bookA#1",
            upscaleWithMetalFX: false, noiseReduction: .strong)
        let distant = await resampler.stats()
        XCTAssertEqual(distant.reducedSourceCount, before.reducedSourceCount + 1)
    }

    func testRemovingBookRetentionAllowsInsertsWithoutChangingAnotherBooksRules() async throws {
        let source = try ImageDecoding.decode(TestFixtures.pngData(width: 20, height: 20))
        let resampler = ImageResampler(pressure: FixedMemoryPressure(), noiseReductionOverride: { image, _ in image })
        await resampler.retainStrongIntermediates(bookKey: "bookA", pageKeys: [], revision: 100)
        await resampler.retainStrongIntermediates(bookKey: "bookB", pageKeys: [], revision: 1)
        await resampler.removeStrongIntermediateRetention(bookKey: "bookA")
        for key in ["bookA#1", "bookB#1"] {
            for edge in [10, 11] {
                _ = await resampler.resample(source, to: CGSize(width: edge, height: edge), cacheKey: key,
                    upscaleWithMetalFX: false, noiseReduction: .strong)
            }
        }
        let stats = await resampler.stats()
        // 条件が消えた A は中間結果を再利用し、空の保持条件が残る B は毎回計算する。
        XCTAssertEqual(stats.reducedSourceCount, 3)
        let accepted = await resampler.retainStrongIntermediates(bookKey: "bookA", pageKeys: [], revision: 1)
        XCTAssertTrue(accepted)
    }

    @MainActor
    func testBookCloseDrainsPendingRetentionAndRemovesBookEntry() async {
        let key = "retention-close-\(UUID())"
        let book = makeBook(cacheKey: key)
        await ImageResampler.shared.retainStrongIntermediates(bookKey: key, pageKeys: [], revision: .max)
        let stale = await ImageResampler.shared.retainStrongIntermediates(bookKey: key, pageKeys: [], revision: 1)
        XCTAssertFalse(stale)
        // 表示が予約した utility 更新も排出し、close 完了後に保持条件を復活させない。
        _ = await book.currentSpread()
        await book.close().value
        let reopened = await ImageResampler.shared.retainStrongIntermediates(bookKey: key, pageKeys: [], revision: 1)
        XCTAssertTrue(reopened)
        await ImageResampler.shared.removeStrongIntermediateRetention(bookKey: key)
    }

    @MainActor
    func testSpreadReturnsWhileResamplerActorIsBusy() async {
        let key = "retention-display-\(UUID())"
        let book = makeBook(cacheKey: key)
        let entered = expectation(description: "描画 actor を占有")
        let returned = expectation(description: "保持更新を待たずに表示を返す")
        let release = DispatchSemaphore(value: 0)
        let blocker = Task.detached {
            await ImageResampler.shared.blockForRetentionTest(entered: entered, release: release)
        }
        await fulfillment(of: [entered], timeout: 3)
        let display = Task {
            _ = await book.currentSpread()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 3)
        let closing = book.close()
        release.signal()
        await blocker.value
        await display.value
        await closing.value
        let reopened = await ImageResampler.shared.retainStrongIntermediates(bookKey: key, pageKeys: [], revision: 1)
        XCTAssertTrue(reopened)
        await ImageResampler.shared.removeStrongIntermediateRetention(bookKey: key)
    }

    @MainActor
    private func makeBook(cacheKey: String) -> Book {
        let entry = PageEntry(id: 0, name: "page.png", pathInBook: "page.png",
                              fileURL: nil, creationDate: nil, modificationDate: nil)
        let source = FolderSource(snapshotURL: URL(fileURLWithPath: "/stub/\(cacheKey)"),
                                  images: [entry], nestedPaths: [])
        let book = Book(source: source, prepared: .init(sortedEntries: [entry], cacheKey: cacheKey))
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        return book
    }
}
