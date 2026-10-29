import CoreGraphics
import CryptoKit
import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import cooViewer

enum CacheImageFixtures {
    /// 保存順序のテストはハードウェア符号器に依存させない(設計書 §7.6)。
    static func writePNG(_ image: CGImage, at url: URL, encryptionKey: SymmetricKey? = nil) throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let saved = try encryptionKey.map { try XCTUnwrap(SuperResCacheCrypto.seal(data as Data, using: $0)) }
            ?? (data as Data)
        try saved.write(to: url)
    }

    static func image(width: Int, height: Int,
                      space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space,
            colors: [CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1),
                     CGColor(red: 0.95, green: 0.8, blue: 0.2, alpha: 1)] as CFArray,
            locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 20, to: width, by: 83) {
            context.fill(CGRect(x: x, y: height / 4, width: 3, height: height / 2))
        }
        return try XCTUnwrap(context.makeImage())
    }

    static func meanDifference(_ first: CGImage, _ second: CGImage) throws -> Double {
        XCTAssertEqual(first.width, second.width)
        XCTAssertEqual(first.height, second.height)
        let space = try XCTUnwrap(first.colorSpace)
        let a = try XCTUnwrap(DisplayColorTarget.draw(first, width: first.width, height: first.height, space: space))
        let b = try XCTUnwrap(DisplayColorTarget.draw(second, width: first.width, height: first.height, space: space))
        let pa = try XCTUnwrap(a.dataProvider?.data as Data?)
        let pb = try XCTUnwrap(b.dataProvider?.data as Data?)
        var difference: Double = 0
        var minimum = 255, maximum = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                for c in 0..<3 {
                    let value = Int(pa[y * a.bytesPerRow + x * 4 + c])
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    difference += Double(abs(value
                                             - Int(pb[y * b.bytesPerRow + x * 4 + c])))
                }
            }
        }
        XCTAssertGreaterThan(maximum - minimum, 16, "復号が失敗した空画像を比較しない")
        return difference / Double(a.width * a.height * 3)
    }
}

