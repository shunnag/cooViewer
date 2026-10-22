import Darwin
import KaitoKit
import os
import XCTest
@testable import cooViewer

final class SourceAssemblyFailureTests: XCTestCase {
    func testSpoolingAcrossBooksHasBoundedConcurrencyAndReleasesDecoders() async throws {
        let root = try directory()
        let activity = OSAllocatedUnfairLock(initialState: (active: 0, peak: 0, reads: 0, discarded: 0))
        let factory = ArchiveEngineFactory(openFile: { kind, path, role in
            guard let engine = try ArchiveEngineFactory.live.openFile(kind, path, role) else { return nil }
            return SpoolActivityEngine(engine: engine, read: {
                activity.withLock { state in
                    state.active += 1
                    state.peak = max(state.peak, state.active)
                    state.reads += 1
                }
                Thread.sleep(forTimeInterval: 0.03)
                activity.withLock { $0.active -= 1 }
            }, discard: { activity.withLock { $0.discarded += 1 } })
        }, openData: { _, _, _ in nil })
        var sources: [ArchiveSource] = []
        for index in 0..<12 {
            let url = root.appendingPathComponent("book-\(index).zip")
            try zip().write(to: url)
            sources.append(try ArchiveSource(url: url, engineFactory: factory))
        }
        for (index, source) in sources.enumerated() {
            await source.beginSpooling(sizeLimit: 1 << 20, interactive: index.isMultiple(of: 2))
        }
        for source in sources {
            await source.waitForSpoolCompletion()
            let count = await source.spooledEntryCount
            XCTAssertEqual(count, 1)
        }
        let result = activity.withLock { $0 }
        XCTAssertGreaterThan(result.peak, 1)
        XCTAssertLessThanOrEqual(result.peak, 2 + (ProcessInfo.processInfo.physicalMemory < 12 << 30 ? 1 : 2))
        XCTAssertEqual(result.reads, 12)
        XCTAssertEqual(result.discarded, 12)
    }

    func testCompletedSpoolReleasesIdleExtractorsAndStillServesPages() async throws {
        let url = try directory().appendingPathComponent("spooled.zip")
        try zip().write(to: url)
        let source = try ArchiveSource(url: url)
        let pages = try await source.entries()
        let page = try XCTUnwrap(pages.first)
        _ = try await source.image(for: page, maxPixelSize: nil)
        let before = await source.extractorCount
        XCTAssertGreaterThan(before, 0)
        await source.beginSpooling(sizeLimit: 1 << 20)
        await source.waitForSpoolCompletion()
        let after = await source.extractorCount
        XCTAssertEqual(after, 0)
        let image = try await source.image(for: page, maxPixelSize: nil)
        XCTAssertEqual(image.width, 40)
    }
    private func directory() throws -> URL {
        let url = try TestFixtures.makeTempDir()
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func zip() -> Data {
        TestFixtures.storedZip(entries: [(Array("page.png".utf8), TestFixtures.pngData(width: 40, height: 60))])
    }

    private func failingOnce(suffix: String) -> ArchiveEngineFactory {
        let failed = OSAllocatedUnfairLock(initialState: false)
        return ArchiveEngineFactory(openFile: { kind, path, role in
            if path.hasSuffix(suffix), failed.withLock({ value in
                if value { return false }
                value = true
                return true
            }) { throw KaitoError.io(EMFILE) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
    }

    func testFolderIOFailureDoesNotBecomePermanentMissingChild() async throws {
        let root = try directory()
        for name in ["a.zip", "b.zip"] { try zip().write(to: root.appendingPathComponent(name)) }
        let source = NestedFolderSource(folder: try FolderSource(url: root, readSubFolders: false),
            engineFactory: failingOnce(suffix: "b.zip"), retryPolicy: .immediate)
        let recovered = try await source.entries()
        XCTAssertEqual(recovered.map(\.pathInBook), ["a.zip/page.png", "b.zip/page.png"])
        XCTAssertEqual(Set(recovered.map(\.id)).count, 2)
        let image = try await source.image(for: XCTUnwrap(recovered.dropFirst().first), maxPixelSize: nil)
        XCTAssertEqual(image.width, 40)
    }

    func testNestedArchiveIOFailureDoesNotFreezePartialLocations() async throws {
        let root = try directory()
        let outer = root.appendingPathComponent("outer.zip")
        try TestFixtures.storedZip(entries: [(Array("a.zip".utf8), zip()), (Array("b.zip".utf8), zip())])
            .write(to: outer)
        let source = try ArchiveSource(url: outer, engineFactory: failingOnce(suffix: "-b.zip"), retryPolicy: .immediate)
        let recovered = try await source.entries()
        XCTAssertEqual(recovered.map(\.pathInBook), ["a.zip/page.png", "b.zip/page.png"])
        XCTAssertEqual(recovered.map(\.id), [1_000_000, 2_000_000])
    }

    func testReadFailureClassificationPreservesResourceErrors() {
        XCTAssertTrue(SourceReadFailure.mustPropagate(KaitoError.io(EMFILE)))
        XCTAssertTrue(SourceReadFailure.mustPropagate(KaitoError.io(ESTALE)))
        XCTAssertTrue(SourceReadFailure.mustPropagate(CancellationError()))
        XCTAssertTrue(SourceReadFailure.mustPropagate(CocoaError(.fileReadNoPermission)))
        XCTAssertFalse(SourceReadFailure.mustPropagate(KaitoError.malformed("broken")))
        XCTAssertFalse(SourceReadFailure.mustPropagate(CocoaError(.fileReadCorruptFile)))
    }
}

private final class SpoolActivityEngine: ArchiveEngine {
    private let engine: any ArchiveEngine
    private let read: () -> Void
    private let discard: () -> Void
    init(engine: any ArchiveEngine, read: @escaping () -> Void, discard: @escaping () -> Void) {
        self.engine = engine; self.read = read; self.discard = discard
    }
    init?(file path: String, role: ArchiveReaderRole) { return nil }
    init?(data: Data, role: ArchiveReaderRole) { return nil }
    func contents(ofEntry index: Int32) -> Data? { read(); return engine.contents(ofEntry: index) }
    func numberOfEntries() -> Int32 { engine.numberOfEntries() }
    func name(ofEntry index: Int32) -> String? { engine.name(ofEntry: index) }
    func uncompressedSize(ofEntry index: Int32) -> Int64 { engine.uncompressedSize(ofEntry: index) }
    func entryHasSize(_ index: Int32) -> Bool { engine.entryHasSize(index) }
    func entryIsDirectory(_ index: Int32) -> Bool { engine.entryIsDirectory(index) }
    func entryIsEncrypted(_ index: Int32) -> Bool { engine.entryIsEncrypted(index) }
    func isEncrypted() -> Bool { engine.isEncrypted() }
    func setPassword(_ password: String) { engine.setPassword(password) }
    func solidGroup(ofEntry index: Int32) -> Int32 { engine.solidGroup(ofEntry: index) }
    func discardDecodedState() { discard(); engine.discardDecodedState() }
    static var defaultZipLazyLocalHeaders: Bool { KaitoKitEngine.defaultZipLazyLocalHeaders }
    static func setDefaultZipLazyLocalHeaders(_ enabled: Bool) { KaitoKitEngine.setDefaultZipLazyLocalHeaders(enabled) }
}
