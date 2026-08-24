import XCTest
@testable import Washi

/// EPUBPublication ファサードの統合検証(ZIP / フォルダ両コンテナ)
final class PublicationTests: XCTestCase {
    private func openVerticalNovel() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/novel.epub"))
    }

    func testOpenVerticalNovel() throws {
        let publication = try openVerticalNovel()
        XCTAssertEqual(publication.metadata.mainTitle, "吾輩は猫である")
        XCTAssertEqual(publication.readingDirection, .rtl)
        XCTAssertFalse(publication.isFixedLayout)
        XCTAssertFalse(publication.isDRMProtected)
        XCTAssertNil(publication.drmSchemeName)
        // 読書順(linear="no" の奥付も含む)
        XCTAssertEqual(publication.readingOrder.map(\.containerPath),
                       ["OEBPS/text/ch1.xhtml", "OEBPS/text/ch2.xhtml",
                        "OEBPS/text/colophon.xhtml"])
        XCTAssertEqual(publication.coverImagePath, "OEBPS/images/cover.png")
    }

    /// 表紙 API: 宣言あり(cover-image)の解決とデコード・縮小
    func testCoverImageDeclaredAndDecoded() throws {
        let publication = try openVerticalNovel()
        XCTAssertEqual(publication.resolvedCoverImagePath, "OEBPS/images/cover.png")
        let full = publication.coverImage()
        XCTAssertNotNil(full)
        let thumb = publication.coverImage(maxPixelSize: 2)
        XCTAssertNotNil(thumb)
        XCTAssertLessThanOrEqual(max(thumb?.width ?? 0, thumb?.height ?? 0), 2)
    }

    /// 表紙 API: 宣言なしでも「cover を含む名前の manifest 画像」へフォールバック
    func testCoverImageFallsBackToNamedManifestImage() throws {
        var entries = EPUBFixtures.verticalNovelEntries()
        for (index, entry) in entries.enumerated()
        where entry.name.hasSuffix("package.opf") {
            let opf = String(data: entry.data, encoding: .utf8)!
                .replacingOccurrences(of: #" properties="cover-image""#, with: "")
            entries[index] = (entry.name, Data(opf.utf8))
        }
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/no-decl.epub"))
        XCTAssertNil(publication.coverImagePath)
        XCTAssertEqual(publication.resolvedCoverImagePath, "OEBPS/images/cover.png")
    }

    /// 表紙 API: 宣言も cover 名もない FXL は先頭ページの単一画像へフォールバック
    func testCoverImageFallsBackToFirstFXLPage() throws {
        var entries = EPUBFixtures.fxlComicEntries()
        for (index, entry) in entries.enumerated()
        where entry.name.hasSuffix(".opf") {
            let opf = String(data: entry.data, encoding: .utf8)!
                .replacingOccurrences(of: #" properties="cover-image""#, with: "")
            entries[index] = (entry.name, Data(opf.utf8))
        }
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries, method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/fxl-no-decl.epub"))
        XCTAssertNil(publication.coverImagePath)
        XCTAssertEqual(publication.resolvedCoverImagePath, "OEBPS/images/p001.png")
        XCTAssertNotNil(publication.coverImage(maxPixelSize: 4))
    }

    /// EPUBLocator: idref 併記の生成・改版追跡の resolve・旧形式互換
    func testLocatorResolveTracksIdref() throws {
        let publication = try openVerticalNovel()
        // 保存用 locator には idref が併記される
        let saved = publication.locator(forSpineIndex: 1, progression: 0.5)
        XCTAssertEqual(saved.idref, publication.readingOrder[1].itemRef.idref)
        // 同一 spine 構成なら恒等
        XCTAssertEqual(publication.resolve(saved), saved)
        // spineIndex がずれていても idref で正しい項目へ写像される(改版追跡)
        let stale = EPUBLocator(spineIndex: 0, progression: 0.5,
                                idref: saved.idref)
        XCTAssertEqual(publication.resolve(stale)?.spineIndex, 1)
        XCTAssertEqual(publication.resolve(stale)?.progression, 0.5)
        // 消えた idref は nil(呼び出し側が先頭から等を決める)
        let gone = EPUBLocator(spineIndex: 0, progression: 0, idref: "no-such")
        XCTAssertNil(publication.resolve(gone))
        // idref のない旧形式は範囲内クランプのみ
        let legacy = EPUBLocator(spineIndex: 99, progression: 1)
        XCTAssertEqual(publication.resolve(legacy)?.spineIndex,
                       publication.readingOrder.count - 1)
    }

    /// EPUBLocator: 旧形式 JSON({spineIndex, progression})とデコード互換
    func testLocatorCodableBackwardCompatible() throws {
        let legacy = Data(#"{"spineIndex":2,"progression":0.25}"#.utf8)
        let decoded = try JSONDecoder().decode(EPUBLocator.self, from: legacy)
        XCTAssertEqual(decoded.spineIndex, 2)
        XCTAssertEqual(decoded.progression, 0.25)
        XCTAssertNil(decoded.idref)
        // idref 付きはラウンドトリップ
        let modern = EPUBLocator(spineIndex: 1, progression: 0.5, idref: "ch2")
        let roundTrip = try JSONDecoder().decode(
            EPUBLocator.self, from: JSONEncoder().encode(modern))
        XCTAssertEqual(roundTrip, modern)
    }

    /// 本文抽出: ルビの読み(rt)を除いた本文が取れ、章題も含まれる
    func testExtractTextStripsRuby() throws {
        let publication = try openVerticalNovel()
        let text = try publication.extractText(forSpineIndex: 0)
        XCTAssertTrue(text.contains("吾輩は猫である"), "本文が連続していない: \(text)")
        XCTAssertTrue(text.contains("名前はまだ無い"))
        XCTAssertTrue(text.contains("第一章"))
        // ルビの読みは本文から除かれる
        XCTAssertFalse(text.contains("わがはい"))
        XCTAssertFalse(text.contains("ねこ"))
    }

    /// 全文検索: 章を跨いでヒットし、位置とスニペットが返る
    func testSearchAcrossSpine() throws {
        let publication = try openVerticalNovel()
        let hits = publication.search("猫")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.length == 1 })
        // ヒットは spine 順
        XCTAssertEqual(hits.map(\.spineIndex), hits.map(\.spineIndex).sorted())
        // スニペットにヒット語が含まれる
        XCTAssertTrue(hits.allSatisfy { $0.snippet.contains("猫") })
        // 別の章の語も引ける
        XCTAssertEqual(publication.search("生れた").first?.spineIndex, 1)
        // 空クエリは無ヒット
        XCTAssertTrue(publication.search("   ").isEmpty)
    }

    /// 検索の文字オフセットは抽出テキスト上で一致する(ハイライトの土台)
    func testSearchOffsetPointsAtMatch() throws {
        let publication = try openVerticalNovel()
        let text = try publication.extractText(forSpineIndex: 0)
        let chars = Array(text)
        guard let hit = publication.search("猫").first(where: { $0.spineIndex == 0 })
        else { return XCTFail("ヒットなし") }
        let end = hit.characterOffset + hit.length
        let matched = String(chars[hit.characterOffset..<end])
        XCTAssertEqual(matched, "猫")
    }

    /// 複数ヒットでも各 characterOffset が増分計算で正しく整合する
    func testSearchMultipleOffsetsConsistent() throws {
        let publication = try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.verticalNovelEntries(), method: 8),
            displayURL: URL(fileURLWithPath: "/tmp/multi.epub"))
        // 「は」は 1 章内に複数出現する(吾輩は / 名前は)
        let hits = publication.search("は").filter { $0.spineIndex == 0 }
        XCTAssertGreaterThan(hits.count, 1)
        let text = try publication.extractText(forSpineIndex: 0)
        let chars = Array(text)
        for hit in hits {
            let end = hit.characterOffset + hit.length
            XCTAssertEqual(String(chars[hit.characterOffset..<end]), "は")
        }
        // オフセットは狭義単調増加(重複・逆行なし)
        XCTAssertEqual(hits.map(\.characterOffset),
                       hits.map(\.characterOffset).sorted())
    }

    /// 非同期オープン(open)は同期 init と同じ結果を返す
    func testAsyncOpenMatchesSyncInit() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("washi-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, data) in EPUBFixtures.verticalNovelEntries() {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let publication = try await EPUBPublication.open(url: dir)
        XCTAssertEqual(publication.metadata.mainTitle, "吾輩は猫である")
    }

    /// resourcePaths はコンテナ内の実リソースを列挙する
    func testResourcePathsEnumerated() throws {
        let publication = try openVerticalNovel()
        let paths = publication.resourcePaths
        XCTAssertTrue(paths.contains("OEBPS/package.opf"))
        XCTAssertTrue(paths.contains("OEBPS/images/cover.png"))
        XCTAssertTrue(paths.contains("OEBPS/text/ch1.xhtml"))
    }

    /// エラーは LocalizedError で人間可読な errorDescription を返す
    func testErrorsAreLocalized() {
        XCTAssertNotNil((EPUBError.notAnEPUB("x") as LocalizedError).errorDescription)
        XCTAssertNotNil((EPUBError.drmProtected(scheme: "LCP") as LocalizedError)
            .errorDescription)
        XCTAssertNotNil((ZipError.notAZipFile as LocalizedError).errorDescription)
        XCTAssertNotNil((ZipError.entryTooLarge("a", declaredSize: 9) as LocalizedError)
            .errorDescription)
        // localizedDescription 経路(NSError ブリッジ)でも空でない
        XCTAssertFalse(EPUBError.malformed("y").localizedDescription.isEmpty)
        XCTAssertFalse(ZipError.corruptEntry("z").localizedDescription.isEmpty)
    }

    /// アクセシビリティ・メタデータの型付きサーフェス
    func testAccessibilityMetadata() throws {
        let a11y = try openVerticalNovel().metadata.accessibility
        XCTAssertFalse(a11y.isEmpty)
        XCTAssertEqual(a11y.accessModes, ["textual", "visual"])
        XCTAssertEqual(a11y.accessModesSufficient, [["textual", "visual"]])
        XCTAssertEqual(a11y.features, ["structuralNavigation"])
        XCTAssertEqual(a11y.hazards, ["noFlashingHazard"])
        XCTAssertNotNil(a11y.summary)
        XCTAssertEqual(a11y.conformsTo.count, 1)
    }

    /// 便利アクセサ: authors(role=aut・display-seq 順)と series
    func testAuthorsAndSeriesAccessors() throws {
        let metadata = try openVerticalNovel().metadata
        XCTAssertEqual(metadata.authors, ["夏目漱石"])
        XCTAssertEqual(metadata.series?.name, "漱石全集")
        XCTAssertEqual(metadata.series?.type, "series")
    }

    func testNavigationResolution() throws {
        let publication = try openVerticalNovel()
        XCTAssertEqual(publication.navigation.toc.count, 2)
        // nav 項目 → spine index の解決
        let ch2 = publication.navigation.toc[1]
        XCTAssertEqual(publication.spineIndex(forNavItem: ch2), 1)
        // フラグメント付き子項目も文書単位で解決される
        let sec1 = publication.navigation.toc[0].children[0]
        XCTAssertEqual(publication.spineIndex(forNavItem: sec1), 0)
    }

    func testResourceLoading() throws {
        let publication = try openVerticalNovel()
        let (data, mediaType) = try publication.resource(at: "OEBPS/text/ch1.xhtml")
        XCTAssertEqual(mediaType, "application/xhtml+xml")
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("吾輩"))
        // マニフェスト未記載のリソースは拡張子から推定
        let css = try publication.resource(at: "OEBPS/style.css")
        XCTAssertEqual(css.mediaType, "text/css")
        XCTAssertThrowsError(try publication.resource(at: "OEBPS/missing.png"))
    }

    func testFolderContainer() throws {
        // 展開済みフォルダとしても同じ結果になる
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("washi-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, data) in EPUBFixtures.verticalNovelEntries() {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let publication = try EPUBPublication(url: dir)
        XCTAssertEqual(publication.metadata.mainTitle, "吾輩は猫である")
        XCTAssertEqual(publication.readingOrder.count, 3)
        let (data, _) = try publication.resource(at: "OEBPS/text/ch2.xhtml")
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("第二章"))
    }

    // MARK: - 固定レイアウト

    private func openFXLComic() throws -> EPUBPublication {
        try EPUBPublication(
            data: ZipBuilder.build(EPUBFixtures.fxlComicEntries()),
            displayURL: URL(fileURLWithPath: "/tmp/comic.epub"))
    }

    func testFixedLayoutInfo() throws {
        let publication = try openFXLComic()
        XCTAssertTrue(publication.isFixedLayout)
        XCTAssertEqual(publication.readingDirection, .rtl)

        let page1 = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertEqual(page1.viewportSize, CGSize(width: 1200, height: 1920))
        XCTAssertEqual(page1.simpleImagePath, "OEBPS/images/p001.png")
        XCTAssertEqual(page1.pageSpread, .center)

        let page2 = try publication.fixedLayoutInfo(forSpineIndex: 1)
        XCTAssertEqual(page2.pageSpread, .left)
        let page3 = try publication.fixedLayoutInfo(forSpineIndex: 2)
        XCTAssertEqual(page3.pageSpread, .right)
    }

    /// 電書協 FXL テンプレートの SVG ラッパー形式でも画像を直接取り出せる
    func testSVGWrappedImagePage() throws {
        let svgPage = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"
              xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="UTF-8"/><title>p</title>
        <meta name="viewport" content="width=848, height=1200"/></head>
        <body epub:type="cover"><div class="main">
          <svg xmlns="http://www.w3.org/2000/svg" version="1.1"
               xmlns:xlink="http://www.w3.org/1999/xlink"
               width="100%" height="100%" viewBox="0 0 848 1200">
            <image width="848" height="1200" xlink:href="images/p001.png"/>
          </svg>
        </div></body></html>
        """
        var entries = EPUBFixtures.fxlComicEntries()
        entries[4] = ("OEBPS/p001.xhtml", Data(svgPage.utf8))
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/comic.epub"))
        let info = try publication.fixedLayoutInfo(forSpineIndex: 0)
        XCTAssertEqual(info.viewportSize, CGSize(width: 848, height: 1200))
        XCTAssertEqual(info.simpleImagePath, "OEBPS/images/p001.png")
    }

    /// viewport の寛容パース("500px" → 500 の数値サルベージ)
    func testViewportSalvage() {
        XCTAssertEqual(
            EPUBPublication.parseViewportContent("width=500px, height=700px"),
            CGSize(width: 500, height: 700))
        XCTAssertEqual(
            EPUBPublication.parseViewportContent("width = 848 , height = 1200"),
            CGSize(width: 848, height: 1200))
        XCTAssertNil(EPUBPublication.parseViewportContent(
            "width=device-width, initial-scale=1"))
    }

    // MARK: - 難読化・DRM

    func testObfuscatedFontRoundTrip() throws {
        let uid = "urn:uuid:12345678-1234-1234-1234-123456789abc"
        let fontData = Data((0..<1500).map { UInt8($0 % 256) })
        let obfuscated = FontDeobfuscator.deobfuscate(
            fontData, algorithm: .idpf, uniqueIdentifier: uid)
        let encryptionXML = """
        <?xml version="1.0"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/fonts/m.otf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        var entries = EPUBFixtures.verticalNovelEntries()
        entries.append(("META-INF/encryption.xml", Data(encryptionXML.utf8)))
        entries.append(("OEBPS/fonts/m.otf", obfuscated))
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/novel.epub"))
        // resource() が透過的に解除して元のフォントデータを返す
        let (data, _) = try publication.resource(at: "OEBPS/fonts/m.otf")
        XCTAssertEqual(data, fontData)
        XCTAssertFalse(publication.isDRMProtected)
    }

    func testDRMDetection() throws {
        let encryptionXML = """
        <?xml version="1.0"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                    xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/text/ch1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """
        var entries = EPUBFixtures.verticalNovelEntries()
        entries.append(("META-INF/encryption.xml", Data(encryptionXML.utf8)))
        entries.append(("META-INF/rights.xml",
                        Data("<rights xmlns=\"http://ns.adobe.com/adept\"/>".utf8)))
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/drm.epub"))
        XCTAssertTrue(publication.isDRMProtected)
        XCTAssertEqual(publication.drmSchemeName, "Adobe ADEPT")
        XCTAssertThrowsError(try publication.resource(at: "OEBPS/text/ch1.xhtml")) {
            guard case EPUBError.drmProtected = $0 else {
                return XCTFail("drmProtected であるべき: \($0)")
            }
        }
    }

    // MARK: - 異常系

    func testNotAnEPUB() {
        XCTAssertThrowsError(try EPUBPublication(
            data: ZipBuilder.build([("hello.txt", Data("x".utf8))]),
            displayURL: URL(fileURLWithPath: "/tmp/x.epub")))
    }

    func testWrongMimetypeRejected() {
        var entries = EPUBFixtures.verticalNovelEntries()
        entries[0] = ("mimetype", Data("application/zip".utf8))
        XCTAssertThrowsError(try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/x.epub")))
    }

    /// 複数 rootfile は先頭を採用(OCF §3.5.2.1)
    func testMultipleRootfiles() throws {
        let containerXML = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/>
            <rootfile full-path="OEBPS/alt.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        var entries = EPUBFixtures.verticalNovelEntries()
        entries[1] = ("META-INF/container.xml", Data(containerXML.utf8))
        let publication = try EPUBPublication(
            data: ZipBuilder.build(entries),
            displayURL: URL(fileURLWithPath: "/tmp/x.epub"))
        XCTAssertEqual(publication.package.path, "OEBPS/package.opf")
    }

    // MARK: - SMIL

    func testMediaOverlayParsing() throws {
        XCTAssertEqual(SMILParser.parseClockValue("12.5s"), 12.5)
        XCTAssertEqual(SMILParser.parseClockValue("1250ms"), 1.25)
        XCTAssertEqual(SMILParser.parseClockValue("1:02:03.5"), 3723.5)
        XCTAssertEqual(SMILParser.parseClockValue("02:03"), 123)
        let smil = """
        <?xml version="1.0"?>
        <smil xmlns="http://www.w3.org/ns/SMIL"
              xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
          <body>
            <seq>
              <par id="p1">
                <text src="ch1.xhtml#w1"/>
                <audio src="audio/ch1.m4a" clipBegin="0s" clipEnd="2.5s"/>
              </par>
              <par id="p2" epub:type="footnote">
                <text src="ch1.xhtml#w2"/>
                <audio src="audio/ch1.m4a" clipBegin="2.5s" clipEnd="5s"/>
              </par>
            </seq>
          </body>
        </smil>
        """
        let overlay = try SMILParser.parse(data: Data(smil.utf8),
                                           at: "OEBPS/ch1.smil")
        XCTAssertEqual(overlay.parallels.count, 2)
        XCTAssertEqual(overlay.parallels[0].textHref, "ch1.xhtml#w1")
        XCTAssertEqual(overlay.parallels[0].clipEnd, 2.5)
        XCTAssertEqual(overlay.parallels[1].epubType, "footnote")
    }
}
