import Darwin
import ImageIO
import PDFKit
import XCTest
@testable import cooViewer

/// GUI の FD 上限でも正常な合本の全ページを保持し、未使用ハンドルを閉じられること。
final class ArchiveResourceTests: XCTestCase {
    private func fdCount() -> Int {
        (0..<4096).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
    }

    func testSyntheticCollectionAtGUIFileLimit() async throws {
        try await checkCollection(forceFile: true)
    }

    func testMappedSyntheticCollectionAtGUIFileLimit() async throws {
        try await checkCollection(forceFile: false)
    }

    private func checkCollection(forceFile: Bool) async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = PDFDocument()
        let png = TestFixtures.pngData(width: 40, height: 60)
        let jpegBytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            jpegBytes, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try ImageDecoding.decode(png), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let page = try XCTUnwrap(PDFPage(image: NSImage(data: png)!))
        document.insert(page, at: 0)
        let pdf = try XCTUnwrap(document.dataRepresentation())
        let zip = TestFixtures.storedZip(entries: [
            (Array("drawing.jpg".utf8), jpegBytes as Data),
            (Array("scan.pdf".utf8), pdf),
            (Array("instructions.txt".utf8), Data("Synthetic only".utf8))
        ])
        let count = 300
        for index in 0..<count {
            try zip.write(to: root.appendingPathComponent(String(format: "%04d.zip", index)))
        }
        // NAS・外付け同様の file 入口をローカル合成 ZIP に使わせる。
        let factory = ArchiveEngineFactory(
            openFile: ArchiveEngineFactory.live.openFile,
            openData: { _, _, _ in nil })
        let folder = try FolderSource(url: root, readSubFolders: false)
        var source: NestedFolderSource? = NestedFolderSource(
            folder: folder, engineFactory: forceFile ? factory : .live)
        weak var lifetimeProbe = source
        let before = fdCount()
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        defer { _ = setrlimit(RLIMIT_NOFILE, &original) }
        var reduced = original
        reduced.rlim_cur = 256
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &reduced), 0)
        let entries = try await source!.entries()
        let retained = fdCount()
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &original), 0)
        let second = try await source!.entries()
        source = nil
        for _ in 0..<20 { await Task.yield() }
        print("QR73_COLLECTION fileRoute=\(forceFile) candidates=\(count) expectedPages=\(count * 2) actualPages=\(entries.count) secondReadPages=\(second.count) beforeFD=\(before) retainedFD=\(retained) releasedFD=\(fdCount()) releasedSource=\(lifetimeProbe == nil)")
        // GUI の fd 上限でも正常な全書庫が残るべき。現行版の資源枯渇を検出する。
        XCTAssertEqual(entries.count, count * 2)
        XCTAssertLessThan(retained - before, 96)
    }
}
