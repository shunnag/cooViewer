import CoreGraphics
import CryptoKit
import ImageIO
import os
import XCTest
@testable import cooViewer

/// 一時ファイルを未完成で止め、表示と公開の順序を検証する(設計書 §5、§7.6)。
final class SlowImageWrite: Sendable {
    let started = XCTestExpectation(description: "保存開始")
    let release = AsyncStream<Void>.makeStream()
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let priority = OSAllocatedUnfairLock<TaskPriority?>(initialState: nil)

    func pause(at url: URL) async throws {
        calls.withLock { $0 += 1 }
        priority.withLock { $0 = Task.currentPriority }
        try Data("未完成".utf8).write(to: url)
        started.fulfill()
        for await _ in release.stream { }
    }
}

private actor DeferredThumbnailSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/deferred")
    nonisolated let supportsDateSort = false
    let image: CGImage
    let protected: Bool
    private(set) var loads = 0
    init(image: CGImage, protected: Bool = false) { self.image = image; self.protected = protected }
    func entries() async throws -> [PageEntry] { [] }
    func containsProtectedContent() async -> Bool { protected }
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        loads += 1
        return image
    }
}

final class DeferredImageWriterTests: XCTestCase {
    func testConcurrentSameKeyWritesPublishAtomicallyAndFailureKeepsOldFile() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = DeferredImageWriter()
        let slow = SlowImageWrite()
        let image = try CacheImageFixtures.image(width: 32, height: 48)
        let url = root.appendingPathComponent("page.heic")
        let old = Data("以前の完成ファイル".utf8)
        let completed = Data(repeating: 42, count: 100_000)
        try old.write(to: url)
        let generation = writer.generation
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    writer.enqueue(image, at: url, generation: generation) { _, temporary in
                        try await slow.pause(at: temporary)
                        try completed.write(to: temporary)
                    }
                }
            }
        }
        await fulfillment(of: [slow.started], timeout: 3)
        for _ in 0..<20 { XCTAssertEqual(try Data(contentsOf: url), old) }
        XCTAssertEqual(slow.calls.withLock { $0 }, 1)
        slow.release.continuation.finish()
        await writer.waitForPendingWrites()
        XCTAssertEqual(try Data(contentsOf: url), completed)
        writer.enqueue(image, at: url, generation: generation) { _, temporary in
            try Data("未完成".utf8).write(to: temporary)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        await writer.waitForPendingWrites()
        XCTAssertEqual(try Data(contentsOf: url), completed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["page.heic"])
    }

    func testThumbnailReturnsBeforeSaveAndPendingSurvivesFreshCache() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = DeferredImageWriter()
        let slow = SlowImageWrite()
        let image = try CacheImageFixtures.image(width: 80, height: 120)
        let source = DeferredThumbnailSource(image: image)
        let entry = PageEntry(id: 0, name: "a", pathInBook: "a", fileURL: nil,
                              creationDate: nil, modificationDate: nil)
        let cache = ThumbnailCache(diskRoot: root, byteLimit: 1, pressure: FixedMemoryPressure(),
                                  diskWriter: writer, diskWrite: { image, url in
            try await slow.pause(at: url)
            try CacheImageFixtures.writePNG(image, at: url)
        })
        let returned = expectation(description: "画像返却")
        let request = Task {
            let result = await cache.thumbnail(for: entry, in: source, bookKey: "book")
            returned.fulfill()
            return result
        }
        await fulfillment(of: [returned, slow.started], timeout: 3)
        let final = root.appendingPathComponent("book/0@256.heic")
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertTrue(writer.image(at: final) === image)
        // 別インスタンスでも保存待ち画像を使い、未完成ファイルを読まない(設計書 §7.3)。
        let fresh = ThumbnailCache(diskRoot: root, pressure: FixedMemoryPressure(), diskWriter: writer)
        let pending = await fresh.thumbnail(for: entry, in: source, bookKey: "book")
        XCTAssertTrue(pending === image)
        let loads = await source.loads
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(slow.calls.withLock { $0 }, 1)
        XCTAssertEqual(slow.priority.withLock { $0 }, .utility)
        slow.release.continuation.finish()
        _ = await request.value
        await writer.waitForPendingWrites()
        XCTAssertNotNil(CGImageSourceCreateWithURL(final as CFURL, nil))
        XCTAssertNil(writer.image(at: final))
    }

    func testCancellationAndShutdownNeverPublishDelayedWrites() async throws {
        for stopping in [false, true] {
            let root = try TestFixtures.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let writer = DeferredImageWriter()
            let slow = SlowImageWrite()
            let image = try CacheImageFixtures.image(width: 32, height: 48)
            let url = root.appendingPathComponent("page.heic")
            let original = Data("以前の完成ファイル".utf8)
            try original.write(to: url)
            let generation = writer.generation
            writer.enqueue(image, at: url, generation: generation) { _, temp in
                try await slow.pause(at: temp)
                try Data("完成".utf8).write(to: temp)
            }
            await fulfillment(of: [slow.started], timeout: 3)
            XCTAssertEqual(try Data(contentsOf: url), original)
            writer.cancelAll(stopping: stopping)
            slow.release.continuation.finish()
            await writer.waitForPendingWrites()
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertNil(writer.image(at: url))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["page.heic"])
            writer.enqueue(image, at: url, generation: generation) { _, _ in XCTFail("旧世代") }
            writer.enqueue(image, at: url, generation: writer.generation) { _, temp in
                try Data("新世代".utf8).write(to: temp)
            }
            await writer.waitForPendingWrites()
            XCTAssertEqual(try Data(contentsOf: url), stopping ? original : Data("新世代".utf8))
        }
    }

    func testProtectedThumbnailNeverEnqueuesDiskWrite() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = DeferredImageWriter()
        let source = DeferredThumbnailSource(image: try CacheImageFixtures.image(width: 32, height: 48),
                                             protected: true)
        let cache = ThumbnailCache(diskRoot: root, pressure: FixedMemoryPressure(), diskWriter: writer,
                                  diskWrite: { _, _ in XCTFail("保護サムネイルの保存は禁止") })
        let entry = PageEntry(id: 0, name: "a", pathInBook: "a", fileURL: nil,
                              creationDate: nil, modificationDate: nil)
        let image = await cache.thumbnail(for: entry, in: source, bookKey: "protected")
        XCTAssertNotNil(image)
        await writer.waitForPendingWrites()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
