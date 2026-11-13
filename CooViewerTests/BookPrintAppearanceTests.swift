import CoreGraphics
import PrintAppearanceKit
import XCTest
@testable import cooViewer

/// 網点処理の要求・キー・失効の Book 側の規則(設計書 §5)。読み込み元は要求の段階ごとに違う画素を返す
/// 合成の偽物で、PrintAppearanceService.shared には触れない
@MainActor
final class BookPrintAppearanceTests: XCTestCase {
    // MARK: - キー

    /// 印は renderKey だけを変え、cacheKey(サムネイルの名前空間)は変えない。切っているときは従来のキーのまま
    func testTagChangesRenderKeyAndLeavesCacheKey() async throws {
        let book = try await Book.open(source: PrintAppearanceStubSource())
        let cacheKey = book.cacheKey
        XCTAssertNil(book.printAppearanceLevel)
        XCTAssertEqual(book.printAppearanceTag, "")
        XCTAssertEqual(book.renderKey, cacheKey)
        XCTAssertEqual(book.pageKey(forEntryID: 3), "\(cacheKey)#3")

        var renderKeys: Set<String> = [book.renderKey]
        for level in PrintAppearanceLevel.allCases {
            XCTAssertTrue(book.updatePrintAppearance(level))
            XCTAssertFalse(book.updatePrintAppearance(level), "同じ段階では何もしない")
            XCTAssertEqual(book.cacheKey, cacheKey)
            XCTAssertEqual(book.renderKey, cacheKey + PrintAppearanceTag.tag(for: level))
            XCTAssertFalse(book.printAppearanceTag.contains("#"), "ページキーの分割を崩さない")
            let pageKey = book.pageKey(forEntryID: 3)
            XCTAssertEqual(pageKey.lastIndex(of: "#").map { String(pageKey[..<$0]) }, book.renderKey)
            renderKeys.insert(book.renderKey)
        }
        XCTAssertEqual(renderKeys.count, 4, "切と 3 段階で別の名前空間")
        XCTAssertTrue(book.updatePrintAppearance(nil))
        XCTAssertEqual(book.renderKey, cacheKey)
        await book.close().value
    }

    func testTagSpellsEngineVersionAndLevel() {
        let version = PrintAppearance.engineVersion
        XCTAssertEqual(PrintAppearanceTag.tag(for: nil), "")
        XCTAssertEqual(PrintAppearanceTag.tag(for: .low), "~pa\(version)l")
        XCTAssertEqual(PrintAppearanceTag.tag(for: .standard), "~pa\(version)s")
        XCTAssertEqual(PrintAppearanceTag.tag(for: .strong), "~pa\(version)h")
    }

    /// 作るときの段階で始まり、見開きは読み込んだときの renderKey を持つ
    func testBookStartsWithRequestAndSpreadCarriesRenderKey() async throws {
        let source = PrintAppearanceStubSource()
        let book = try await Book.open(source: source, printAppearance: .strong)
        book.readMode = .leftToRightSingle
        XCTAssertEqual(book.printAppearanceLevel, .strong)
        XCTAssertEqual(book.renderKey, book.cacheKey + PrintAppearanceTag.tag(for: .strong))
        let spread = await book.currentSpread()
        XCTAssertEqual(spread.renderKey, book.renderKey)
        XCTAssertEqual(spread.images.first.flatMap { $0.map(pixelValue) }, PrintAppearanceStubSource.value(for: .strong))
        book.updatePrintAppearance(nil)
        let off = await book.currentSpread()
        XCTAssertEqual(off.renderKey, book.cacheKey)
        XCTAssertEqual(off.images.first.flatMap { $0.map(pixelValue) }, PrintAppearanceStubSource.value(for: nil))
        await book.close().value
    }

    // MARK: - 要求と券

    /// 切っているときは要求を立てない。入れているときは読み込みごとに券を付け、表示と先読みを区別する
    func testRequestReachesSourceWithTicketOnlyWhenOn() async throws {
        let source = PrintAppearanceStubSource()
        let book = try await Book.open(source: source)
        _ = await book.image(at: 0)
        var requests = await source.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests[0].level)
        XCTAssertNil(requests[0].ticket)

