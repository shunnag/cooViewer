import AppKit
import os
import XCTest
@testable import cooViewer

final class DecodedOriginalRetentionPolicyTests: XCTestCase {
    func testOnlyDisplayReadyPagesStrictlyBeyondBehindAreEvicted() {
        func evicts(_ index: Int, behind: Int = 3, protected: Bool = false, ready: Bool = true) -> Bool {
            DecodedOriginalRetentionPolicy.canEvict(index: index, currentIndex: 10,
                decodeBehind: behind, adjacentIndices: 8..<14, protected: protected, displayReady: ready)
        }
        XCTAssertTrue(evicts(6))
        XCTAssertFalse(evicts(7))
        XCTAssertFalse(evicts(8, behind: 0))
        XCTAssertFalse(evicts(9, behind: 0))
        XCTAssertFalse(evicts(10, behind: 0))
        XCTAssertFalse(evicts(11, behind: 0))
        XCTAssertFalse(evicts(14, behind: 0))
        XCTAssertFalse(evicts(-1))
        XCTAssertFalse(evicts(6, protected: true))
        XCTAssertFalse(evicts(6, ready: false))
        XCTAssertFalse(evicts(6, behind: 16))
    }

    func testResampledOnlyDisplayIsLimitedToNormalDisplayModes() {
        for mode in [ReaderFitMode.fitToScreen, .fitWidth, .fitWidthDivide] {
            for quality in [ImageInterpolation.systemDefault, .high] {
                XCTAssertTrue(ResampledDisplayPolicy.allows(fitMode: mode, rotation: 0,
                    zoomed: false, loupe: false, interpolation: quality))
            }
        }
        XCTAssertFalse(ResampledDisplayPolicy.allows(fitMode: .noScale, rotation: 0,
            zoomed: false, loupe: false, interpolation: .high))
        for rotation in 1...3 {
            XCTAssertFalse(ResampledDisplayPolicy.allows(fitMode: .fitToScreen, rotation: rotation,
                zoomed: false, loupe: false, interpolation: .high))
        }
        XCTAssertFalse(ResampledDisplayPolicy.allows(fitMode: .fitToScreen, rotation: 0,
            zoomed: true, loupe: false, interpolation: .high))
        XCTAssertFalse(ResampledDisplayPolicy.allows(fitMode: .fitToScreen, rotation: 0,
            zoomed: false, loupe: true, interpolation: .high))
        for quality in [ImageInterpolation.none, .low] {
            XCTAssertFalse(ResampledDisplayPolicy.allows(fitMode: .fitToScreen, rotation: 0,
                zoomed: false, loupe: false, interpolation: quality))
        }
    }
}

