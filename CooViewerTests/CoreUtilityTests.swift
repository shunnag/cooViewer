import XCTest
@testable import cooViewer

final class ImageDecodingTests: XCTestCase {
    func testDecodeFullSize() throws {
        let data = TestFixtures.pngData(width: 32, height: 16)
        let image = try ImageDecoding.decode(data)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 16)
    }

    func testDecodeWithMaxPixelSizeDownsamples() throws {
        let data = TestFixtures.pngData(width: 32, height: 16)
        let image = try ImageDecoding.decode(data, maxPixelSize: 8)
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
    }

    func testDecodeGarbageThrows() {
        XCTAssertThrowsError(try ImageDecoding.decode(Data([0xDE, 0xAD, 0xBE, 0xEF])))
    }
}

final class PageCacheTests: XCTestCase {
    /// 16x16 RGBA ≈ 1KB のテスト画像
    private func image() -> CGImage {
        try! ImageDecoding.decode(TestFixtures.pngData(width: 16, height: 16))
    }

    private var oneCost: Int {
        let sample = image()
        return sample.bytesPerRow * sample.height
    }

    func testEvictsOldestWhenOverByteLimit() async {
        let cache = PageCache(byteLimit: oneCost * 2)  // 2 枚分
        await cache.insert(image(), for: 1)
        await cache.insert(image(), for: 2)
        await cache.insert(image(), for: 3)
        let first = await cache.image(for: 1)
        let second = await cache.image(for: 2)
        let third = await cache.image(for: 3)
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
    }

    func testAccessMovesEntryToMostRecentlyUsed() async {
        let cache = PageCache(byteLimit: oneCost * 2)
        await cache.insert(image(), for: 1)
        await cache.insert(image(), for: 2)
        _ = await cache.image(for: 1)          // 1 を MRU に
        await cache.insert(image(), for: 3)    // 2 が追い出される
        let first = await cache.image(for: 1)
        let second = await cache.image(for: 2)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }

    func testByteLimitReductionEvicts() async {
        let cache = PageCache(byteLimit: oneCost * 3)
        await cache.insert(image(), for: 1)
        await cache.insert(image(), for: 2)
        await cache.insert(image(), for: 3)
        await cache.setByteLimit(oneCost)
        let count = await cache.count
        XCTAssertEqual(count, 1)
        let third = await cache.image(for: 3)  // 最新のみ残る
        XCTAssertNotNil(third)
    }

    func testSingleOversizedImageIsKept() async {
        // 上限を超える 1 枚でも保持する(再デコードの繰り返し防止)
        let cache = PageCache(byteLimit: 1)
        await cache.insert(image(), for: 1)
        let first = await cache.image(for: 1)
        XCTAssertNotNil(first)
    }

    func testTrimToHalfDropsOldEntries() async {
        let cache = PageCache(byteLimit: oneCost * 4)
        for id in 1...4 {
            await cache.insert(image(), for: id)
        }
        await cache.trimToHalf()
        let count = await cache.count
        XCTAssertEqual(count, 2)
        let newest = await cache.image(for: 4)
        XCTAssertNotNil(newest)
    }
}