        book.updatePrintAppearance(.low)
        _ = await PageRequestIntent.$isDisplay.withValue(true) { await book.image(at: 1) }
        _ = await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 2) }
        requests = await source.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].level, .low)
        XCTAssertEqual(requests[1].ticket?.intent, .display)
        XCTAssertEqual(requests[1].ticket?.book, ObjectIdentifier(book))
        XCTAssertEqual(requests[2].level, .low)
        XCTAssertEqual(requests[2].ticket?.intent, .prefetch)
        XCTAssertFalse(requests[1].ticket === requests[2].ticket, "券は読み込みごと")
        await book.close().value
    }

    /// 表示が先読みの読み込みに合流したら券に触れて表示に上げ、先読みの辞退は券にも届く
    func testDisplayJoinTouchesTicketAndPrefetchDeclineReachesTicket() async throws {
        let source = PrintAppearanceStubSource(holds: true)
        let book = try await Book.open(source: source, printAppearance: .standard)
        let prefetch = Task { await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 0) } }
        let started = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(started)
        let first = await source.requests[0]
        XCTAssertEqual(first.ticket?.intent, .prefetch)
        let display = Task { await PageRequestIntent.$isDisplay.withValue(true) { await book.image(at: 0) } }
        let touched = await waitUntil { first.ticket?.intent == .display }
        XCTAssertTrue(touched, "合流した表示が券を表示に上げる")
        await source.release(0)
        let (prefetched, displayed) = await (prefetch.value, display.value)
        XCTAssertNotNil(displayed)
        XCTAssertTrue(prefetched === displayed)
        let requestCount = await source.requestCount
        XCTAssertEqual(requestCount, 1, "単一飛行のまま")

        let second = Task { await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 1) } }
        let secondStarted = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(secondStarted)
        let ticket = await source.requests[1].ticket
        XCTAssertEqual(ticket?.intent, .prefetch)
        book.cancelPrefetch()
        XCTAssertEqual(ticket?.intent, .declined)
        await source.release(1)
        _ = await second.value
        await book.close().value
    }

    // MARK: - 先読みの再計画

    /// ページ移動では網点処理の先読みを辞退させない。移動先の見開きが揃ったら、新しい計画に残る先読みは
    /// 読み直さずにそのまま残し(並列幅に数える)、計画から外れたものだけを辞退させる(設計書 §5)
    func testNavigationKeepsPrefetchLoadsThatStayInTheNewPlan() async throws {
        let source = PrintAppearanceStubSource(pageCount: 12, holds: true, parallel: true)
        let book = try await Book.open(source: source, printAppearance: .standard)
        book.readMode = .leftToRightSingle
        let width = PreresamplePolicy.decodeWidth(mediaConcurrency: book.mediaProfile.bookPrefetchConcurrency,
                                                  printAppearance: true)
        book.prefetchAhead = width
        book.prefetchBehind = 0
        func ticket(_ entry: Int) async -> PrintAppearanceTicket? {
            await source.requests.last { $0.entryID == entry }?.ticket
        }
        func releaseRequest(for entry: Int) async {
            if let index = await source.requests.lastIndex(where: { $0.entryID == entry }) { await source.release(index) }
        }

        // 1 ページ目を表示し、先読みが幅いっぱい(ページ 1...width)始まるのを待つ
        let first = Task { await book.currentSpread() }
        let firstStarted = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(firstStarted)
        await releaseRequest(for: 0)
        _ = await first.value
        let prefetching = await waitUntil { await source.heldCount == width }
        XCTAssertTrue(prefetching)
        var before: [PrintAppearanceTicket?] = []
        for entry in 1...width { before.append(await ticket(entry)) }
        XCTAssertEqual(before.map { $0?.intent }, Array(repeating: .prefetch, count: width))

        // 次のページへ: 移動の時点では辞退させない
        XCTAssertEqual(book.moveNext(), .moved)
        XCTAssertEqual(before.map { $0?.intent }, Array(repeating: .prefetch, count: width))
        // 移動先(ページ 1)の表示は先読みの読み込みに合流し、揃ったら新しい計画(2...width+1)を立てる
        let second = Task { await book.currentSpread() }
        let joined = await waitUntil { before[0]?.intent == .display }
        XCTAssertTrue(joined)
        await releaseRequest(for: 1)
        _ = await second.value
        let replanned = await waitUntil { await source.heldCount == width }
        XCTAssertTrue(replanned, "残した読み込みも並列幅に数える")
        for (offset, kept) in before.dropFirst().enumerated() {
            XCTAssertEqual(kept?.intent, .prefetch, "ページ \(offset + 2) は新しい計画に残るので辞退させない")
        }
        let requests = await source.requests
        for entry in 2...width {
            XCTAssertEqual(requests.filter { $0.entryID == entry }.count, 1, "残したページ \(entry) を読み直さない")
        }
        let newcomer = await ticket(width + 1)
        XCTAssertEqual(newcomer?.intent, .prefetch)

        // 遠くへ移動: 移動先の計画から外れた先読みだけを辞退させる
        book.goTo(index: 9)
        XCTAssertEqual(newcomer?.intent, .prefetch, "移動の時点では辞退させない")
        let far = Task { await book.currentSpread() }
        let farStarted = await waitUntil { await source.requests.contains { $0.entryID == 9 } }
        XCTAssertTrue(farStarted)
        await releaseRequest(for: 9)
        _ = await far.value
        for kept in before.dropFirst() + [newcomer] {
            XCTAssertEqual(kept?.intent, .declined, "計画から外れた先読みは辞退させる")
        }
        // 止めている読み込みをすべて放してから閉じる
        for index in 0..<(await source.requestCount) { await source.release(index) }
        let drained = await waitUntil {
            for index in 0..<(await source.requestCount) { await source.release(index) }
            return await source.heldCount == 0
        }
        XCTAssertTrue(drained)
        await book.close().value
    }

    // MARK: - 失効

    /// 設定の変更はキャッシュを捨て、遅れて届いた旧い印の読み込みを登録しない。待っていた image(at:) は
    /// 旧い印の画素を返さず、新しい印で読み直す
    func testUpdateFlushesCacheAndImageNeverReturnsOldTagPixels() async throws {
        let source = PrintAppearanceStubSource(holds: true)
        let book = try await Book.open(source: source)
        // 先にもう 1 ページをキャッシュに入れておき、捨てられることを確かめる
        let warm = Task { await book.image(at: 1) }
        let warmStarted = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(warmStarted)
        await source.release(0)
        _ = await warm.value
        XCTAssertEqual(book.pageCacheStats().count, 1)

        let waiting = Task { await PageRequestIntent.$isDisplay.withValue(true) { await book.image(at: 0) } }
        let started = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(started)
        let epoch = book.renderEpoch
        XCTAssertTrue(book.updatePrintAppearance(.standard))
        XCTAssertEqual(book.renderEpoch, epoch + 1)
        XCTAssertEqual(book.pageCacheStats().count, 0, "設定の変更でページキャッシュを捨てる")
        // 旧い読み込み(切)を終わらせる: 登録されず、待っていた呼び出しは新しい印で読み直す
        await source.release(1)
        let reloaded = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(reloaded)
        XCTAssertEqual(book.pageCacheStats().count, 0, "旧い印の遅れた結果はキャッシュに入れない")
        let retry = await source.requests[2]
        XCTAssertEqual(retry.entryID, book.entries[0].id)
        XCTAssertEqual(retry.level, .standard)
        await source.release(2)
        let image = await waiting.value
        XCTAssertEqual(image.map(pixelValue), PrintAppearanceStubSource.value(for: .standard))
        XCTAssertEqual(book.pageCacheStats().count, 1)
        // 戻した設定でも同じ: 入れていたときの画素を返さない(まだキャッシュにないページで確かめる)
        let back = Task { await book.image(at: 3) }
        let backStarted = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(backStarted)
        book.updatePrintAppearance(.strong)
        book.updatePrintAppearance(nil)
        await source.release(3)
        let backReloaded = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(backReloaded)
        await source.release(4)
        let offImage = await back.value
        XCTAssertEqual(offImage.map(pixelValue), PrintAppearanceStubSource.value(for: nil))
        let levels = await source.requests.map(\.level)
        XCTAssertEqual(levels, [nil, nil, .standard, .standard, nil])
        await book.close().value
    }

    /// 間引かれた読み込みは何もキャッシュせず、位置・条件が変わっていなければ読み直す
    func testSupersededLoadIsRetriedWhileRevisionUnchanged() async throws {
        let source = PrintAppearanceStubSource(outcomes: [.superseded, .image])
        let book = try await Book.open(source: source, printAppearance: .standard)
        let image = await PageRequestIntent.$isDisplay.withValue(true) { await book.image(at: 0) }
        XCTAssertEqual(image.map(pixelValue), PrintAppearanceStubSource.value(for: .standard))
        let requestCount = await source.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(book.pageCacheStats().count, 1)
        await book.close().value
    }

    /// 位置が動いた後に間引かれた読み込みは読み直さず nil を返す(壊れたページとして描く前に呼び出し側が捨てる)
    func testSupersededLoadReturnsNilAfterRevisionMoved() async throws {
        let source = PrintAppearanceStubSource(holds: true, outcomes: [.superseded])
        let book = try await Book.open(source: source, printAppearance: .standard)
        let waiting = Task { await PageRequestIntent.$isDisplay.withValue(true) { await book.image(at: 0) } }
        let started = await waitUntil { await source.heldCount == 1 }
        XCTAssertTrue(started)
        book.goTo(index: 2)
        await source.release(0)
        let image = await waiting.value
        XCTAssertNil(image)
        let requestCount = await source.requestCount
        XCTAssertEqual(requestCount, 1, "古い要求は読み直さない")
        XCTAssertEqual(book.pageCacheStats().count, 0)
        await book.close().value
    }

    /// 読み直しは 3 回まで。間引かれ続けたら nil で、何もキャッシュしない
    func testSupersededRetryIsBounded() async throws {
        let source = PrintAppearanceStubSource(outcomes: Array(repeating: .superseded, count: 6))
        let book = try await Book.open(source: source, printAppearance: .low)
        let image = await PageRequestIntent.$isDisplay.withValue(true) { await book.image(at: 0) }
        XCTAssertNil(image)
        let requestCount = await source.requestCount
        XCTAssertEqual(requestCount, 4, "最初の 1 回と読み直し 3 回")
        XCTAssertEqual(book.pageCacheStats().count, 0)
        await book.close().value
    }

    /// 辞退・取り消し・間引きのどれでも何もキャッシュしない
    func testNothingIsCachedForDeclinedCancelledOrShedLoads() async throws {
        let source = PrintAppearanceStubSource(outcomes: [.declined, .cancelled, .superseded, .superseded,
                                                          .superseded, .superseded])
        let book = try await Book.open(source: source, printAppearance: .standard)
        let declined = await PageRequestIntent.$isPrefetch.withValue(true) { await book.image(at: 0) }
        XCTAssertNil(declined)
        XCTAssertEqual(book.pageCacheStats().count, 0)
        let cancelled = await book.image(at: 1)
        XCTAssertNil(cancelled)
        XCTAssertEqual(book.pageCacheStats().count, 0)
        let shed = await book.image(at: 2)
        XCTAssertNil(shed)
        XCTAssertEqual(book.pageCacheStats().count, 0)
        await book.close().value
    }

    // MARK: - 補助

    private func pixelValue(_ image: CGImage) -> UInt8? {
        guard let data = image.dataProvider?.data, CFDataGetLength(data) > 0 else { return nil }
        return CFDataGetBytePtr(data)[0]
    }

    private func waitUntil(timeout: Duration = .seconds(5),
                           _ condition: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}

