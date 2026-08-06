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
    private func image(_ size: Int) -> CGImage {
        try! ImageDecoding.decode(TestFixtures.pngData(width: size, height: size))
    }

    func testEvictsOldestWhenOverCapacity() async {
        let cache = PageCache(capacity: 2)
        await cache.insert(image(1), for: 1)
        await cache.insert(image(2), for: 2)
        await cache.insert(image(3), for: 3)
        let first = await cache.image(for: 1)
        let second = await cache.image(for: 2)
        let third = await cache.image(for: 3)
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
    }

    func testAccessMovesEntryToMostRecentlyUsed() async {
        let cache = PageCache(capacity: 2)
        await cache.insert(image(1), for: 1)
        await cache.insert(image(2), for: 2)
        _ = await cache.image(for: 1)          // 1 を MRU に
        await cache.insert(image(3), for: 3)   // 2 が追い出される
        let first = await cache.image(for: 1)
        let second = await cache.image(for: 2)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }

    func testCapacityReductionEvicts() async {
        let cache = PageCache(capacity: 3)
        await cache.insert(image(1), for: 1)
        await cache.insert(image(2), for: 2)
        await cache.insert(image(3), for: 3)
        await cache.setCapacity(1)
        let count = await cache.count
        XCTAssertEqual(count, 1)
        let third = await cache.image(for: 3)
        XCTAssertNotNil(third)
    }
}