final class SuperResDiskCacheTests: XCTestCase {
    func testBookCloseDuringInferenceRejectsDelayedSave() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = DeferredImageWriter()
        let started = expectation(description: "推論開始")
        let release = AsyncStream<Void>.makeStream()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resolver = MLSuperResolver(diskRoot: root, diskWriter: writer,
            diskWrite: { _, _, _ in calls.withLock { $0 += 1 } }, upscaleOverride: { image in
                started.fulfill()
                for await _ in release.stream { }
                return image
            })
        let image = try CacheImageFixtures.image(width: 80, height: 120)
        let request = Task { await resolver.upscale(image, cacheKey: "closed") }
        await fulfillment(of: [started], timeout: 3)
        writer.cancelAll()
        release.continuation.finish()
        let result = await request.value
        XCTAssertNotNil(result)
        await writer.waitForPendingWrites()
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MLSuperResolver.cacheFileURL(for: "closed", at: root).path))
    }

    func testDeferredPublicationStillAppliesTwoGiBQuota() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(MLSuperResolver.prepareDiskCache(at: root))
        let old = root.appendingPathComponent("old.heic")
        XCTAssertTrue(FileManager.default.createFile(atPath: old.path, contents: nil))
        let file = try FileHandle(forWritingTo: old)
        // 疎ファイルで容量台帳だけを満たし、実ディスクを二 GiB 消費しない(設計書 §7.6)。
        try file.truncate(atOffset: UInt64(MLSuperResolver.diskCacheByteLimit))
        try file.close()
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: old.path)
        let writer = DeferredImageWriter()
        let image = try CacheImageFixtures.image(width: 80, height: 120)
        let resolver = MLSuperResolver(diskRoot: root, diskWriter: writer,
            diskWrite: { try CacheImageFixtures.writePNG($0, at: $1, encryptionKey: $2) }, upscaleOverride: { $0 })
        _ = await resolver.upscale(image, cacheKey: "new")
        await writer.waitForPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MLSuperResolver.cacheFileURL(for: "new", at: root).path))
    }

    func testSRReturnsBeforeSaveAndDeduplicatesPendingReadsForPlainAndEncryptedBooks() async throws {
        for encrypted in [false, true] {
            let root = try TestFixtures.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let writer = DeferredImageWriter()
            let slow = SlowImageWrite()
            let key = SymmetricKey(size: .bits256)
            let image = try CacheImageFixtures.image(width: 80, height: 120)
            let enlarged = try CacheImageFixtures.image(width: 320, height: 480)
            let predictions = OSAllocatedUnfairLock(initialState: 0)
            let resolver = MLSuperResolver(diskRoot: root, diskWriter: writer,
                cacheEncryptionKey: key, diskWrite: { image, temporary, encryptionKey in
                    try await slow.pause(at: temporary)
                    try CacheImageFixtures.writePNG(image, at: temporary, encryptionKey: encryptionKey)
                }, upscaleOverride: { _ in
                    predictions.withLock { $0 += 1 }
                    return enlarged
                })
            let returned = expectation(description: "超解像返却")
            let request = Task {
                let result = await resolver.upscale(image, cacheKey: "book|80x120|sr4|cs:test", encrypted: encrypted)
                returned.fulfill()
                return result
            }
            await fulfillment(of: [returned, slow.started], timeout: 3)
            let url = MLSuperResolver.cacheFileURL(for: "book|80x120|sr4|cs:test", at: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let pending = await resolver.upscale(image, cacheKey: "book|80x120|sr4|cs:test", encrypted: encrypted)
            XCTAssertTrue(pending === enlarged)
            XCTAssertEqual(predictions.withLock { $0 }, 1)
            XCTAssertEqual(slow.calls.withLock { $0 }, 1)
            XCTAssertEqual(slow.priority.withLock { $0 }, .utility)
            slow.release.continuation.finish()
            _ = await request.value
            await writer.waitForPendingWrites()
            let saved = try Data(contentsOf: url)
            if encrypted {
                XCTAssertNotNil(SuperResCacheCrypto.open(saved, using: key))
                if let source = CGImageSourceCreateWithData(saved as CFData, nil) {
                    XCTAssertNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
                }
            } else { XCTAssertNotNil(CGImageSourceCreateWithData(saved as CFData, nil)) }
            let cached = await resolver.upscale(image, cacheKey: "book|80x120|sr4|cs:test", encrypted: encrypted,
                                                displaySize: CGSize(width: 80, height: 120))
            XCTAssertEqual(cached?.width, 160)
            XCTAssertEqual(cached?.height, 240)
            XCTAssertEqual(predictions.withLock { $0 }, 1)
        }
    }

    /// 縮小復号と全体復号を同じ最終寸法で比較する(設計書 §5、§7.6)。
    func testThumbnailDecodeMatchesFullDecodeSizeColorAndQuality() throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(MLSuperResolver.prepareDiskCache(at: root))
        // 符号器を使えない単体検証では PNG で API の縮小・色・暗号化を確認する(設計書 §7.6)。
        let softwareFixture = ProcessInfo.processInfo.environment["COO_TEST_SOFTWARE_IMAGE_FIXTURE"] == "1"
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try XCTUnwrap(CGColorSpace(name: name))
            for encrypted in [false, true] {
                let encryptionKey = encrypted ? SymmetricKey(size: .bits256) : nil
                let image = try CacheImageFixtures.image(width: 1536, height: 2304, space: space)
                let url = root.appendingPathComponent("quality.heic")
                if softwareFixture {
                    try CacheImageFixtures.writePNG(image, at: url, encryptionKey: encryptionKey)
                } else {
                    try MLSuperResolver.writeDiskCache(image, at: url, encryptionKey: encryptionKey)
                }
                let start = ContinuousClock.now
                let full = try XCTUnwrap(MLSuperResolver.readDiskCache(at: url, directory: root,
                    encryptionKey: encryptionKey))
                let width = max(1, full.width / 4), height = max(1, full.height / 4)
                let outputSpace = try XCTUnwrap(full.colorSpace)
                let old = try XCTUnwrap(DisplayColorTarget.draw(full, width: width, height: height, space: outputSpace))
                let fullDuration = ContinuousClock.now - start
                let thumbnailStart = ContinuousClock.now
                let reduced = try XCTUnwrap(MLSuperResolver.readDiskCache(at: url, directory: root,
                    encryptionKey: encryptionKey,
                    maxPixelSize: MLSuperResolver.decodeCap(for: CGSize(width: width, height: height))))
                XCTAssertEqual(reduced.colorSpace, full.colorSpace)
                XCTAssertLessThanOrEqual(max(reduced.width, reduced.height), max(width, height) * 2)
                let result = try XCTUnwrap(DisplayColorTarget.draw(reduced, width: width, height: height, space: outputSpace))
                let reducedDuration = ContinuousClock.now - thumbnailStart
                XCTAssertEqual(result.colorSpace, old.colorSpace)
                let difference = try CacheImageFixtures.meanDifference(old, result)
                XCTAssertLessThan(difference, 3, "8bit RGB の平均絶対差")
                print("SR cache \(softwareFixture ? "PNG" : "HEIC") \(full.width)x\(full.height) \(name) encrypted=\(encrypted): full=\(fullDuration), thumbnail=\(reducedDuration), MAD=\(difference)/255")
            }
        }
    }

    func testDecodeCapUsesTwiceDisplayEdgeWithoutChangingCacheKey() {
        XCTAssertEqual(MLSuperResolver.decodeCap(for: CGSize(width: 350.25, height: 200)), 701)
        XCTAssertNil(MLSuperResolver.decodeCap(for: nil))
        XCTAssertNil(MLSuperResolver.decodeCap(for: .zero))
        XCTAssertNil(MLSuperResolver.decodeCap(for: CGSize(width: CGFloat.infinity, height: 200)))
        XCTAssertEqual(MLSuperResolver.diskCacheByteLimit, 2 << 30)
    }
}