/// 印のキーとリサンプル・表示の照合(設計書 §5)。切っているときのキーは従来の書式のまま
@MainActor
final class PrintAppearanceKeyTests: XCTestCase {
    /// 切・各段階で最終・強の中間・超解像のキーがすべて別になり、切のキーは従来の書式と 1 バイトも違わない
    func testResamplerKeysAreDistinctPerTagAndUnchangedWhenOff() async throws {
        let book = try await Book.open(source: PrintAppearanceStubSource())
        let image = try XCTUnwrap(PrintAppearanceStubSource.page(value: 90))
        let source = DecodedPageInfo(image)
        let target = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.sRGB)!)
        let size = CGSize(width: 4, height: 6)
        let entryID = 7
        var finals: Set<String> = [], strongs: Set<String> = [], superResolutions: Set<String> = []
        for level in [nil] + PrintAppearanceLevel.allCases.map(Optional.some) {
            book.updatePrintAppearance(level)
            let pageKey = book.pageKey(forEntryID: entryID)
            for processing in [ImageProcessingSettings(interpolation: .systemDefault, noiseReduction: .none),
                               ImageProcessingSettings(interpolation: .high, noiseReduction: .strong)] {
                finals.insert(try XCTUnwrap(ImageResampler.cacheIdentity(source: source, to: size, cacheKey: pageKey,
                    processing: processing, displayTarget: target)))
            }
            strongs.insert(ImageResampler.strongIntermediateKey(cacheKey: pageKey, image: image))
            superResolutions.insert(ImageResampler.superResolutionKey(cacheKey: pageKey, image: image))
        }
        XCTAssertEqual(finals.count, 8)
        XCTAssertEqual(strongs.count, 4)
        XCTAssertEqual(superResolutions.count, 4)

        // 切: 従来の書式("<本のキー>#<ID>" に寸法・処理・色空間を続ける)
        book.updatePrintAppearance(nil)
        let pageKey = book.pageKey(forEntryID: entryID)
        XCTAssertEqual(pageKey, "\(book.cacheKey)#7")
        let sourceSpace = source.colorSpaceIdentity
        XCTAssertEqual(ImageResampler.cacheIdentity(source: source, to: size, cacheKey: pageKey,
            processing: ImageProcessingSettings(interpolation: .systemDefault, noiseReduction: .none),
            displayTarget: target),
            "\(book.cacheKey)#7|8x12|4x6|false|nr0|src-cs:\(sourceSpace)|cs:\(target.identity)")
        let imageSpace = image.colorSpace.map(DisplayColorTarget.identity) ?? "none"
        XCTAssertEqual(ImageResampler.strongIntermediateKey(cacheKey: pageKey, image: image),
                       "\(book.cacheKey)#7|8x12|nr-strong|cs:\(imageSpace)")
        XCTAssertEqual(ImageResampler.superResolutionKey(cacheKey: pageKey, image: image),
                       "\(book.cacheKey)#7|8x12|sr4|cs:\(imageSpace)")
        // 入れているとき: 同じ書式の先頭の本のキーだけが印つきになる
        book.updatePrintAppearance(.standard)
        XCTAssertEqual(ImageResampler.superResolutionKey(cacheKey: book.pageKey(forEntryID: entryID), image: image),
                       "\(book.cacheKey)~pa\(PrintAppearance.engineVersion)s#7|8x12|sr4|cs:\(imageSpace)")
        await book.close().value
    }

    /// 処理条件の既定の印は空(切のとき従来と同じ等価判定)
    func testProcessingSettingsDefaultTagIsEmpty() {
        let plain = ImageProcessingSettings(interpolation: .systemDefault, noiseReduction: .none)
        XCTAssertEqual(plain.printAppearanceTag, "")
        XCTAssertEqual(plain, ImageProcessingSettings(interpolation: .systemDefault, noiseReduction: .none,
                                                      printAppearanceTag: ""))
        XCTAssertNotEqual(plain, ImageProcessingSettings(interpolation: .systemDefault, noiseReduction: .none,
                                                         printAppearanceTag: "~pa1s"))
    }

    /// 名前空間と印は setPages だけが画像と一緒に置き、別の印で作った完成画像は採用しない
    func testViewTakesPrefixAndTagFromSetPagesAndRejectsOtherTag() throws {
        let view = ReaderView(frame: CGRect(x: 0, y: 0, width: 160, height: 240))
        let input = try XCTUnwrap(PrintAppearanceStubSource.page(value: 90, width: 160, height: 240))
        let sources = [DecodedPageInfo(input)]
        let size = try XCTUnwrap(view.predictedResampleSizes(for: [CGSize(width: 160, height: 240)])?.first)
        let completed = try XCTUnwrap(PrintAppearanceStubSource.page(value: 90, width: Int(size.width),
                                                                     height: Int(size.height)))
        let tag = PrintAppearanceTag.tag(for: .standard)
        view.setPages([input], ids: [3], readsFromLeft: true, keyPrefix: "book\(tag)", printAppearanceTag: tag)
        XCTAssertEqual(view.resampleKeyPrefix, "book\(tag)")
        XCTAssertEqual(view.printAppearanceTag, tag)
        XCTAssertEqual(view.imageProcessingSettings.printAppearanceTag, tag)

        let target = view.displayColorTarget
        let sameTag = ResampledPage(size: size, image: completed,
                                    processing: view.imageProcessingSettings(printAppearanceTag: tag),
                                    colorTarget: target)
        let untagged = ResampledPage(size: size, image: completed,
                                     processing: view.imageProcessingSettings(printAppearanceTag: ""),
                                     colorTarget: target)
        XCTAssertTrue(view.canDisplayResampled([sameTag], sources: sources))
        XCTAssertFalse(view.canDisplayResampled([untagged], sources: sources), "別の印の完成画像は使わない")
        XCTAssertTrue(view.canDisplayResampled([untagged], sources: sources, printAppearanceTag: ""))

        // 完成画像の見開きは、差し替える前に新しい見開きの印で照合する
        view.setPages([completed], ids: [3], readsFromLeft: true, keyPrefix: "book", printAppearanceTag: "",
                      preResampled: [untagged], decodedSources: sources)
        XCTAssertEqual(view.resampleKeyPrefix, "book")
        XCTAssertEqual(view.printAppearanceTag, "")
        XCTAssertTrue(view.images.first === completed)
        // 印の食い違う完成画像の見開きは受け付けず、表示を変えない
        view.setPages([completed], ids: [4], readsFromLeft: true, keyPrefix: "other\(tag)", printAppearanceTag: tag,
                      preResampled: [untagged], decodedSources: sources)
        XCTAssertEqual(view.resampleKeyPrefix, "book")
        XCTAssertEqual(view.pageIDs, [3])
    }
}

