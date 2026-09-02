import Foundation
import XCTest

@testable import cooViewer

/// 書庫内固定レイアウト EPUB の合本取り込み(cooViewer-c6s.14)を検証する。
/// 既存の書庫/PDF 回帰は NestedArchiveSourceTests が担当し、ここでは EPUB の
/// 対象境界(FXL のみ、リフロー/暗号化祖先下は黙殺)を固定する。
final class NestedEPUBArchiveSourceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestFixtures.makeTempDir()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDir)
    }

    /// 幅をページ内容のマーカーとして使う。
    private func png(width: Int) -> Data {
        TestFixtures.pngData(width: width, height: 60)
    }

    private func zipData(_ entries: [(String, Data)]) -> Data {
        TestFixtures.storedZip(entries: entries.map { (Array($0.0.utf8), $0.1) })
    }

    private func writeZip(named name: String, _ entries: [(String, Data)]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try zipData(entries).write(to: url)
        return url
    }

    private let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0"
                   xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf"
                      media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    private func pageXHTML(image: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>page</title>
        <meta name="viewport" content="width=1200, height=1920"/></head>
        <body><div><img src="images/\(image)" alt=""/></div></body>
        </html>
        """
    }

    /// Scripts/make-sample-epub.py の FXL 漫画部分と同じ構造を、テスト用の
    /// 幅マーカー画像 2 枚で最小化した EPUB フィクスチャ。
    private func fixedLayoutEPUBData(widths: [Int]) -> Data {
        let manifest = widths.indices.map { index in
            let page = index + 1
            return """
                <item id="p\(page)" href="p\(String(format: "%03d", page)).xhtml"
                      media-type="application/xhtml+xml"/>
                <item id="i\(page)" href="images/p\(String(format: "%03d", page)).png"
                      media-type="image/png"/>
                """
        }.joined(separator: "\n")
        let spine = widths.indices.map { index in
            "<itemref idref=\"p\(index + 1)\"/>"
        }.joined(separator: "\n")
        let package = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:nested-fxl-test</dc:identifier>
                <dc:title>書庫内 FXL テスト</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-02T00:00:00Z</meta>
                <meta property="rendition:layout">pre-paginated</meta>
              </metadata>
              <manifest>
            \(manifest)
              </manifest>
              <spine page-progression-direction="rtl">
            \(spine)
              </spine>
            </package>
            """
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(package.utf8)),
        ]
        for (index, width) in widths.enumerated() {
            let name = String(format: "p%03d", index + 1)
            entries.append(("OEBPS/\(name).xhtml",
                            Data(pageXHTML(image: "\(name).png").utf8)))
            entries.append(("OEBPS/images/\(name).png", png(width: width)))
        }
        return zipData(entries)
    }

    private func reflowEPUBData() -> Data {
        let package = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0"
                     unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:nested-reflow-test</dc:identifier>
                <dc:title>書庫内リフローテスト</dc:title>
                <dc:language>ja</dc:language>
                <meta property="dcterms:modified">2026-09-02T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="chapter" href="chapter.xhtml"
                      media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """
        let chapter = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>本文</title></head><body><p>リフロー本文</p></body>
            </html>
            """
        return zipData([
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/package.opf", Data(package.utf8)),
            ("OEBPS/chapter.xhtml", Data(chapter.utf8)),
        ])
    }

    /// 画像 + FXL EPUB + 画像が列挙順のまま 1 冊になり、EPUB の spine 枚数と
    /// 画像内容が保たれること。id 規則も既存のネスト書庫/PDF と同じであること。
    func testFixedLayoutEPUBPagesInterleaveInArchiveOrder() async throws {
        let url = try writeZip(named: "nested-fxl.zip", [
            ("00.avifs", png(width: 40)),
            ("comic.epub", fixedLayoutEPUBData(widths: [41, 42])),
            ("10.avifs", png(width: 43)),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()

        XCTAssertEqual(entries.map(\.pathInBook), [
            "00.avifs", "comic.epub/000000", "comic.epub/000001", "10.avifs",
        ])
        XCTAssertEqual(entries.map(\.id), [0, 1_000_000, 1_000_001, 2])
        for (entry, width) in zip(entries, [40, 41, 42, 43]) {
            let image = try await source.image(for: entry, maxPixelSize: nil)
            XCTAssertEqual(image.width, width, "\(entry.pathInBook) の画像内容")
        }
    }

    /// リフロー EPUB は固定レイアウト画像パイプラインに入れず、従来どおり
    /// 仕様書 §4.17 の黙殺で他のページだけを残す(cooViewer-c6s.23)。
    func testReflowEPUBIsSkippedSilently() async throws {
        let uniqueName = "novel-\(UUID().uuidString).epub"
        let url = try writeZip(named: "nested-reflow.zip", [
            ("00.avifs", png(width: 40)),
            (uniqueName, reflowEPUBData()),
            ("10.avifs", png(width: 43)),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()

        XCTAssertEqual(entries.map(\.pathInBook), ["00.avifs", "10.avifs"])

        // cooViewer-cj2: source を生存させたまま spool を調べ、棄却した
        // リフロー EPUB が nested temp に作られていないことを固定する。
        let root = ArchiveSource.spoolRoot()
        let pidPrefix = "\(ProcessInfo.processInfo.processIdentifier)-"
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var leakedFiles: [URL] = []
        for directory in directories
            where directory.lastPathComponent.hasPrefix(pidPrefix) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            leakedFiles.append(contentsOf: files.filter {
                $0.lastPathComponent.hasSuffix("-\(uniqueName)")
            })
        }
        XCTAssertTrue(leakedFiles.isEmpty,
                      "リフロー EPUB が nested temp に書かれている")
    }

    /// cooViewer-id8: 棄却 EPUB は id 序数を消費せず、後続の従来型
    /// ネスト書庫は EPUB 非対応時代と同じ 1_000_000 から始まる。
    func testRejectedEPUBDoesNotConsumeNestedIDOrdinal() async throws {
        let inner = zipData([("inside.avifs", png(width: 41))])
        let url = try writeZip(named: "rejected-epub-before-archive.zip", [
            ("00.avifs", png(width: 40)),
            ("novel.epub", reflowEPUBData()),
            ("inner.zip", inner),
        ])
        let source = try ArchiveSource(url: url)
        let entries = try await source.entries()

        XCTAssertEqual(entries.map(\.pathInBook), [
            "00.avifs", "inner.zip/inside.avifs",
        ])
        XCTAssertEqual(entries.map(\.id), [0, 1_000_000])
    }

    /// 暗号化祖先下では EPUB 全体の平文 temp を作らない(cooViewer-6ax)。
    /// in-memory OCF 対応は cooViewer-c6s.23 まで保留し、EPUB だけ黙って欠落する。
    func testEncryptedParentSkipsEPUBWithoutPlaintextTemp() async throws {
        let epubData = fixedLayoutEPUBData(widths: [41, 42])
        let uniqueName = "secret-\(UUID().uuidString).epub"
        let stage = tempDir.appendingPathComponent("encrypted")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let imageURL = stage.appendingPathComponent("visible.avifs")
        let epubURL = stage.appendingPathComponent(uniqueName)
        let archiveURL = stage.appendingPathComponent("outer.zip")
        try png(width: 40).write(to: imageURL)
        try epubData.write(to: epubURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-P", "sesame", archiveURL.path,
                             imageURL.path, epubURL.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let source = try ArchiveSource(url: archiveURL)
        let encrypted = await source.isEncrypted()
        XCTAssertTrue(encrypted)
        let unlocked = await source.checkAndSetPassword("sesame")
        XCTAssertTrue(unlocked)
        let entries = try await source.entries()
        XCTAssertEqual(entries.map(\.pathInBook), ["visible.avifs"])

        // source を生存させたまま spool を調べ、候補名を持つ平文 temp が無いことを
        // assert する。UUID 名なので同時実行中の別テストとは衝突しない。
        let root = ArchiveSource.spoolRoot()
        let pidPrefix = "\(ProcessInfo.processInfo.processIdentifier)-"
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        var leakedFiles: [URL] = []
        for directory in directories
            where directory.lastPathComponent.hasPrefix(pidPrefix) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            leakedFiles.append(contentsOf: files.filter {
                $0.lastPathComponent.hasSuffix("-\(uniqueName)")
            })
        }
        XCTAssertTrue(leakedFiles.isEmpty,
                      "暗号化祖先下の EPUB が平文 temp に書かれている")
    }
}
