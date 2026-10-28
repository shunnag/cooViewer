import AppKit
import KaitoKit
import XCTest
import os
@testable import cooViewer

/// 副ファイルの除外・番号変更・保存位置の互換性を同じ入力で照合する(設計書 §2.4、§5、§7.2)。
final class ArchiveAppleDoubleTests: XCTestCase {
    private static func sidecar(resource: Data = Data()) -> Data {
        var data = Data()
        func append32(_ value: UInt32) {
            for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        append32(0x0005_1607)
        append32(0x0002_0000)
        data.append(Data(repeating: 0, count: 16))
        data.append(contentsOf: [0, 2])
        append32(9)
        append32(50)
        append32(32)
        append32(2)
        append32(82)
        append32(UInt32(resource.count))
        data.append(Data(repeating: 0, count: 32))
        data.append(resource)
        return data
    }

    // 独立実行でも画像判定を UTI サービスに依存させず、内容はマジックで復号する(設計書 §7.6)。
    private static func fixture() -> Data {
        TestFixtures.storedZip(entries: [
            (Array("__MACOSX/".utf8), Data()),
            (Array("__MACOSX/._cover.avifs".utf8), sidecar(resource: Data([1, 2, 3]))),
            (Array("cover.avifs".utf8), TestFixtures.pngData(width: 4, height: 9)),
            (Array("._second.avifs".utf8), sidecar()),
            (Array("second.avifs".utf8), TestFixtures.pngData(width: 5, height: 9)),
            (Array("sub/".utf8), Data()),
            (Array("__MACOSX/sub/".utf8), Data()),
            (Array("__MACOSX/sub/._page.avifs".utf8), sidecar()),
            (Array("sub/page.avifs".utf8), TestFixtures.pngData(width: 6, height: 9)),
        ])
    }

    private static var mergedFactory: ArchiveEngineFactory {
        ArchiveEngineFactory(openFile: { _, path, role in
            var options = KaitoKitEngine.options(role: role)
            options.appleDoublePolicy = .merge
            return try KaitoKitEngine(file: path, options: options)
        }, openData: { _, data, role in
            var options = KaitoKitEngine.options(role: role)
            options.appleDoublePolicy = .merge
            return try KaitoKitEngine(data: data, options: options)
        })
    }

    func testArchiveSourceKeepsVisibleNamesOrderAndContentsAcrossPolicies() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // 両入口と独立した展開係でも同じ番号体系を使う(設計書 §2.4、§5)。
        for name in ["book.cbz", "book.cbr"] {
            let url = root.appendingPathComponent(name)
            try Self.fixture().write(to: url)
            let merged = try ArchiveSource(url: url, engineFactory: Self.mergedFactory)
            let exposed = try ArchiveSource(url: url)
            let before = try await merged.entries()
            let after = try await exposed.entries()
            XCTAssertEqual(before.map(\.pathInBook), ["cover.avifs", "second.avifs", "sub/page.avifs"])
            XCTAssertEqual(after.map(\.pathInBook), before.map(\.pathInBook))
            XCTAssertEqual(after.map(\.name), before.map(\.name))
            XCTAssertEqual(before.map(\.id), [0, 2, 4])
            XCTAssertEqual(after.map(\.id), [2, 4, 8])
            for (offset, entry) in after.enumerated() {
                let image = try await exposed.image(for: entry, maxPixelSize: nil)
                XCTAssertEqual(image.width, 4 + offset)
            }
        }
    }