/// 網点処理の設定キー(設計書 §5)。新設キーだけを使い、未知の値は既定として読み、書き戻さない
@MainActor
final class PrintAppearanceSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() async throws {
        suiteName = "print-appearance-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults, powerMonitor: PowerStateMonitor(center: NotificationCenter(),
            readState: { PowerConditions(isLowPowerModeEnabled: false, isThermalPressureActive: false) }))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
    }

    func testDefaultsAreOffAndStandard() {
        XCTAssertFalse(store.halftoneDisplayEnabled)
        XCTAssertEqual(store.halftoneDisplayStrength, .standard, "未設定でも 標準")
        XCTAssertNil(store.printAppearanceRequest)
        store.registerDefaults()
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayStrength"), 1)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["HalftoneDisplayMode"])
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["HalftoneDisplayStrength"],
                     "既定は登録だけで保存しない")
        XCTAssertFalse(store.halftoneDisplayEnabled)
        XCTAssertEqual(store.halftoneDisplayStrength, .standard)
    }

    func testRoundTripAndRequest() {
        store.registerDefaults()
        store.halftoneDisplayEnabled = true
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 1)
        XCTAssertEqual(store.printAppearanceRequest, .standard)
        for level in PrintAppearanceLevel.allCases {
            store.halftoneDisplayStrength = level
            XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayStrength"), level.rawValue)
            XCTAssertEqual(store.printAppearanceRequest, level)
        }
        store.halftoneDisplayEnabled = false
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 0)
        XCTAssertNil(store.printAppearanceRequest, "切なら段階によらず要求なし")
        XCTAssertEqual(store.halftoneDisplayStrength, .strong, "強さは切っても残る")
    }

    func testOutOfRangeValuesReadAsDefaultsAndAreNotWrittenBack() {
        store.registerDefaults()
        defaults.set(2, forKey: "HalftoneDisplayMode")
        defaults.set(7, forKey: "HalftoneDisplayStrength")
        XCTAssertFalse(store.halftoneDisplayEnabled)
        XCTAssertEqual(store.halftoneDisplayStrength, .standard)
        XCTAssertNil(store.printAppearanceRequest)
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayMode"), 2)
        XCTAssertEqual(defaults.integer(forKey: "HalftoneDisplayStrength"), 7)
        defaults.set(-1, forKey: "HalftoneDisplayStrength")
        defaults.set(1, forKey: "HalftoneDisplayMode")
        XCTAssertEqual(store.printAppearanceRequest, .standard)
        // 引数ドメインと同じ文字列の値も整数として読む
        defaults.set("2", forKey: "HalftoneDisplayStrength")
        XCTAssertEqual(store.printAppearanceRequest, .strong)
    }
}