@MainActor
final class DecodedOriginalRetentionTests: XCTestCase {
    private final class Source: BookSource, @unchecked Sendable {
        let url = URL(fileURLWithPath: "/stub/decoded-retention")
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let singlePageHints: Set<Int>
        init(singlePageHints: Set<Int> = []) { self.singlePageHints = singlePageHints }
        var supportsDateSort: Bool { false }
        var loadCount: Int { counter.withLock { $0 } }
        func entries() async throws -> [PageEntry] {
            (0..<20).map { index in
                PageEntry(id: 100 + index * 3, name: "\(index).png", pathInBook: "\(index).png",
                          fileURL: nil, creationDate: nil, modificationDate: nil)
            }
        }
        func imageSize(for entry: PageEntry) async -> CGSize? { CGSize(width: 64, height: 96) }
        func layoutSinglePageIndices() async -> Set<Int> { singlePageHints }
        func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
            counter.withLock { $0 += 1 }
            return try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        }
    }

    private func makeBook(resampler: ImageResampler = .shared, singlePageHints: Set<Int> = []) async throws -> (Book, Source) {
        let source = Source(singlePageHints: singlePageHints)
        let entries = try await source.entries()
        let book = Book(source: source, prepared: .init(sortedEntries: entries, cacheKey: UUID().uuidString), resampler: resampler)
        book.readMode = .rightToLeftSingle
        book.prefetchAhead = 0
        book.prefetchBehind = 0
        book.updateResampledDisplayContext("test")
        return (book, source)
    }

    private func completedPages(_ candidate: Book.DisplayCandidate, book: Book,
                                resampler: ImageResampler = .shared) async throws -> [ResampledPage] {
        let target = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.sRGB)!)
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        let size = CGSize(width: 32, height: 48)
        var pages: [ResampledPage] = []
        for index in candidate.indices {
            let image = await resampler.resample(input, to: size,
                cacheKey: "\(book.cacheKey)#\(book.entries[index].id)", upscaleWithMetalFX: false, displayTarget: target)
            pages.append(ResampledPage(size: size, image: try XCTUnwrap(image),
                processing: .init(interpolation: .systemDefault, noiseReduction: .none), colorTarget: target))
        }
        return pages
    }

    private func populate(_ book: Book, through end: Int) async {
        for index in 0...end {
            book.goTo(index: index)
            _ = await book.currentSpread()
        }
        await book.waitForPrefetch()
    }

    func testFirstAndForwardDisplaysDoNotTryTheResampledOnlyPath() async throws {
        let (book, source) = try await makeBook()
        XCTAssertNil(book.resampledDisplayCandidate())
        XCTAssertEqual(source.loadCount, 0)
        await populate(book, through: 4)
        XCTAssertNil(book.resampledDisplayCandidate())
        book.goTo(index: 15)
        XCTAssertNil(book.resampledDisplayCandidate())
        XCTAssertEqual(source.loadCount, 5)
        await book.close().value
    }

    func testOldEvictionDecisionCannotDeleteAfterPositionOrDisplayContextChanges() async throws {
        let (book, _) = try await makeBook()
        await populate(book, through: 10)
        let old = try XCTUnwrap(book.decodedRetentionCandidates().first)
        let count = book.pageCacheStats().count
        book.goTo(index: 9)
        book.evictDecodedOriginals(Set(old.indices), candidate: old, pages: try await completedPages(old, book: book), protectedPageKeys: [])
        XCTAssertEqual(book.pageCacheStats().count, count)
        let changed = try XCTUnwrap(book.decodedRetentionCandidates().first)
        book.updateResampledDisplayContext("resized")
        book.evictDecodedOriginals(Set(changed.indices), candidate: changed, pages: try await completedPages(changed, book: book), protectedPageKeys: [])
        XCTAssertEqual(book.pageCacheStats().count, count)
        await book.close().value
    }

    func testUnvisitedPreresampledPageCanBeReleasedAfterJump() async throws {
        let (book, _) = try await makeBook()
        _ = await book.image(at: 0)
        book.noteResampleLayout([0])
        book.goTo(index: 10)
        _ = await book.currentSpread()
        let candidate = try XCTUnwrap(book.decodedRetentionCandidates().first)
        XCTAssertEqual(candidate.indices, [0])
        book.evictDecodedOriginals([0], candidate: candidate, pages: try await completedPages(candidate, book: book), protectedPageKeys: [])
        XCTAssertTrue(book.hasMissingOriginal(at: [0]))
        await book.close().value
    }

    func testEvictionPreservesDistanceAdjacentDisplayedAndPlannedPages() async throws {
        let (book, _) = try await makeBook()
        await populate(book, through: 10)
        book.prefetchBehind = 3
        let before = book.pageCacheStats()
        let candidates = book.decodedRetentionCandidates()
        XCTAssertEqual(Set(candidates.flatMap(\.indices)), Set(0...6))
        for candidate in candidates {
            book.evictDecodedOriginals(Set(candidate.indices), candidate: candidate, pages: try await completedPages(candidate, book: book),
                protectedPageKeys: ["\(book.cacheKey)#\(book.entries[0].id)"])
        }
        XCTAssertEqual(book.pageCacheStats().count, before.count - 6)
        XCTAssertLessThan(book.pageCacheStats().cost, before.cost)
        XCTAssertFalse(book.hasMissingOriginal(at: [0, 7, 8, 9, 10]))
        XCTAssertTrue(book.hasMissingOriginal(at: [1]))
        XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: 0))
        XCTAssertTrue(book.hasCachedResampleForEvictedOriginal(at: 1))
        for index in 7...10 { XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: index)) }
        _ = await book.image(at: 1)
        XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: 1))
        await book.close().value
    }

    func testDecodeAheadResumesAfterAnotherWindowEvictsCompletedImages() async throws {
        let resampler = ImageResampler(byteLimit: 8 * 32 * 48 * 4, pressure: FixedMemoryPressure())
        let (book, source) = try await makeBook(resampler: resampler)
        await populate(book, through: 10)
        book.prefetchBehind = 3
        for candidate in book.decodedRetentionCandidates() {
            let pages = try await completedPages(candidate, book: book, resampler: resampler)
            book.evictDecodedOriginals(Set(candidate.indices), candidate: candidate, pages: pages, protectedPageKeys: [])
        }
        for index in 1...6 { XCTAssertTrue(book.hasCachedResampleForEvictedOriginal(at: index)) }
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        for index in 0..<5 {
            _ = await resampler.resample(input, to: CGSize(width: 48, height: 72),
                cacheKey: "other-window#\(index)", upscaleWithMetalFX: false)
        }
        let before = source.loadCount
        book.goTo(index: 0)
        book.prefetchAhead = 6
        book.prefetchBehind = 0
        _ = await book.currentSpread()
        await book.waitForPrefetch()
        XCTAssertEqual(source.loadCount, before + 7)
        XCTAssertFalse(book.hasMissingOriginal(at: Array(1...6)))
        for index in 1...6 { XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: index)) }
        await book.close().value
    }

    func testResidencyTracksPressureAndMLFallbackRemoval() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        let size = CGSize(width: 32, height: 48)
        let processing = ImageProcessingSettings(interpolation: .systemDefault, noiseReduction: .none)
        let resampler = ImageResampler(byteLimit: 3 * 32 * 48 * 4, pressure: FixedMemoryPressure())
        var keys: [String] = []
        for index in 0..<3 {
            let pageKey = "pressure#\(index)"
            _ = await resampler.resample(input, to: size, cacheKey: pageKey, upscaleWithMetalFX: false)
            keys.append(try XCTUnwrap(ImageResampler.cacheIdentity(source: DecodedPageInfo(input), to: size,
                cacheKey: pageKey, processing: processing, displayTarget: nil)))
        }
        XCTAssertTrue(keys.allSatisfy(resampler.cacheResidency.contains))
        await resampler.applyMemoryPressure(.critical)
        XCTAssertFalse(resampler.cacheResidency.contains(keys[0]))
        XCTAssertFalse(resampler.cacheResidency.contains(keys[1]))
        XCTAssertTrue(resampler.cacheResidency.contains(keys[2]))

        let fallback = ImageResampler(pressure: FixedMemoryPressure(), noiseReductionOverride: { image, _ in image })
        _ = await fallback.resample(input, to: size, cacheKey: "fallback#0",
            upscaleWithMetalFX: false, noiseReduction: .strong)
        let key = try XCTUnwrap(ImageResampler.cacheIdentity(source: DecodedPageInfo(input), to: size,
            cacheKey: "fallback#0", processing: .init(interpolation: .systemDefault, noiseReduction: .strong), displayTarget: nil))
        XCTAssertTrue(fallback.cacheResidency.contains(key))
        await fallback.removeMLFallbackEntries()
        XCTAssertFalse(fallback.cacheResidency.contains(key))
    }

    func testLayoutSettingsInvalidateEvictedResampleReceipts() async throws {
        for change in 0..<5 {
            let (book, _) = try await makeBook(singlePageHints: [0])
            await populate(book, through: 10)
            let candidate = try XCTUnwrap(book.decodedRetentionCandidates().first { $0.indices == [0] })
            let pages = try await completedPages(candidate, book: book)
            book.evictDecodedOriginals([0], candidate: candidate, pages: pages, protectedPageKeys: [])
            XCTAssertTrue(book.hasCachedResampleForEvictedOriginal(at: 0))
            let revision = book.spreadLayoutRevision
            switch change {
            case 0: book.readMode = .rightToLeftSpread
            case 1: book.marks.setForcedSingle(0)
            case 2: book.coverSingleFirst = true
            case 3: book.singleSetting += 1
            default: await book.loadComicInfoState(useLayoutHints: false)
            }
            XCTAssertGreaterThan(book.spreadLayoutRevision, revision)
            XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: 0))
            await book.close().value
        }
    }

    func testDisplayPathMissClearsTheEvictedResampleReceipt() async throws {
        let (book, _) = try await makeBook()
        await populate(book, through: 10)
        let old = try XCTUnwrap(book.decodedRetentionCandidates().first { $0.indices == [0] })
        book.evictDecodedOriginals([0], candidate: old, pages: try await completedPages(old, book: book), protectedPageKeys: [])
        book.goTo(index: 0)
        let candidate = try XCTUnwrap(book.resampledDisplayCandidate())
        book.clearResampledDisplayMiss(candidate)
        XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: 0))
        XCTAssertNil(book.resampledDisplayCandidate())
        let pages = try await completedPages(candidate, book: book)
        XCTAssertNotNil(book.acceptResampledDisplay(candidate, pages: pages))
        XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: 0))
        await book.close().value
    }

    func testViewContextChangesInvalidateReceiptsWithoutARefreshDisplay() async throws {
        for change in 0..<8 {
            let (book, _) = try await makeBook()
            await populate(book, through: 10)
            let candidate = try XCTUnwrap(book.decodedRetentionCandidates().first { $0.indices == [0] })
            book.evictDecodedOriginals([0], candidate: candidate,
                pages: try await completedPages(candidate, book: book), protectedPageKeys: [])
            XCTAssertTrue(book.hasCachedResampleForEvictedOriginal(at: 0))
            let view = ReaderView(frame: CGRect(x: 0, y: 0, width: 16, height: 24))
            var notifications = 0
            view.onResampledDisplayContextChanged = {
                notifications += 1
                book.updateResampledDisplayContext("view-\(notifications)")
            }
            switch change {
            case 0: view.setFrameSize(CGSize(width: 20, height: 30))
            case 1: view.setBoundsSize(CGSize(width: 20, height: 30))
            case 2: view.fitMode = .fitWidth
            case 3: view.rotation = 1
            case 4: view.interpolation = .low
            case 5: view.noiseReductionLevel = .light
            case 6: view.singleSetting += 1
            default: _ = view.invalidateDisplayColorSpace(to: DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.displayP3)!))
            }
            XCTAssertGreaterThan(notifications, 0)
            XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: 0))
            await book.close().value
        }
    }

    func testEvictionRejectsACompletedImageThatWasDroppedAfterLookup() async throws {
        let resampler = ImageResampler(byteLimit: 1, pressure: FixedMemoryPressure())
        let (book, _) = try await makeBook(resampler: resampler)
        await populate(book, through: 10)
        let candidate = try XCTUnwrap(book.decodedRetentionCandidates().first { $0.indices == [0] })
        let pages = try await completedPages(candidate, book: book, resampler: resampler)
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        _ = await resampler.resample(input, to: CGSize(width: 16, height: 24), cacheKey: "replacement", upscaleWithMetalFX: false)
        book.evictDecodedOriginals([0], candidate: candidate, pages: pages, protectedPageKeys: [])
        XCTAssertFalse(book.hasMissingOriginal(at: [0]))
        XCTAssertFalse(book.hasCachedResampleForEvictedOriginal(at: 0))
        await book.close().value
    }

    func testBackwardDisplayAndDecodePrefetchUseCompletedImagesWithoutOriginals() async throws {
        let (book, source) = try await makeBook()
        let view = ReaderView(frame: CGRect(x: 0, y: 0, width: 16, height: 24))
        let target = view.displayColorTarget
        let size = CGSize(width: 32, height: 48)
        for index in 0...10 {
            book.goTo(index: index)
            let spread = await book.currentSpread()
            let image = try XCTUnwrap(spread.images.first.flatMap { $0 })
            _ = await ImageResampler.shared.resample(image, to: size,
                cacheKey: "\(book.cacheKey)#\(book.entries[index].id)", upscaleWithMetalFX: false,
                displayTarget: target)
        }
        for candidate in book.decodedRetentionCandidates() {
            book.evictDecodedOriginals(Set(candidate.indices), candidate: candidate, pages: try await completedPages(candidate, book: book), protectedPageKeys: [])
        }
        let before = source.loadCount
        book.goTo(index: 4)
        book.prefetchAhead = 2
        book.prefetchBehind = 3
        let candidate = try XCTUnwrap(book.resampledDisplayCandidate())
        let hit = await ImageResampler.shared.cached(source: candidate.sources[0], to: size,
            cacheKey: "\(book.cacheKey)#\(book.entries[4].id)", upscaleWithMetalFX: false, displayTarget: target)
        let page = ResampledPage(size: size, image: try XCTUnwrap(hit),
            processing: view.imageProcessingSettings, colorTarget: target)
        let spread = try XCTUnwrap(book.acceptResampledDisplay(candidate, pages: [page]))
        var lazyLoads = 0
        view.setPages(spread.images.compactMap { $0 }, ids: [book.entries[4].id], readsFromLeft: false,
            preResampled: [page], decodedSources: candidate.sources, originalLoader: { _ in
                lazyLoads += 1
                return nil
            })
        _ = view.snapshotContent()
        await book.waitForPrefetch()
        XCTAssertEqual(source.loadCount, before)
        XCTAssertEqual(lazyLoads, 0)
        XCTAssertEqual(view.sourceImageSizes, [CGSize(width: 64, height: 96)])
        XCTAssertTrue(view.images[0] === hit)
        XCTAssertEqual(book.displayedPageCount, 1)
        await book.close().value
    }

    func testCandidateCannotCommitAfterJumpColorOrCapChange() async throws {
        let (book, _) = try await makeBook()
        await populate(book, through: 10)
        for candidate in book.decodedRetentionCandidates() {
            book.evictDecodedOriginals(Set(candidate.indices), candidate: candidate, pages: try await completedPages(candidate, book: book), protectedPageKeys: [])
        }
        book.goTo(index: 0)
        let candidate = try XCTUnwrap(book.resampledDisplayCandidate())
        let image = try ImageDecoding.decode(TestFixtures.pngData(width: 32, height: 48))
        let page = ResampledPage(size: CGSize(width: 32, height: 48), image: image,
            processing: .init(interpolation: .systemDefault, noiseReduction: .none))
        book.goTo(index: 1)
        XCTAssertNil(book.acceptResampledDisplay(candidate, pages: [page]))
        book.goTo(index: 0)
        XCTAssertNotNil(book.resampledDisplayCandidate())
        _ = book.updateDisplayColorTarget(DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.displayP3)!))
        XCTAssertNil(book.resampledDisplayCandidate())
        _ = await book.currentSpread()
        _ = book.updateDisplayPixelCap(8192)
        XCTAssertNil(book.resampledDisplayCandidate())
        await book.close().value
    }

    func testMetadataLookupRequiresExactSizeQualityAndBothColorProfiles() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        let source = DecodedPageInfo(input)
        let target = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.sRGB)!)
        let resampler = ImageResampler(pressure: FixedMemoryPressure())
        let size = CGSize(width: 32, height: 48)
        let result = await resampler.resample(input, to: size, cacheKey: "metadata#1",
            upscaleWithMetalFX: false, displayTarget: target)
        let hit = await resampler.cached(source: source, to: size, cacheKey: "metadata#1",
            upscaleWithMetalFX: false, displayTarget: target)
        XCTAssertNotNil(hit)
        XCTAssertTrue(result === hit)
        let differentSize = await resampler.cached(source: source, to: CGSize(width: 33, height: 49),
            cacheKey: "metadata#1", upscaleWithMetalFX: false, displayTarget: target)
        let differentQuality = await resampler.cached(source: source, to: size, cacheKey: "metadata#1",
            upscaleWithMetalFX: true, displayTarget: target)
        let differentNR = await resampler.cached(source: source, to: size, cacheKey: "metadata#1",
            upscaleWithMetalFX: false, noiseReduction: .light, displayTarget: target)
        let p3 = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.displayP3)!)
        let differentTarget = await resampler.cached(source: source, to: size, cacheKey: "metadata#1",
            upscaleWithMetalFX: false, displayTarget: p3)
        let p3Image = try XCTUnwrap(p3.converted(input))
        let differentSource = await resampler.cached(source: DecodedPageInfo(p3Image), to: size,
            cacheKey: "metadata#1", upscaleWithMetalFX: false, displayTarget: target)
        XCTAssertNil(differentSize)
        XCTAssertNil(differentQuality)
        XCTAssertNil(differentNR)
        XCTAssertNil(differentTarget)
        XCTAssertNil(differentSource)
    }

    func testCachedSpreadRequiresEveryPageAndKeepsUnequalPageGeometry() async throws {
        let images = try [64, 48].map { try ImageDecoding.decode(TestFixtures.pngData(width: $0, height: 96)) }
        let sources = images.map(DecodedPageInfo.init)
        let normal = ReaderView(frame: CGRect(x: 0, y: 0, width: 32, height: 24))
        let cached = ReaderView(frame: normal.frame)
        let targets = try XCTUnwrap(normal.predictedResampleSizes(for: sources.map(\.size)))
        var pages: [ResampledPage] = []
        for index in images.indices {
            let image = await ImageResampler.shared.resample(images[index], to: targets[index],
                cacheKey: "pair-\(UUID())", upscaleWithMetalFX: false, displayTarget: normal.displayColorTarget)
            pages.append(ResampledPage(size: targets[index], image: try XCTUnwrap(image),
                processing: normal.imageProcessingSettings, colorTarget: normal.displayColorTarget))
        }
        XCTAssertTrue(cached.canDisplayResampled(pages, sources: sources))
        XCTAssertFalse(cached.canDisplayResampled([pages[0]], sources: sources))
        var changed = pages
        changed[1] = ResampledPage(size: targets[1], image: pages[1].image,
            processing: .init(interpolation: .high, noiseReduction: .strong), colorTarget: normal.displayColorTarget)
        XCTAssertFalse(cached.canDisplayResampled(changed, sources: sources))
        var loads = 0
        normal.setPages(images, readsFromLeft: false, preResampled: pages.map { $0 })
        cached.setPages(pages.map(\.image), readsFromLeft: false, preResampled: pages.map { $0 },
            decodedSources: sources, originalLoader: { _ in loads += 1; return nil })
        XCTAssertEqual(cached.sourceImageSizes, sources.map(\.size))
        XCTAssertEqual(try XCTUnwrap(cached.snapshotContent()?.dataProvider?.data as Data?),
                       try XCTUnwrap(normal.snapshotContent()?.dataProvider?.data as Data?))
        XCTAssertEqual(loads, 0)
    }

    private func lazyView(inputs: [CGImage],
                          loader: @escaping @MainActor (Int) async -> CGImage?) async throws -> ReaderView {
        let view = ReaderView(frame: CGRect(x: 0, y: 0, width: 16 * inputs.count, height: 24))
        let sources = inputs.map(DecodedPageInfo.init)
        let sizes = try XCTUnwrap(view.predictedResampleSizes(for: sources.map(\.size)))
        var pages: [ResampledPage] = []
        for index in inputs.indices {
            let image = await ImageResampler.shared.resample(inputs[index], to: sizes[index],
                cacheKey: "lazy-\(UUID())", upscaleWithMetalFX: false, displayTarget: view.displayColorTarget)
            pages.append(ResampledPage(size: sizes[index], image: try XCTUnwrap(image),
                processing: view.imageProcessingSettings, colorTarget: view.displayColorTarget))
        }
        view.setPages(pages.map(\.image), readsFromLeft: true, preResampled: pages.map { $0 },
            decodedSources: sources, originalLoader: loader)
        return view
    }

    func testLazyOriginalAndDisplayImageAreCommittedTogetherAcrossRelayout() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        let view = try await lazyView(inputs: [input], loader: { _ in input })
        let old = view.images[0]
        let converting = expectation(description: "元画像の色変換を保留")
        var release: CheckedContinuation<CGImage?, Never>?
        view.originalDisplayImagePreparer = { _, _, _ in
            await withCheckedContinuation { release = $0; converting.fulfill() }
        }
        view.setFrameSize(CGSize(width: 32, height: 48))
        view.layoutSubtreeIfNeeded()
        await fulfillment(of: [converting], timeout: 3)
        // 設計書 §5: 変換待ちの配置更新が旧完成画像を新寸法の完成結果として固定してはならない。
        XCTAssertTrue(view.images[0] === old)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        try XCTUnwrap(release).resume(returning: input)
        await view.waitForOriginalImages()
        view.layoutSubtreeIfNeeded()
        let contents = try XCTUnwrap(view.layer?.sublayers?.first?.sublayers?.first?.contents as! CGImage?)
        XCTAssertTrue(view.images[0] === input)
        XCTAssertTrue(contents === input)
        XCTAssertEqual(contents.width, 64)
        XCTAssertEqual(contents.height, 96)
    }

    func testFailedOriginalRetriesAfterBackoffAndDoesNotSkipTheOtherPage() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        var calls = [0, 0]
        let view = try await lazyView(inputs: [input, input], loader: { index in
            calls[index] += 1
            return index == 0 && calls[index] == 1 ? nil : input
        })
        var now = ContinuousClock.now
        view.originalImageRetryNow = { now }
        view.setFrameSize(CGSize(width: 64, height: 48))
        view.layoutSubtreeIfNeeded()
        await view.waitForOriginalImages()
        XCTAssertEqual(calls, [1, 1])
        XCTAssertTrue(view.images[1] === input)
        for _ in 0..<3 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            await view.waitForOriginalImages()
        }
        XCTAssertEqual(calls, [1, 1])
        now = now.advanced(by: .seconds(1))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        await view.waitForOriginalImages()
        XCTAssertEqual(calls, [2, 1])
        XCTAssertTrue(view.images[0] === input)
    }

    func testFailedDisplayConversionRetriesWithoutAdoptingAnUnpreparedOriginal() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        var calls = 0
        let view = try await lazyView(inputs: [input], loader: { _ in input })
        let old = view.images[0]
        var now = ContinuousClock.now
        view.originalImageRetryNow = { now }
        view.originalDisplayImagePreparer = { _, _, _ in calls += 1; return calls == 1 ? nil : input }
        view.setFrameSize(CGSize(width: 32, height: 48))
        view.layoutSubtreeIfNeeded()
        await view.waitForOriginalImages()
        XCTAssertTrue(view.images[0] === old)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        await view.waitForOriginalImages()
        XCTAssertEqual(calls, 1)
        now = now.advanced(by: .seconds(1))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        await view.waitForOriginalImages()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(view.images[0] === input)
    }

    func testColorChangeDuringLazyConversionContinuesTheSpreadAndRetriesInterruptedPage() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        var calls = [0, 0]
        let view = try await lazyView(inputs: [input, input], loader: { index in calls[index] += 1; return input })
        let old = view.images[0]
        let converting = expectation(description: "旧出力色の変換を保留")
        var release: CheckedContinuation<CGImage?, Never>?
        var now = ContinuousClock.now
        view.originalImageRetryNow = { now }
        var first = true
        view.originalDisplayImagePreparer = { image, _, target in
            if first {
                first = false
                return await withCheckedContinuation { release = $0; converting.fulfill() }
            }
            return target.converted(image)
        }
        view.setFrameSize(CGSize(width: 64, height: 48))
        view.layoutSubtreeIfNeeded()
        await fulfillment(of: [converting], timeout: 3)
        let target = DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.displayP3)!)
        _ = view.invalidateDisplayColorSpace(to: target)
        try XCTUnwrap(release).resume(returning: input)
        await view.waitForOriginalImages()
        XCTAssertEqual(calls, [1, 1])
        XCTAssertTrue(view.images[0] === old)
        XCTAssertTrue(view.images[1] === input)
        now = now.advanced(by: .seconds(1))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        await view.waitForOriginalImages()
        XCTAssertEqual(calls, [2, 1])
        XCTAssertTrue(view.images[0] === input)
    }

    func testLateOriginalConversionCannotReplaceAChangedSpread() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        let replacement = try ImageDecoding.decode(TestFixtures.pngData(width: 48, height: 96))
        let view = try await lazyView(inputs: [input], loader: { _ in input })
        let converting = expectation(description: "旧見開きの変換を保留")
        let waiting = expectation(description: "旧取得の完了待機を開始")
        var release: CheckedContinuation<CGImage?, Never>?
        view.originalDisplayImagePreparer = { _, _, _ in
            await withCheckedContinuation { release = $0; converting.fulfill() }
        }
        view.setFrameSize(CGSize(width: 32, height: 48))
        view.layoutSubtreeIfNeeded()
        await fulfillment(of: [converting], timeout: 3)
        let drain = Task { waiting.fulfill(); await view.waitForOriginalImages() }
        await fulfillment(of: [waiting], timeout: 3)
        view.setPages([replacement], ids: [99], readsFromLeft: true)
        try XCTUnwrap(release).resume(returning: input)
        await drain.value
        XCTAssertEqual(view.pageIDs, [99])
        XCTAssertTrue(view.images[0] === replacement)
    }

    func testResampledOnlyDisplayKeepsPixelsAndRequestsOriginalForChangedGeometryOrQuality() async throws {
        let input = try ImageDecoding.decode(TestFixtures.pngData(width: 64, height: 96))
        for change in 0..<7 {
            let normal = ReaderView(frame: CGRect(x: 0, y: 0, width: 16, height: 24))
            let cached = ReaderView(frame: normal.frame)
            let size = try XCTUnwrap(normal.predictedResampleSizes(for: [DecodedPageInfo(input).size])?.first)
            let target = normal.displayColorTarget
            let image = await ImageResampler.shared.resample(input, to: size, cacheKey: "pixels-\(change)",
                upscaleWithMetalFX: false, displayTarget: target)
            let page = ResampledPage(size: size, image: try XCTUnwrap(image),
                processing: normal.imageProcessingSettings, colorTarget: target)
            normal.setPages([input], readsFromLeft: true, preResampled: [page])
            let loaded = expectation(description: "必要になった元画像の取得 \(change)")
            var calls = 0
            cached.setPages([page.image], readsFromLeft: true, preResampled: [page],
                decodedSources: [DecodedPageInfo(input)], originalLoader: { _ in
                    calls += 1
                    loaded.fulfill()
                    return input
                })
            let expected = try XCTUnwrap(normal.snapshotContent()?.dataProvider?.data as Data?)
            let actual = try XCTUnwrap(cached.snapshotContent()?.dataProvider?.data as Data?)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(calls, 0)
            switch change {
            case 0: cached.setFrameSize(CGSize(width: 20, height: 30))
            case 1: cached.rotation = 1
            case 2: cached.fitMode = .noScale
            case 3: cached.interpolation = .low
            case 4: _ = cached.invalidateDisplayColorSpace(to: DisplayColorTarget(rgb: CGColorSpace(name: CGColorSpace.displayP3)!))
            case 5: cached.restoreZoom(scale: 2, anchorRatio: CGPoint(x: 0.5, y: 0.5))
            default: cached.noiseReductionLevel = .light
            }
            cached.layoutSubtreeIfNeeded()
            await fulfillment(of: [loaded], timeout: 3)
            XCTAssertEqual(calls, 1)
        }
    }
}