    func testNestedArchiveKeepsVisiblePathsAndContents() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outer.cbz")
        try TestFixtures.storedZip(entries: [
            (Array("__MACOSX/._inner.cbz".utf8), Self.sidecar()),
            (Array("inner.cbz".utf8), Self.fixture()),
        ]).write(to: url)
        let merged = try ArchiveSource(url: url, engineFactory: Self.mergedFactory)
        let exposed = try ArchiveSource(url: url)
        let before = try await ArchiveSource.$testingNestedAvailableCapacity.withValue({ _ in 100 << 30 }) {
            try await merged.entries()
        }
        let after = try await ArchiveSource.$testingNestedAvailableCapacity.withValue({ _ in 100 << 30 }) {
            try await exposed.entries()
        }
        XCTAssertEqual(after.map(\.pathInBook), before.map(\.pathInBook))
        XCTAssertEqual(after.map(\.pathInBook),
                       ["inner.cbz/cover.avifs", "inner.cbz/second.avifs", "inner.cbz/sub/page.avifs"])
        for (offset, entry) in after.enumerated() {
            let image = try await exposed.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, 4 + offset)
        }
    }

    @MainActor
    func testPersistedBookmarksAndLastPageSurviveEntryRenumbering() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "test.cooViewer.appleDouble.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10, forKey: "OpenRecentLimit")
        let directory = root.appendingPathComponent("BookStates")
        let url = root.appendingPathComponent("book.cbz")
        try Self.fixture().write(to: url)
        let merged = try ArchiveSource(url: url, engineFactory: Self.mergedFactory)
        let exposed = try ArchiveSource(url: url)
        let before = try await Book.open(source: merged, sortMode: .name).entries
        let after = try await Book.open(source: exposed, sortMode: .name).entries
        XCTAssertNotEqual(before.map(\.id), after.map(\.id))
        for withPath in [true, false] {
            let store = BookHistoryStore(defaults: defaults, directory: directory)
            let page = 1
            let path = withPath ? before[page].pathInBook : nil
            XCTAssertEqual(store.saveImageBook(path: url.path, snapshot: .init(
                displayName: "book.cbz", pageIndex: page, pagePath: path,
                settings: .init(readMode: nil, sortMode: nil, marks: PageMarks(),
                                bookmarks: [.init(name: "保存位置", pageIndex: page, pagePath: path)]))), .saved)
            let fresh = BookHistoryStore(defaults: defaults, directory: directory)
            let last = try XCTUnwrap(fresh.savedPage(forPath: url.path, inRecents: true))
            let settings = try XCTUnwrap(fresh.settings(displayName: "book.cbz", path: url.path))
            let bookmark = try XCTUnwrap(settings.bookmarks.first)
            for (index, pagePath) in [(last.page, last.pagePath), (bookmark.pageIndex, bookmark.pagePath)] {
                let resolved = BookHistoryStore.reconciledIndex(saved: index, pagePath: pagePath, entries: after)
                XCTAssertEqual(after[resolved].pathInBook, before[page].pathInBook)
            }
        }
    }

    @MainActor
    func testDiskThumbnailCannotReuseMergedEntryNumberForAnotherPage() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("book.cbz")
        try Self.fixture().write(to: url)
        let merged = try ArchiveSource(url: url, engineFactory: Self.mergedFactory)
        let exposed = try ArchiveSource(url: url)
        let before = try await merged.entries()
        let after = try await exposed.entries()
        let identity = BookFileIdentity()
        let keyURL = URL(fileURLWithPath: "/test/appledouble.cbz")
        // 変更前の式で、同じパス・日時・サイズ・表示一覧から得たキー(設計書 §5)。
        let oldKey = "aef68b7f1e8689008d6f5b6821bf1b18"
        let mergedKey = Book.makeCacheKey(for: keyURL, entries: before, identity: identity)
        let newKey = Book.makeCacheKey(for: keyURL, entries: after, identity: identity)
        XCTAssertNotEqual(mergedKey, oldKey)
        XCTAssertNotEqual(mergedKey, newKey)
        XCTAssertNotEqual(oldKey, newKey)
        XCTAssertEqual(newKey, Book.makeCacheKey(for: keyURL, entries: after.reversed(), identity: identity))
        // .merge の二枚目と .expose の表紙で番号が衝突する入力を使う(設計書 §5)。
        let target = try XCTUnwrap(after.first)
        let stale = try XCTUnwrap(before.first { $0.id == target.id })
        XCTAssertNotEqual(stale.pathInBook, target.pathInBook)
        let disk = root.appendingPathComponent("Thumbnails")
        let staleFile = disk.appendingPathComponent(oldKey).appendingPathComponent("\(stale.id)@256.heic")
        // 読取は画像マジックで判別するため、符号器のサービスに依存せず旧画像を置く(設計書 §7.6)。
        try FileManager.default.createDirectory(at: staleFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let staleData = await merged.imageData(for: stale)
        try XCTUnwrap(staleData).write(to: staleFile)
        let oldHit = await ThumbnailCache(diskRoot: disk)
            .thumbnail(for: target, in: exposed, bookKey: oldKey)
        XCTAssertEqual(oldHit?.width, 5)
        let freshCache = ThumbnailCache(diskRoot: disk)
        let result = await freshCache.thumbnail(for: target, in: exposed, bookKey: newKey)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 9)
    }

    private struct ReadRecordingSource: ByteSource {
        let data: Data
        let reads = OSAllocatedUnfairLock(initialState: [Range<UInt64>]())
        var length: UInt64 { UInt64(data.count) }

        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            guard offset < length else { return 0 }
            let count = min(buffer.count, Int(length - offset))
            reads.withLock { $0.append(offset..<offset + UInt64(count)) }
            data.withUnsafeBytes { bytes in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[Int(offset)..<Int(offset) + count]))
            }
            return count
        }
    }

    func testCacheKeyBindsIDsToPathsEvenWhenNamesHaveEqualLength() {
        func entry(_ id: Int, _ path: String) -> PageEntry {
            PageEntry(id: id, name: path, pathInBook: path, fileURL: nil,
                      creationDate: nil, modificationDate: nil)
        }
        let url = URL(fileURLWithPath: "/test/book.cbz")
        let before = [entry(1, "001.avifs"), entry(2, "002.avifs")]
        let after = [entry(2, "001.avifs"), entry(1, "002.avifs")]
        XCTAssertNotEqual(Book.makeCacheKey(for: url, entries: before, identity: .init()),
                          Book.makeCacheKey(for: url, entries: after, identity: .init()))
    }

    func testOpeningDoesNotReadSidecarPayload() throws {
        let prefix = Data(repeating: 0, count: 128 << 10)
        let name = "__MACOSX/._page.avifs"
        let sidecar = Self.sidecar(resource: Data(repeating: 1, count: 4096))
        let data = TestFixtures.storedZip(entries: [
            (Array("padding.bin".utf8), prefix),
            (Array(name.utf8), sidecar),
            (Array("page.avifs".utf8), TestFixtures.pngData(width: 4, height: 9)),
            (Array("tail.bin".utf8), prefix),
        ])
        let start = UInt64(30 + "padding.bin".utf8.count + prefix.count + 30 + name.utf8.count)
        let payload = start..<start + UInt64(sidecar.count)
        for role in [ArchiveReaderRole.primary, .extractor(poolSize: 3)] {
            let source = ReadRecordingSource(data: data)
            let options = KaitoKitEngine.options(role: role)
            let reader = try ArchiveReader.open(source: source, options: options)
            XCTAssertEqual(reader.entries.count, 4)
            XCTAssertFalse(source.reads.withLock { $0.contains { $0.overlaps(payload) } })
        }
        // 同じ観測点で旧方針の検査を検出できることも確かめる(設計書 §5)。
        let source = ReadRecordingSource(data: data)
        var options = KaitoKitEngine.options(role: .primary)
        options.appleDoublePolicy = .merge
        _ = try ArchiveReader.open(source: source, options: options)
        XCTAssertTrue(source.reads.withLock { $0.contains { $0.overlaps(payload) } })
    }
}