/// 要求の段階ごとに違う値の灰色のページを返す読み込み元。holds なら要求を止め、テストが順に放す。
/// outcomes は放した順に結果を決める(空なら画像)
private actor PrintAppearanceStubSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/stub/print-appearance-book")
    nonisolated var supportsDateSort: Bool { false }

    struct Request: Sendable {
        let entryID: Int
        let level: PrintAppearanceLevel?
        let ticket: PrintAppearanceTicket?
        let prefetch: Bool
    }

    enum Outcome: Sendable {
        case image
        case superseded
        case declined
        case cancelled
    }

    nonisolated let supportsParallelPageLoads: Bool
    private let pageCount: Int
    private let holds: Bool
    private var outcomes: [Outcome]
    private(set) var requests: [Request] = []
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]

    init(pageCount: Int = 4, holds: Bool = false, outcomes: [Outcome] = [], parallel: Bool = false) {
        self.pageCount = pageCount
        self.holds = holds
        self.outcomes = outcomes
        supportsParallelPageLoads = parallel
    }

    var requestCount: Int { requests.count }
    var heldCount: Int { held.count }

    /// 段階ごとのページの値(切は 10)
    nonisolated static func value(for level: PrintAppearanceLevel?) -> UInt8 {
        switch level {
        case nil: 10
        case .low: 60
        case .standard: 120
        case .strong: 200
        }
    }

    nonisolated static func page(value: UInt8, width: Int = 8, height: Int = 12) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        memset(data, Int32(value), context.bytesPerRow * height)
        return context.makeImage()
    }

    func entries() async throws -> [PageEntry] {
        (0..<pageCount).map {
            PageEntry(id: $0, name: "p\($0).png", pathInBook: "p\($0).png",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
    }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let request = Request(entryID: entry.id, level: PageRequestIntent.printAppearance?.level,
                              ticket: PageRequestIntent.printAppearance?.ticket,
                              prefetch: PageRequestIntent.isPrefetch)
        let index = requests.count
        requests.append(request)
        if holds {
            await withCheckedContinuation { held[index] = $0 }
        }
        switch outcomes.isEmpty ? .image : outcomes.removeFirst() {
        case .image:
            guard let image = Self.page(value: Self.value(for: request.level)) else {
                throw BookSourceError.pageLoadFailed(entry.name)
            }
            return image
        case .superseded:
            throw PrintAppearanceService.Superseded()
        case .declined:
            throw PrefetchDecodeGate.Declined()
        case .cancelled:
            throw CancellationError()
        }
    }

    /// index 番目の要求を放す
    func release(_ index: Int) {
        held.removeValue(forKey: index)?.resume()
    }
}
