import AppKit
import Washi
import XCTest
@testable import cooViewer

@MainActor
final class ThumbnailInitialGenerationTests: XCTestCase {
    func testFirstEPUBScreenGeneratesFromCoverOnFirstShowAndReopen() async throws {
        try await checkInitialGeneration(epub: true, anchor: 0)
    }

    func testEPUBScreenGeneratesFromAnchorOnFirstShowAndReopen() async throws {
        try await checkInitialGeneration(epub: true, anchor: 123)
    }

    func testFirstImagePageGeneratesFromCoverOnFirstShowAndReopen() async throws {
        try await checkInitialGeneration(epub: false, anchor: 0)
    }

    func testImagePageGeneratesFromAnchorOnFirstShowAndReopen() async throws {
        try await checkInitialGeneration(epub: false, anchor: 123)
    }

    func testSupersededInitialViewportDoesNotGenerateForTheOldRange() async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ThumbnailInitialLayout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ThumbnailOverlayModel(defaults: defaults,
            thumbnailCache: ThumbnailCache(diskRoot: root, pressure: FixedMemoryPressure()))
        model.setCellSize(80, commit: false)
        let entries = (0..<437).map {
            PageEntry(id: $0, name: "\($0)", pathInBook: "\($0)",
                      fileURL: nil, creationDate: nil, modificationDate: nil)
        }
        let source = InitialThumbnailSource(entries: entries) {
            (model.viewportSize, model.snapshot.currentIndex)
        }
        var snapshot = ThumbnailOverlayModel.Snapshot()
        snapshot.entries = entries
        snapshot.source = source
        snapshot.bookKey = UUID().uuidString
        snapshot.currentIndex = 123
        snapshot.prefetchConcurrency = 2
        let started = expectation(description: "最終版面の先頭二件")
        await source.observe(count: 2, expectation: started)
        model.updateViewport(CGSize(width: 400, height: 400))
        model.present(snapshot: snapshot)
        model.updateViewport(CGSize(width: 1000, height: 700))
        let expected = Array(model.layout.groups(onScreen: model.screen).flatMap { $0 }.prefix(2))
        await fulfillment(of: [started], timeout: 3)
        let records = await source.records
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.entryID)), Set(expected))
        XCTAssertTrue(records.allSatisfy { $0.viewport == CGSize(width: 1000, height: 700) })
        let pending = model.clear()
        await source.stop()
        await pending?.value
    }

    private func checkInitialGeneration(epub: Bool, anchor: Int) async throws {
        let root = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ThumbnailInitialGeneration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ThumbnailCache(diskRoot: root, pressure: FixedMemoryPressure(),
                                   diskWriter: DeferredImageWriter())
        let model = ThumbnailOverlayModel(defaults: defaults, thumbnailCache: cache)
        model.setCellSize(80, commit: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = ReaderWindowController(window: window, thumbnailOverlayModel: model)
        controller.setUpContentViews(in: window)
        XCTAssertNil(controller.thumbnailHostingView)
        var originalHost: NSView?
        for presentation in 0..<2 {
            // 設計書 §2.4・§7.6: 閉じた間のリサイズでも旧画面の範囲から生成しない。
            if presentation == 1 { window.setContentSize(NSSize(width: 720, height: 580)) }
            let entries: [PageEntry]
            if epub {
                // 設計書 §2.4: 表紙一画面と本文の census から、実アダプタと同じ437画面を組む。
                let screens = EPUBScreenThumbnailSource.makeScreens(counts: [1, 872], pagesPerScreen: 2)
                let adapter = EPUBScreenThumbnailSource(url: root.appendingPathComponent("book.epub"),
                    screens: screens, view: EPUBReaderView())
                entries = adapter.pageEntries
                XCTAssertEqual(entries.count, 437)
                XCTAssertEqual(screens[0].spineIndex, 0)
                XCTAssertEqual(screens[1].pageInItem, 0)
            } else {
                entries = (0..<437).map {
                    PageEntry(id: $0, name: String(format: "%04d.avifs", $0), pathInBook: "\($0)",
                              fileURL: nil, creationDate: nil, modificationDate: nil)
                }
            }
            let source = InitialThumbnailSource(entries: entries) {
                (model.viewportSize, model.snapshot.currentIndex)
            }
            let firstWave = expectation(description: "現在画面の先頭二件")
            await source.observe(count: 2, expectation: firstWave)
            var book: Book?
            if epub {
                var snapshot = ThumbnailOverlayModel.Snapshot()
                snapshot.entries = entries
                snapshot.source = source
                snapshot.bookKey = UUID().uuidString
                snapshot.currentIndex = anchor
                snapshot.displayedIndices = [anchor]
                snapshot.singleSetting = 0
                snapshot.prefetchConcurrency = 2
                controller.presentThumbnailOverlay(snapshot: snapshot)
            } else {
                let opened = Book(source: source, prepared: Book.prepare(
                    url: source.url, entries: entries, sortMode: .name, identity: .init()))
                opened.mediaProfile = MediaProfile(mediaClass: .slowLocal, conserveEnergy: false)
                opened.goTo(index: anchor)
                book = opened
                controller.presentThumbnailOverlay(for: opened)
            }
            controller.revealThumbnailOverlay()
            let visible = model.layout.groups(onScreen: model.screen).flatMap { $0 }
            XCTAssertTrue(visible.contains(anchor))
            let start = try XCTUnwrap(visible.first)
            await fulfillment(of: [firstWave], timeout: 3)
            for wave in 1...3 {
                let records = await source.records
                XCTAssertEqual(records.count, wave * 2)
                for offset in stride(from: 0, to: records.count, by: 2) {
                    // 設計書 §5: 並列二件内の到着順は任意だが、遠いセルは先頭を追い越さない。
                    XCTAssertEqual(Set(records[offset..<min(offset + 2, records.count)].map(\.entryID)),
                                   Set((start + offset)..<(start + offset + 2)))
                }
                XCTAssertTrue(records.allSatisfy { $0.viewport.width > 0 && $0.viewport.height > 0 })
                XCTAssertTrue(records.allSatisfy { $0.anchor == anchor })
                XCTAssertTrue(records.allSatisfy { $0.priority >= .userInitiated })
                XCTAssertTrue(model.initialPrefetchPending)
                if wave < 3 {
                    let nextWave = expectation(description: "現在画面の次の二件")
                    await source.observe(count: (wave + 1) * 2, expectation: nextWave)
                    await source.finishPending()
                    await fulfillment(of: [nextWave], timeout: 3)
                }
            }
            XCTAssertTrue(Set((start..<(start + 4))).isSubset(of: Set(model.measuredAspects.keys)))
            if let originalHost { XCTAssertTrue(controller.thumbnailHostingView === originalHost) }
            else { originalHost = controller.thumbnailHostingView }
            let pending = controller.hideThumbnailOverlay()
            await source.stop()
            await pending?.value
            await book?.close().value
        }
        model.clear()
        controller.thumbnailHostingView?.layoutSubtreeIfNeeded()
    }
}

