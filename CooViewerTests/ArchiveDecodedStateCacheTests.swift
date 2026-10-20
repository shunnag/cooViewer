import Foundation
import XCTest
@testable import cooViewer

final class ArchiveDecodedStateCacheTests: XCTestCase {
    func testCurrentOwnerIsNeverReleasedWithOneBusyOwnerAtLimitOne() async {
        await checkCurrentOwnerWithBusyOwners(limit: 1)
    }

    func testCurrentOwnerIsNeverReleasedWithTwoBusyOwnersAtLimitTwo() async {
        await checkCurrentOwnerWithBusyOwners(limit: 2)
    }

    private func checkCurrentOwnerWithBusyOwners(limit: Int) async {
        let cache = ArchiveDecodedStateCache(limit: limit)
        let busyOwners = (0..<limit).map { _ in DecoderOwner() }
        for owner in busyOwners {
            await owner.setBusy(true)
            await cache.recordUse(owner)
        }
        let current = DecoderOwner()
        for _ in 0..<5 { await cache.recordUse(current) }
        let attempts = await current.releaseAttempts
        XCTAssertEqual(attempts, 0)
        for owner in busyOwners {
            let released = await owner.releases
            let attempted = await owner.releaseAttempts
            XCTAssertEqual(released, 0)
            XCTAssertGreaterThan(attempted, 0)
        }
    }

    func testOldestIdleOwnerIsStillEvicted() async {
        let cache = ArchiveDecodedStateCache(limit: 1)
        let first = DecoderOwner(), second = DecoderOwner()
        await cache.recordUse(first)
        await cache.recordUse(second)
        let firstCount = await first.releases
        let secondAttempts = await second.releaseAttempts
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondAttempts, 0)
    }

    func testIdleBookLimitUsesOnlyValidLaunchArgument() throws {
        let suite = "test.cooViewer.decoded-state.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(9, forKey: "DecodedStateIdleBooks")
        for value in ["", "0", "-1", "1.5", "invalid"] {
            defaults.setVolatileDomain(["DecodedStateIdleBooks": value], forName: UserDefaults.argumentDomain)
            XCTAssertEqual(ArchiveDecodedStateCache.idleBookLimit(defaults: defaults, physicalMemory: 16 << 30), 2)
        }
        for value in [1, 2, 32] {
            defaults.setVolatileDomain(["DecodedStateIdleBooks": String(value)], forName: UserDefaults.argumentDomain)
            XCTAssertEqual(ArchiveDecodedStateCache.idleBookLimit(defaults: defaults, physicalMemory: 128 << 30), value)
        }
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(ArchiveDecodedStateCache.idleBookLimit(defaults: defaults, physicalMemory: 16 << 30), 2)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["DecodedStateIdleBooks"] as? Int, 9)
    }

    func testRecentOwnersRemainAndBusyOwnerIsNeverReleased() async {
        let cache = ArchiveDecodedStateCache(limit: 2)
        let first = DecoderOwner(), second = DecoderOwner(), third = DecoderOwner()
        await cache.recordUse(first)
        await cache.recordUse(second)
        await cache.recordUse(first)
        await cache.recordUse(third)
        let firstCount = await first.releases, secondCount = await second.releases
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
        await first.setBusy(true)
        await cache.recordUse(second)
        let whileBusy = await first.releases
        XCTAssertEqual(whileBusy, 0)
        await first.setBusy(false)
        await cache.recordUse(second)
        await cache.recordUse(third)
        let afterIdle = await first.releases
        XCTAssertEqual(afterIdle, 1)
    }

    func testManyRetainedSourcesKeepFewIdleExtractorsAndRevisitCorrectly() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var sources: [ArchiveSource] = []
        for index in 0..<20 {
            let url = root.appendingPathComponent("book-\(index).zip")
            try TestFixtures.storedZip(entries: [(Array("page.avifs".utf8),
                TestFixtures.pngData(width: 40 + index, height: 60))]).write(to: url)
            let source = try ArchiveSource(url: url)
            let pages = try await source.entries()
            let image = try await source.image(for: pages[0], maxPixelSize: nil)
            XCTAssertEqual(image.width, 40 + index)
            sources.append(source)
        }
        var retained = 0
        for source in sources { retained += await source.extractorCount }
        XCTAssertLessThanOrEqual(retained, ArchiveDecodedStateCache.maximumIdleBooks)
        for index in [0, 19, 1, 18] {
            let pages = try await sources[index].entries()
            let image = try await sources[index].image(for: pages[0], maxPixelSize: nil)
            XCTAssertEqual(image.width, 40 + index)
        }
    }

    func testSolidSevenZipRevisitAfterEvictionKeepsPagesAndBytes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "solid", withExtension: "7z"))
        var sources: [ArchiveSource] = []
        var expected: [Data] = []
        var pageIDs: [[Int]] = []
        for _ in 0..<(ArchiveDecodedStateCache.maximumIdleBooks + 4) {
            let source = try ArchiveSource(url: fixture)
            let pages = try await source.entries()
            let bytes = await source.imageData(for: pages[0])
            expected.append(try XCTUnwrap(bytes))
            _ = try await source.image(for: pages[0], maxPixelSize: nil)
            pageIDs.append(pages.map(\.id))
            sources.append(source)
        }
        let last = sources.count - 1
        for index in [0, last, 1, last - 1] {
            let pages = try await sources[index].entries()
            XCTAssertEqual(pages.map(\.id), pageIDs[index])
            let bytes = await sources[index].imageData(for: pages[0])
            XCTAssertEqual(bytes, expected[index])
            let image = try await sources[index].image(for: pages[0], maxPixelSize: nil)
            XCTAssertEqual(image.width, 4)
        }
    }
}

private actor DecoderOwner: ArchiveDecodedStateOwner {
    private var busy = false
    private(set) var releases = 0
    private(set) var releaseAttempts = 0
    func setBusy(_ value: Bool) { busy = value }
    func releaseIdleDecodedState() -> Bool {
        releaseAttempts += 1
        guard !busy else { return false }
        releases += 1
        return true
    }
}