/// 設計書 §7.6: 実 WebKit・I/O の代わりに生成の開始と完了を止め、要求順を記録する。
private actor InitialThumbnailSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/test/initial-thumbnail-\(UUID().uuidString)")
    nonisolated let supportsDateSort = false
    struct Record {
        let entryID: Int
        let viewport: CGSize
        let anchor: Int
        let priority: TaskPriority
    }
    private let pages: [PageEntry]
    private let state: @MainActor @Sendable () -> (CGSize, Int)
    private var stopped = false
    private var pending: [UUID: CheckedContinuation<CGImage, any Error>] = [:]
    private var observations: [Int: XCTestExpectation] = [:]
    private(set) var records: [Record] = []

    init(entries: [PageEntry], state: @escaping @MainActor @Sendable () -> (CGSize, Int)) {
        pages = entries
        self.state = state
    }

    func entries() async throws -> [PageEntry] { pages }
    func containsProtectedContent() async -> Bool { true }
    func observe(count: Int, expectation: XCTestExpectation) { observations[count] = expectation }

    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let (viewport, anchor) = await state()
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                records.append(Record(entryID: entry.id, viewport: viewport, anchor: anchor,
                                      priority: Task.currentPriority))
                observations.removeValue(forKey: records.count)?.fulfill()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func finishPending() {
        let context = CGContext(data: nil, width: 12, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: image) }
    }

    func stop() {
        stopped = true
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }
}
