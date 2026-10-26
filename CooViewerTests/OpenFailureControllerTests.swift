import AppKit
import os
import XCTest
@testable import cooViewer

@MainActor
final class OpenFailureControllerTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/synthetic/open-failure/collection")

    func testAssemblyFailureAndWrappedFailureDoNotChangeHistoryOrBookStates() async throws {
        for wrapped in [false, true] {
            let (controller, store, directory) = try makeController()
            store.noteOpened(path: url.path)
            store.saveImageBook(path: url.path, snapshot: .init(displayName: "collection", pageIndex: 7,
                pagePath: "missing.zip/7.png", settings: .init(readMode: nil, sortMode: nil,
                    marks: PageMarks(), bookmarks: [.init(name: "keep", pageIndex: 7)])))
            let before = try files(in: directory)
            let failure = makeFailure()
            let error: any Error = wrapped
                ? NSError(domain: "test.wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: failure])
                : failure
            let source = OpenFailureTestSource(url: url, error: error)
            controller.openSourceFactory = { _ in source }
            await controller.openBook(at: url).value
            XCTAssertEqual(controller.book?.pageCount, 0)
            XCTAssertNotNil(controller.failedOpen)
            controller.saveCurrentBookState()
            XCTAssertEqual(try files(in: directory), before)
            // 不在記録は JSON を変えないため、最近の一覧も独立に確認する(設計書 §7.4)。
            XCTAssertTrue(store.recentBookPaths().contains(url.path))
        }
    }

    func testStaleGenerationFailureDoesNotReplaceNewerBook() async throws {
        let (controller, _, _) = try makeController()
        let started = XCTestExpectation(description: "古い組み立てを開始")
        let gate = OpenFailureTestGate()
        let old = OpenFailureTestSource(url: url, error: makeFailure(), started: started, gate: gate)
        let newerURL = url.deletingLastPathComponent().appendingPathComponent("newer")
        let newer = OpenFailureTestSource(url: newerURL, error: makeFailure(), failuresRemaining: 0)
        let originalURL = url
        controller.openSourceFactory = { request in request.url == originalURL ? old : newer }
        let pending = controller.openBook(at: url)
        await fulfillment(of: [started], timeout: 2)
        await controller.openBook(at: newerURL, atPage: 1).value
        let adopted = try XCTUnwrap(controller.book)
        await gate.release()
        await pending.value
        XCTAssertTrue(controller.book === adopted)
        XCTAssertEqual(controller.book?.source.url, newerURL)
        XCTAssertNil(controller.failedOpen)
    }

    func testRetryReusesSourceAndOriginalPageRequest() async throws {
        let (controller, _, _) = try makeController()
        let source = OpenFailureTestSource(url: url, error: makeFailure(), failuresRemaining: 1,
            reportsEncryptionAfterFirstRead: true)
        var factoryCalls = 0
        controller.openSourceFactory = { _ in factoryCalls += 1; return source }
        await controller.openBook(at: url, atPage: 2, allowCollectionDrill: false).value
        XCTAssertTrue((try XCTUnwrap(controller.failedOpen).source as AnyObject) === source)
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        await retry.value
        XCTAssertEqual(factoryCalls, 1)
        let calls = await source.entryCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.book?.currentIndex, 2)
        XCTAssertTrue((try XCTUnwrap(controller.book).source as AnyObject) === source)
        XCTAssertNil(controller.failedOpen)
        XCTAssertEqual(controller.openFailureObserverCount, 0)
    }

    func testReloadMenuValidationAndReplacementRemoveObservers() async throws {
        let (controller, _, _) = try makeController()
        let menu = NSMenuItem(title: "Reload", action: #selector(ReaderWindowController.reloadBook(_:)),
                              keyEquivalent: "r")
        XCTAssertFalse(controller.validateMenuItem(menu))
        let source = OpenFailureTestSource(url: url, error: makeFailure())
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        XCTAssertTrue(controller.validateMenuItem(menu))
        XCTAssertEqual(controller.openFailureObserverCount, 2)
        controller.replaceBook(nil)
        XCTAssertNil(controller.retryFailedOpen())
        XCTAssertFalse(controller.validateMenuItem(menu))
        XCTAssertEqual(controller.openFailureObserverCount, 0)
    }

    func testNotFoundChildrenOpenWithoutFailureOrConsent() async throws {
        try await checkNotFoundChildrenExcluded(openImage: false)
    }

    func testImageRequestSilentlyExcludesNotFoundCollectionChildren() async throws {
        try await checkNotFoundChildrenExcluded(openImage: true)
    }

    private func checkNotFoundChildrenExcluded(openImage: Bool) async throws {
        let (controller, _, directory) = try makeController()
        let folderURL = directory.deletingLastPathComponent().appendingPathComponent("collection")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data().write(to: folderURL.appendingPathComponent("missing.zip"))
        try TestFixtures.storedZip(entries: ["0.png", "1.png", "2.png"].map {
            (Array($0.utf8), TestFixtures.pngData(width: 2, height: 3))
        }).write(to: folderURL.appendingPathComponent("good.zip"))
        let imageURL = folderURL.appendingPathComponent("cover.png")
        if openImage { try TestFixtures.pngData(width: 2, height: 3).write(to: imageURL) }
        controller.fileSystemProbe = OpenFailureTestProbe(exists: true, isDirectory: !openImage)
        let unlocker = NestedUnlocker(vault: nil)
        let clock = AssemblyTestClock { _ in }
        var policy = AssemblyRetryPolicy.immediate
        policy.sleep = { try await clock.sleep($0) }
        policy.reachabilityProbe = { _ in true }
        let engineFactory = ArchiveEngineFactory(openFile: { kind, path, role in
            if path.hasSuffix("/missing.zip") { throw CocoaError(.fileReadNoSuchFile) }
            return try ArchiveEngineFactory.live.openFile(kind, path, role)
        }, openData: { _, _, _ in nil })
        let original = NestedFolderSource(folder: try FolderSource(url: folderURL, readSubFolders: false),
            unlocker: unlocker, engineFactory: engineFactory, retryPolicy: policy)
        var factoryCalls = 0
        controller.openSourceFactory = { request in
            factoryCalls += 1
            XCTAssertEqual(request.url.path, folderURL.path)
            return original
        }
        controller.openReachabilityPolicy.reachabilityProbe = { _ in true }
        await controller.openBook(at: openImage ? imageURL : folderURL, atPage: 2).value
        XCTAssertNil(controller.failedOpen)
        XCTAssertNil(controller.retryFailedOpen())
        XCTAssertFalse(controller.canOpenWithoutUnreadableVolumes)
        XCTAssertEqual(factoryCalls, 1)
        let book = try XCTUnwrap(controller.book)
        XCTAssertTrue((book.source as AnyObject) === original)
        XCTAssertTrue(original.unlocker === unlocker)
        XCTAssertFalse(book.isPartial)
        XCTAssertFalse(book.entries.contains { $0.pathInBook.hasPrefix("missing.zip") })
        if openImage { XCTAssertEqual(book.entries[book.currentIndex].name, "cover.png") }
        else { XCTAssertEqual(book.currentIndex, 2) }
    }

    func testWakeNotificationStartsRetryThroughRegisteredObserver() async throws {
        let (controller, _, _) = try makeController()
        let secondEntry = XCTestExpectation(description: "復帰通知で再読込")
        let source = OpenFailureTestSource(url: url, error: makeFailure(), secondEntry: secondEntry)
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        controller.workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [secondEntry], timeout: 2)
        XCTAssertEqual(controller.openFailureObserverCount, 0)
        controller.workspaceNotificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        let calls = await source.entryCalls
        XCTAssertEqual(calls, 2)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }

    func testCloseCancelsPendingOpenTask() async throws {
        let (controller, _, _) = try makeController()
        let started = XCTestExpectation(description: "組み立て開始")
        let gate = OpenFailureTestGate()
        let source = OpenFailureTestSource(url: url, error: makeFailure(), started: started, gate: gate)
        controller.openSourceFactory = { _ in source }
        let pending = controller.openBook(at: url)
        await fulfillment(of: [started], timeout: 2)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertTrue(pending.isCancelled)
        await gate.release()
        await pending.value
    }

    func testCloseClearsFailureAndOtherOpenKeepsItUntilNewPresentation() async throws {
        let (controller, _, _) = try makeController()
        let source = OpenFailureTestSource(url: url, error: makeFailure())
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertNil(controller.failedOpen)
        XCTAssertEqual(controller.openFailureObserverCount, 0)
        await controller.openBook(at: url).value
        let previous = try XCTUnwrap(controller.failedOpen)
        let other = controller.openBook(at: url.appendingPathComponent("other"))
        XCTAssertTrue(controller.failedOpen?.placeholder === previous.placeholder)
        XCTAssertTrue(controller.openFailurePresentation.statusHidden)
        XCTAssertTrue(controller.openFailurePresentation.buttonsHidden)
        XCTAssertFalse(controller.validateMenuItem(reloadMenuItem()))
        XCTAssertEqual(controller.openFailureObserverCount, 0)
        await other.value
        XCTAssertFalse(controller.book === previous.placeholder)
    }

    func testAutomaticRetryIsOneShotAndRequiresMatchingVolumeAndGeneration() async throws {
        let (controller, _, _) = try makeController()
        let source = OpenFailureTestSource(url: url, error: makeFailure())
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        let generation = controller.openGeneration
        XCTAssertNil(controller.automaticallyRetryFailedOpen(generation: generation - 1))
        XCTAssertNil(controller.automaticallyRetryFailedOpen(generation: generation,
            mountedPath: "/synthetic/open-failure-other"))
        let retry = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: generation,
            mountedPath: "/synthetic/open-failure"))
        await retry.value
        XCTAssertEqual(controller.failedOpen?.autoRetryUsed, true)
        XCTAssertNil(controller.automaticallyRetryFailedOpen(generation: controller.openGeneration))
        let calls = await source.entryCalls
        XCTAssertEqual(calls, 2)
    }

    func testMissingBookOnlyHidesHistoryWhenParentIsReachable() async throws {
        for reachable in [false, true] {
            let (controller, store, _) = try makeController()
            store.noteOpened(path: url.path)
            controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
            controller.openReachabilityPolicy.reachabilityProbe = { _ in reachable }
            await controller.openBook(at: url).value
            XCTAssertEqual(controller.failedOpen?.bookWasMissing, true)
            XCTAssertEqual(controller.failedOpen?.failure.volumeUnavailable, !reachable)
            XCTAssertEqual(store.recentBookPaths().contains(url.path), !reachable)
        }
    }

    func testSlideshowSkipsMissingBookWithoutReplacingCurrentBook() async throws {
        let (controller, _, _) = try makeController()
        let current = Book(source: OpenFailureTestSource(url: url, error: makeFailure()),
                           prepared: .empty(for: url))
        controller.replaceBook(current)
        controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
        controller.openReachabilityPolicy.reachabilityProbe = { _ in true }
        let timer = Timer(timeInterval: 100, repeats: true) { _ in }
        controller.slideshowTimer = timer
        await controller.openBook(at: url, fromSlideshow: true).value
        XCTAssertTrue(controller.book === current)
        XCTAssertTrue(controller.slideshowTimer === timer)
        XCTAssertNil(controller.failedOpen)
    }

    func testRetryReusesSourceWhenAbsentFolderHasBecomeDirectory() async throws {
        let (controller, _, directory) = try makeController()
        let folder = directory.deletingLastPathComponent().appendingPathComponent("remounted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let source = OpenFailureTestSource(url: folder, error: makeFailure(), failuresRemaining: 1)
        var factoryCalls = 0
        controller.openSourceFactory = { _ in factoryCalls += 1; return source }
        await controller.openBook(at: folder, atPage: 2).value
        let canonical = try XCTUnwrap(controller.failedOpen).canonicalPath
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(CanonicalPath.normalize(folder.path), CanonicalPath.normalize(canonical))
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        await retry.value
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue((try XCTUnwrap(controller.book).source as AnyObject) === source)
        XCTAssertEqual(controller.book?.currentIndex, 2)
    }

    func testRetryOfSlideshowFailureIsAnOrdinaryOpen() async throws {
        let (controller, _, _) = try makeController()
        let source = OpenFailureTestSource(url: url, error: makeFailure())
        controller.openSourceFactory = { _ in source }
        controller.slideshowTimer = Timer(timeInterval: 100, repeats: true) { _ in }
        await controller.openBook(at: url, fromSlideshow: true).value
        let previous = try XCTUnwrap(controller.failedOpen)
        XCTAssertFalse(previous.request.fromSlideshow)
        XCTAssertNil(controller.slideshowTimer)
        controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        await retry.value
        XCTAssertEqual(controller.failedOpen?.bookWasMissing, true)
        XCTAssertFalse(controller.book === previous.placeholder)
        XCTAssertEqual(controller.book?.pageCount, 0)
        XCTAssertFalse(try XCTUnwrap(controller.failedOpen).request.fromSlideshow)
    }

    func testRetryRetainsFailureAndHidesTextUntilBookIsAdopted() async throws {
        let (controller, _, _) = try makeController()
        let secondEntry = XCTestExpectation(description: "再読込の組み立てを停止")
        let gate = OpenFailureTestGate()
        let source = OpenFailureTestSource(url: url, error: makeFailure(), failuresRemaining: 1,
            secondEntry: secondEntry, retryGate: gate)
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        let previous = try XCTUnwrap(controller.failedOpen)
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        XCTAssertTrue(controller.failedOpen?.placeholder === previous.placeholder)
        XCTAssertTrue(controller.openFailurePresentation.statusHidden)
        XCTAssertTrue(controller.openFailurePresentation.buttonsHidden)
        XCTAssertFalse(controller.validateMenuItem(reloadMenuItem()))
        XCTAssertNil(controller.retryFailedOpen())
        await fulfillment(of: [secondEntry], timeout: 2)
        // ウインドウの再描画が挟まっても旧メッセージを HUD に重ねない(設計書 §7.4)。
        await controller.refreshDisplay()
        XCTAssertTrue(controller.openFailurePresentation.statusHidden)
        XCTAssertTrue(controller.openFailurePresentation.buttonsHidden)
        await gate.release()
        await retry.value
        XCTAssertEqual(controller.book?.pageCount, 4)
        XCTAssertNil(controller.failedOpen)
        XCTAssertTrue(controller.openFailurePresentation.statusHidden)
        XCTAssertTrue(controller.openFailurePresentation.buttonsHidden)
    }

    func testCancelledRetryBeforeFlowStartsRestoresPreviousFailureAffordances() async throws {
        let (controller, _, _) = try makeController()
        let source = OpenFailureTestSource(url: url, error: makeFailure())
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        let previous = try XCTUnwrap(controller.failedOpen)
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        retry.cancel()
        await retry.value
        XCTAssertTrue(controller.book === previous.placeholder)
        XCTAssertTrue(controller.failedOpen?.placeholder === previous.placeholder)
        XCTAssertFalse(controller.openFailurePresentation.statusHidden)
        XCTAssertFalse(controller.openFailurePresentation.buttonsHidden)
        XCTAssertTrue(controller.validateMenuItem(reloadMenuItem()))
        XCTAssertEqual(controller.openFailureObserverCount, 2)
        let calls = await source.entryCalls
        XCTAssertEqual(calls, 1)
    }

    func testNonAssemblyErrorRestoresFailureWithManualRetryTextAfterAutomaticRetry() async throws {
        let (controller, _, _) = try makeController()
        let failure = makeFailure(volumeUnavailable: true)
        let source = OpenFailureTestSource(url: url, error: failure,
            retryError: CocoaError(.fileReadCorruptFile))
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        let previous = try XCTUnwrap(controller.failedOpen)
        let retry = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: controller.openGeneration))
        await retry.value
        XCTAssertTrue(controller.book === previous.placeholder)
        XCTAssertEqual(controller.failedOpen?.autoRetryUsed, true)
        XCTAssertFalse(controller.openFailurePresentation.statusHidden)
        XCTAssertFalse(controller.openFailurePresentation.buttonsHidden)
        XCTAssertTrue(controller.validateMenuItem(reloadMenuItem()))
        XCTAssertEqual(controller.openFailureObserverCount, 0)
        let expected = OpenFailureMessage.text(for: failure, bookName: source.displayName, automaticRetryArmed: false)
        XCTAssertTrue(controller.openFailurePresentation.text.hasPrefix(expected))
    }

    func testWakeAndMountKeepAutomaticRetryArmedUntilLocationIsReachable() async throws {
        for mountedPath in [nil, "/synthetic/open-failure"] as [String?] {
            let (controller, _, _) = try makeController()
            let failure = makeFailure(volumeUnavailable: true)
            let source = OpenFailureTestSource(url: url, error: failure)
            controller.openSourceFactory = { _ in source }
            await controller.openBook(at: url).value
            let previous = try XCTUnwrap(controller.failedOpen)
            controller.openReachabilityPolicy.reachabilityProbe = { _ in
                XCTAssertFalse(Thread.isMainThread)
                return false
            }
            let probe = try XCTUnwrap(controller.automaticallyRetryFailedOpen(
                generation: controller.openGeneration, mountedPath: mountedPath))
            await probe.value
            XCTAssertTrue(controller.book === previous.placeholder)
            XCTAssertEqual(controller.failedOpen?.autoRetryUsed, false)
            XCTAssertEqual(controller.openFailureObserverCount, 2)
            let callsBeforeReachable = await source.entryCalls
            XCTAssertEqual(callsBeforeReachable, 1)
            let armed = OpenFailureMessage.text(for: failure, bookName: source.displayName)
            XCTAssertTrue(controller.openFailurePresentation.text.hasPrefix(armed))
            controller.openReachabilityPolicy.reachabilityProbe = { _ in true }
            let retry = try XCTUnwrap(controller.automaticallyRetryFailedOpen(
                generation: controller.openGeneration, mountedPath: mountedPath))
            await retry.value
            XCTAssertEqual(controller.failedOpen?.autoRetryUsed, true)
            XCTAssertEqual(controller.openFailureObserverCount, 0)
            let callsAfterReachable = await source.entryCalls
            XCTAssertEqual(callsAfterReachable, 2)
            let exhausted = OpenFailureMessage.text(for: failure, bookName: source.displayName,
                automaticRetryArmed: false)
            XCTAssertTrue(controller.openFailurePresentation.text.hasPrefix(exhausted))
        }
    }

    func testStaleReachabilityResultCannotConsumeAutomaticRetryForNewerBook() async throws {
        let (controller, _, _) = try makeController()
        let source = OpenFailureTestSource(url: url, error: makeFailure())
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        let probing = XCTestExpectation(description: "保存先の到達確認を停止")
        let gate = OpenFailureTestGate()
        controller.openReachabilityPolicy.reachabilityProbe = { _ in
            probing.fulfill()
            await gate.wait()
            return true
        }
        let probe = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: controller.openGeneration))
        await fulfillment(of: [probing], timeout: 2)
        let newer = Book(source: source, prepared: .empty(for: url))
        controller.replaceBook(newer)
        await gate.release()
        await probe.value
        XCTAssertTrue(controller.book === newer)
        XCTAssertNil(controller.failedOpen)
        let calls = await source.entryCalls
        XCTAssertEqual(calls, 1)
    }

    func testRenamedParentOnConnectedStorageIsMissingAndCanAutomaticallyRecheck() async throws {
        let (controller, store, directory) = try makeController()
        let parent = directory.deletingLastPathComponent().appendingPathComponent("original")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bookURL = URL(fileURLWithPath: CanonicalPath.normalize(parent.appendingPathComponent("book.zip").path))
        try Data().write(to: bookURL)
        store.noteOpened(path: bookURL.path)
        let requestedURL = URL(fileURLWithPath: try XCTUnwrap(store.recentBookPaths().first))
        try FileManager.default.moveItem(at: parent, to: parent.appendingPathExtension("renamed"))
        controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
        controller.openReachabilityPolicy.reachabilityProbe = AssemblyRetryPolicy.default.reachabilityProbe
        await controller.openBook(at: requestedURL).value
        XCTAssertEqual(controller.failedOpen?.bookWasMissing, true)
        XCTAssertEqual(controller.failedOpen?.failure.volumeUnavailable, false)
        XCTAssertTrue(store.recentBookPaths().isEmpty)
        let retry = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: controller.openGeneration))
        await retry.value
        XCTAssertEqual(controller.failedOpen?.autoRetryUsed, true)
        XCTAssertEqual(controller.failedOpen?.failure.volumeUnavailable, false)
    }

    func testAbsentVolumeAndAbsentVolumeRootDoNotMarkBookMissing() async throws {
        for suffix in ["/folder/book.zip", ""] {
            let (controller, store, _) = try makeController()
            let volume = URL(fileURLWithPath: "/Volumes/cooViewer-test-\(UUID())", isDirectory: true)
            let bookURL = URL(fileURLWithPath: volume.path + suffix, isDirectory: false)
            store.noteOpened(path: bookURL.path)
            controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
            controller.openMountPointExists = { url in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(url.path, volume.path)
                return false
            }
            await controller.openBook(at: bookURL).value
            XCTAssertEqual(controller.failedOpen?.failure.volumeUnavailable, true)
            XCTAssertTrue(store.recentBookPaths().contains(bookURL.path))
            let probe = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: controller.openGeneration))
            await probe.value
            XCTAssertEqual(controller.failedOpen?.autoRetryUsed, false)
        }
    }

    func testStorageTimeoutKeepsMissingBookInHistory() async throws {
        let (controller, store, _) = try makeController()
        store.noteOpened(path: url.path)
        controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
        let checking = XCTestExpectation(description: "保存先の応答を停止")
        let timer = XCTestExpectation(description: "保存先確認の期限を設定")
        let clock = AssemblyTestClock { if $0 == .seconds(2) { timer.fulfill() } }
        let gate = OpenFailureTestGate()
        controller.openReachabilityPolicy.sleep = { try await clock.sleep($0) }
        controller.openReachabilityPolicy.reachabilityProbe = { _ in
            checking.fulfill()
            await gate.wait()
            return false
        }
        let opening = controller.openBook(at: url)
        await fulfillment(of: [checking, timer], timeout: 2)
        clock.advance(.seconds(2))
        await opening.value
        XCTAssertEqual(controller.failedOpen?.failure.volumeUnavailable, true)
        XCTAssertTrue(store.recentBookPaths().contains(url.path))
        XCTAssertFalse(try XCTUnwrap(controller.failedOpen).automaticRetryArmed)
        XCTAssertEqual(controller.openFailureObserverCount, 0)
        let expected = OpenFailureMessage.textForNotFound(bookName: url.lastPathComponent,
            volumeUnavailable: true, automaticRetryArmed: false)
        XCTAssertTrue(controller.openFailurePresentation.text.hasPrefix(expected))
        await gate.release()
    }

    func testOtherOpenThatBeepsRestoresFailurePresentation() async throws {
        let (controller, _, _) = try makeController()
        let source = OpenFailureTestSource(url: url, error: makeFailure(volumeUnavailable: true))
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        let previous = try XCTUnwrap(controller.failedOpen)
        controller.openSourceFactory = { request in throw BookSourceError.unreadable(request.url) }
        let opening = controller.openBook(at: url.appendingPathComponent("different.zip"))
        XCTAssertTrue(controller.failedOpen?.placeholder === previous.placeholder)
        XCTAssertTrue(controller.openFailurePresentation.statusHidden)
        XCTAssertTrue(controller.openFailurePresentation.buttonsHidden)
        XCTAssertFalse(controller.validateMenuItem(reloadMenuItem()))
        await opening.value
        XCTAssertTrue(controller.book === previous.placeholder)
        XCTAssertFalse(controller.openFailurePresentation.statusHidden)
        XCTAssertFalse(controller.openFailurePresentation.buttonsHidden)
        XCTAssertTrue(controller.validateMenuItem(reloadMenuItem()))
        XCTAssertEqual(controller.openFailureObserverCount, 2)
    }

    func testRetryDrillDownWithoutAdoptionRestoresFailureAfterGenerationBump() async throws {
        let (controller, _, directory) = try makeController()
        let collection = directory.deletingLastPathComponent().appendingPathComponent("collection")
        try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
        try Data().write(to: collection.appendingPathComponent("inner.zip"))
        let source = OpenFailureTestSource(url: collection, error: makeFailure(), failuresRemaining: 1, pageNames: [])
        controller.openSourceFactory = { request in
            if request.url.lastPathComponent == "inner.zip" { throw BookSourceError.unreadable(request.url) }
            return source
        }
        await controller.openBook(at: collection).value
        let previous = try XCTUnwrap(controller.failedOpen)
        let generation = controller.openGeneration
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        await retry.value
        XCTAssertGreaterThan(controller.openGeneration, generation + 1)
        XCTAssertTrue(controller.book === previous.placeholder)
        XCTAssertTrue(controller.failedOpen?.placeholder === previous.placeholder)
        XCTAssertFalse(controller.isOpeningBook)
        XCTAssertFalse(controller.openFailurePresentation.statusHidden)
        XCTAssertFalse(controller.openFailurePresentation.buttonsHidden)
        XCTAssertTrue(controller.validateMenuItem(reloadMenuItem()))
        XCTAssertEqual(controller.openFailureObserverCount, 2)
    }

    func testDanglingSymlinkRequestReusesSourceWhenTargetAppears() async throws {
        let (controller, _, directory) = try makeController()
        let root = directory.deletingLastPathComponent()
        let target = root.appendingPathComponent("target")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let source = OpenFailureTestSource(url: alias, error: makeFailure(), failuresRemaining: 1)
        var factoryCalls = 0
        controller.openSourceFactory = { _ in factoryCalls += 1; return source }
        await controller.openBook(at: alias, atPage: 2).value
        XCTAssertEqual(controller.failedOpen?.originalPath, alias.standardizedFileURL.path)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(CanonicalPath.normalize(try XCTUnwrap(controller.failedOpen).canonicalPath),
                       CanonicalPath.normalize(target.path))
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        await retry.value
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue((try XCTUnwrap(controller.book).source as AnyObject) === source)
        XCTAssertEqual(controller.book?.currentIndex, 2)
    }

    func testDanglingSymlinkToAbsentVolumeDoesNotMarkBookMissing() async throws {
        let (controller, store, directory) = try makeController()
        let volume = URL(fileURLWithPath: "/Volumes/cooViewer-test-\(UUID())", isDirectory: true)
        let target = volume.appendingPathComponent("folder/book.zip")
        let alias = directory.deletingLastPathComponent().appendingPathComponent("alias.zip")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        store.noteOpened(path: alias.path)
        controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
        controller.openMountPointExists = { url in XCTAssertEqual(url.path, volume.path); return false }
        await controller.openBook(at: alias).value
        XCTAssertEqual(controller.failedOpen?.canonicalPath, target.path)
        XCTAssertEqual(controller.failedOpen?.failure.volumeUnavailable, true)
        XCTAssertEqual(store.recentBookPaths(), store.recentPaths())
    }

    func testMountMatchingAcceptsOriginalAndCanonicalLocations() async throws {
        for original in [false, true] {
            let (controller, _, directory) = try makeController()
            let root = directory.deletingLastPathComponent()
            let target = root.appendingPathComponent("target")
            let requests = root.appendingPathComponent("requests")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
            let alias = requests.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            let source = OpenFailureTestSource(url: alias, error: makeFailure(), failuresRemaining: 1)
            controller.openSourceFactory = { _ in source }
            await controller.openBook(at: alias).value
            let mountedURL = original ? requests : target
            let retry = try XCTUnwrap(controller.automaticallyRetryFailedOpen(
                generation: controller.openGeneration, mountedPath: CanonicalPath.normalize(mountedURL.path),
                originalMountedPath: mountedURL.standardizedFileURL.path))
            await retry.value
            XCTAssertTrue((try XCTUnwrap(controller.book).source as AnyObject) === source)
            XCTAssertNil(controller.failedOpen)
        }
    }

    func testMountDuringWakeProbeIsRecheckedBeforeGivingUp() async throws {
        let (controller, _, _) = try makeController()
        let volume = URL(fileURLWithPath: "/Volumes/cooViewer-test-\(UUID())", isDirectory: true)
        let bookURL = volume.appendingPathComponent("collection")
        let source = OpenFailureTestSource(url: bookURL, error: makeFailure(volumeUnavailable: true), failuresRemaining: 1)
        controller.openSourceFactory = { _ in source }
        let checking = XCTestExpectation(description: "復帰時の保存先確認を停止")
        let gate = OpenFailureTestGate()
        let mounts = OpenFailureMountProbe(checking: checking, gate: gate)
        controller.openMountPointExists = { _ in await mounts.exists() }
        await controller.openBook(at: bookURL).value
        let generation = controller.openGeneration
        let wake = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: generation))
        await fulfillment(of: [checking], timeout: 2)
        let mount = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: generation, mountedPath: volume.path))
        await gate.release()
        await wake.value
        await mount.value
        let calls = await mounts.calls
        XCTAssertEqual(calls, 2)
        let entries = await source.entryCalls
        XCTAssertEqual(entries, 2)
        XCTAssertNil(controller.failedOpen)
        XCTAssertEqual(controller.book?.pageCount, 4)
    }

    private func reloadMenuItem() -> NSMenuItem {
        NSMenuItem(title: "Reload", action: #selector(ReaderWindowController.reloadBook(_:)), keyEquivalent: "r")
    }

    private func makeFailure(cause: ReadFailureCause = .accessDenied,
                             volumeUnavailable: Bool = false) -> AssemblyFailure {
        AssemblyFailure(failures: [.init(relativePath: "sub/A-017.zip",
            url: url.appendingPathComponent("A-017.zip"), cause: cause, retryClass: .persistent)],
            total: 1, volumeUnavailable: volumeUnavailable, sourceURL: url)
    }

    func testDisconnectedRetryKeepsUnlockedSourceForLaterRecovery() async throws {
        let (controller, _, _) = try makeController()
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        let child = OpenFailurePasswordSource()
        let unlocker = NestedUnlocker(provider: { _, _ in
            prompts.withLock { $0 += 1 }
            return NestedPasswordAnswer(password: "pw", saveRequested: false)
        }, vault: nil)
        let source = OpenFailureTestSource(url: url, error: makeFailure(), failuresRemaining: 1,
            reportsEncryptionAfterFirstRead: true, beforeEntries: {
                let unlocked = await unlocker.unlock(child, name: "secret.zip")
                XCTAssertTrue(unlocked)
            })
        var factoryCalls = 0
        controller.openSourceFactory = { _ in factoryCalls += 1; return source }
        await controller.openBook(at: url, atPage: 2, allowCollectionDrill: false).value
        XCTAssertEqual(prompts.withLock { $0 }, 1)
        controller.fileSystemProbe = OpenFailureTestProbe(exists: false)
        controller.openMountPointExists = { _ in false }
        controller.openReachabilityPolicy.reachabilityProbe = { _ in false }
        try await XCTUnwrap(controller.retryFailedOpen()).value
        let disconnected = try XCTUnwrap(controller.failedOpen)
        XCTAssertTrue(disconnected.bookWasMissing)
        XCTAssertTrue(disconnected.sourceReusable)
        XCTAssertTrue((disconnected.source as AnyObject) === source)
        controller.fileSystemProbe = OpenFailureTestProbe(exists: true)
        controller.openReachabilityPolicy.reachabilityProbe = { _ in true }
        try await XCTUnwrap(controller.retryFailedOpen()).value
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertTrue((try XCTUnwrap(controller.book).source as AnyObject) === source)
        XCTAssertEqual(controller.book?.currentIndex, 2)
        let calls = await source.entryCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(prompts.withLock { $0 }, 1)
        // 外側の再解錠なら試験中はキャンセルになるため、同じソースの採用も確認する(設計書 §2.4、§7.4)。
        XCTAssertNil(controller.failedOpen)
    }

    func testAssemblyReachabilityTimeoutDoesNotPromiseAutomaticReload() async throws {
        let (controller, _, _) = try makeController()
        let original = makeFailure()
        let failure = AssemblyFailure(failures: original.failures, total: 1,
            volumeUnavailable: true, sourceURL: url, reachabilityTimedOut: true)
        let source = OpenFailureTestSource(url: url, error: failure)
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        XCTAssertFalse(try XCTUnwrap(controller.failedOpen).automaticRetryArmed)
        XCTAssertEqual(controller.openFailureObserverCount, 0)
        let expected = OpenFailureMessage.text(for: failure, bookName: source.displayName, automaticRetryArmed: false)
        XCTAssertTrue(controller.openFailurePresentation.text.hasPrefix(expected))
    }

    func testWakeProbeTimeoutReplacesAutomaticPromiseWithManualReload() async throws {
        let (controller, _, _) = try makeController()
        let failure = makeFailure(volumeUnavailable: true)
        controller.openSourceFactory = { _ in OpenFailureTestSource(url: self.url, error: failure) }
        await controller.openBook(at: url).value
        let checking = XCTestExpectation(description: "復帰後も保存先は応答しない")
        let timer = XCTestExpectation(description: "復帰後の確認期限を設定")
        let gate = OpenFailureTestGate()
        let clock = AssemblyTestClock { if $0 == .seconds(2) { timer.fulfill() } }
        controller.openMountPointExists = { _ in true }
        controller.openReachabilityPolicy.sleep = { try await clock.sleep($0) }
        controller.openReachabilityPolicy.reachabilityProbe = { _ in
            checking.fulfill()
            await gate.wait()
            return false
        }
        let probe = try XCTUnwrap(controller.automaticallyRetryFailedOpen(generation: controller.openGeneration))
        await fulfillment(of: [checking, timer], timeout: 2)
        clock.advance(.seconds(2))
        await probe.value
        XCTAssertFalse(try XCTUnwrap(controller.failedOpen).automaticRetryArmed)
        XCTAssertEqual(controller.failedOpen?.autoRetryUsed, false)
        XCTAssertEqual(controller.openFailureObserverCount, 0)
        let expected = OpenFailureMessage.text(for: failure, bookName: url.lastPathComponent, automaticRetryArmed: false)
        XCTAssertTrue(controller.openFailurePresentation.text.hasPrefix(expected))
        await gate.release()
    }

    func testManualRetryShowsHUDImmediatelyAndWaitsForInjectedMinimumBeforeResult() async throws {
        for succeeds in [false, true] {
            let (controller, _, _) = try makeController()
            let readAgain = XCTestExpectation(description: "最低表示時間中に再読込を完了")
            let source = OpenFailureTestSource(url: url, error: makeFailure(),
                failuresRemaining: succeeds ? 1 : .max, secondEntry: readAgain)
            controller.openSourceFactory = { _ in source }
            await controller.openBook(at: url, allowCollectionDrill: false).value
            let previous = try XCTUnwrap(controller.failedOpen)
            let timer = XCTestExpectation(description: "最低表示時間を設定")
            let clock = AssemblyTestClock { duration in
                XCTAssertEqual(duration, .milliseconds(500))
                timer.fulfill()
            }
            controller.manualRetryMinimumDuration = .milliseconds(500)
            controller.manualRetryNow = { clock.now }
            controller.manualRetrySleep = { try await clock.sleep($0) }
            let retry = try XCTUnwrap(controller.retryFailedOpen())
            XCTAssertTrue(controller.openingProgressIsVisible)
            XCTAssertTrue(controller.openFailurePresentation.statusHidden)
            await fulfillment(of: [readAgain, timer], timeout: 2)
            clock.advance(.milliseconds(499))
            XCTAssertTrue(controller.book === previous.placeholder)
            XCTAssertTrue(controller.openingProgressIsVisible)
            XCTAssertFalse(controller.validateMenuItem(reloadMenuItem()))
            clock.advance(.milliseconds(1))
            await retry.value
            XCTAssertFalse(controller.openingProgressIsVisible)
            XCTAssertFalse(controller.book === previous.placeholder)
            if succeeds { XCTAssertNil(controller.failedOpen) }
            else { XCTAssertFalse(controller.openFailurePresentation.buttonsHidden) }
        }
    }

    func testManualRetryCountsReadingTimeTowardMinimumHUDDuration() async throws {
        let (controller, _, _) = try makeController()
        let reading = XCTestExpectation(description: "再読込中に最低表示時間を経過")
        let gate = OpenFailureTestGate()
        let source = OpenFailureTestSource(url: url, error: makeFailure(), failuresRemaining: 1,
            secondEntry: reading, retryGate: gate)
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        let clock = AssemblyTestClock { _ in }
        controller.manualRetryMinimumDuration = .milliseconds(500)
        controller.manualRetryNow = { clock.now }
        controller.manualRetrySleep = { _ in XCTFail("読み込み中に経過した表示時間を重ねて待たない") }
        let retry = try XCTUnwrap(controller.retryFailedOpen())
        await fulfillment(of: [reading], timeout: 2)
        clock.advance(.milliseconds(500))
        await gate.release()
        await retry.value
        XCTAssertEqual(controller.book?.pageCount, 4)
        XCTAssertFalse(controller.openingProgressIsVisible)
    }

    func testFailureTextHugsItsWidthAndAlignsReloadWhileOrdinaryMessagesStayCentered() async throws {
        let (controller, _, _) = try makeController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        controller.setUpContentViews(in: window)
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        func assertLayout(hasBullets: Bool, checksButtons: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
            content.layoutSubtreeIfNeeded()
            let layout = controller.bookStatusLayout
            let widthCap = min(640, content.bounds.width - 80)
            XCTAssertEqual(layout.alignment, hasBullets ? .left : .center, file: file, line: line)
            XCTAssertGreaterThan(layout.label.width, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(layout.label.width, widthCap, file: file, line: line)
            XCTAssertEqual(layout.label.width, min(widthCap, layout.fittingWidth), accuracy: 2, file: file, line: line)
            XCTAssertEqual(layout.label.midX, content.bounds.midX, accuracy: 1, file: file, line: line)
            if checksButtons {
                if hasBullets {
                    XCTAssertEqual(layout.buttons.minX, layout.label.minX, accuracy: 1, file: file, line: line)
                } else {
                    XCTAssertEqual(layout.buttons.midX, content.bounds.midX, accuracy: 1, file: file, line: line)
                }
            }
        }
        await controller.debugShowOpenFailure()
        assertLayout(hasBullets: true)
        await controller.debugShowOpenFailure(volumeUnavailable: true)
        assertLayout(hasBullets: false)
        let unlisted = AssemblyFailure(failures: [], total: 2, unchecked: 2, sourceURL: url)
        let source = OpenFailureTestSource(url: url, error: unlisted)
        controller.openSourceFactory = { _ in source }
        await controller.openBook(at: url).value
        XCTAssertFalse(controller.openFailurePresentation.buttonsHidden)
        assertLayout(hasBullets: false)
        // 同じ窓で表示が切り替わっても、二つの配置制約を同時に有効にしない(設計書 §7.4)。
        await controller.debugShowOpenFailure()
        assertLayout(hasBullets: true)
        controller.debugShowOpeningProgress(retrying: true)
        XCTAssertTrue(controller.openingProgressIsVisible)
        controller.endOpeningProgress(generation: -1)
        controller.replaceBook(Book(source: source, prepared: .empty(for: url)))
        controller.showBookStatusMessage(String(localized: "Password entry was canceled."))
        assertLayout(hasBullets: false, checksButtons: false)
        XCTAssertTrue(controller.openFailurePresentation.buttonsHidden)
    }

    private func makeController() throws -> (ReaderWindowController, BookHistoryStore, URL) {
        let root = try TestFixtures.makeTempDir()
        let suite = "test.cooViewer.open-failure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = root.appendingPathComponent("states")
        let store = BookHistoryStore(defaults: defaults, directory: directory)
        let controller = ReaderWindowController(window: nil, history: store)
        controller.fileSystemProbe = OpenFailureTestProbe(exists: true)
        controller.workspaceNotificationCenter = NotificationCenter()
        controller.manualRetryMinimumDuration = .zero
        let clock = AssemblyTestClock { _ in }
        controller.openReachabilityPolicy.sleep = { try await clock.sleep($0) }
        controller.openReachabilityPolicy.reachabilityProbe = { _ in true }
        // 実設定を保存せず、描画とプローブの待機を検証から除く(設計書 §7.4)。
        let shared = UserDefaults.standard
        let previous = shared.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["AdaptiveMediaTuning"] = false
        arguments["ReadMode"] = ReadMode.leftToRightSingle.rawValue
        arguments["Interpolation"] = 1
        arguments["NoiseReductionLevel"] = 0
        shared.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        addTeardownBlock { @MainActor in
            controller.replaceBook(nil)
            shared.setVolatileDomain(previous, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: root)
        }
        return (controller, store, directory)
    }

    private func files(in directory: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}

private struct OpenFailureTestProbe: FileSystemProbing {
    let exists: Bool
    var isDirectory = true
    func directoryItems(at directory: URL) async throws -> [DirectoryItem] { [] }
    func fileExists(atPath path: String) async -> Bool { exists }
    func itemKind(at url: URL) async -> (exists: Bool, isDirectory: Bool) { (exists, isDirectory) }
    func identity(at url: URL) async -> BookFileIdentity { .init() }
}

private actor OpenFailureTestGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor OpenFailureMountProbe {
    let checking: XCTestExpectation
    let gate: OpenFailureTestGate
    private(set) var calls = 0
    init(checking: XCTestExpectation, gate: OpenFailureTestGate) { self.checking = checking; self.gate = gate }
    func exists() async -> Bool {
        calls += 1
        if calls == 1 { checking.fulfill(); await gate.wait(); return false }
        return true
    }
}

private actor OpenFailureTestSource: BookSource {
    nonisolated let url: URL
    nonisolated let supportsDateSort = false
    private let error: any Error
    private let retryError: (any Error)?
    private let retryGate: OpenFailureTestGate?
    private let pageNames: [String]
    private var failuresRemaining: Int
    private let started: XCTestExpectation?
    private let secondEntry: XCTestExpectation?
    private let reportsEncryptionAfterFirstRead: Bool
    private let gate: OpenFailureTestGate?
    private let beforeEntries: (@Sendable () async -> Void)?
    private(set) var entryCalls = 0

    init(url: URL, error: any Error, failuresRemaining: Int = .max,
         started: XCTestExpectation? = nil, gate: OpenFailureTestGate? = nil,
         secondEntry: XCTestExpectation? = nil, reportsEncryptionAfterFirstRead: Bool = false,
         retryError: (any Error)? = nil, retryGate: OpenFailureTestGate? = nil,
         pageNames: [String] = ["0.png", "1.png", "2.png", "3.png"],
         beforeEntries: (@Sendable () async -> Void)? = nil) {
        self.url = url
        self.error = error
        self.retryError = retryError
        self.retryGate = retryGate
        self.pageNames = pageNames
        self.failuresRemaining = failuresRemaining
        self.started = started
        self.secondEntry = secondEntry
        self.reportsEncryptionAfterFirstRead = reportsEncryptionAfterFirstRead
        self.gate = gate
        self.beforeEntries = beforeEntries
    }

    func entries() async throws -> [PageEntry] {
        entryCalls += 1
        await beforeEntries?()
        if entryCalls == 1 { started?.fulfill(); await gate?.wait() }
        if entryCalls == 2 { secondEntry?.fulfill(); await retryGate?.wait() }
        if entryCalls > 1, let retryError { throw retryError }
        if failuresRemaining > 0 { failuresRemaining -= 1; throw error }
        return pageNames.enumerated().map { .init(id: $0.offset, name: $0.element, pathInBook: $0.element,
            fileURL: nil, creationDate: nil, modificationDate: nil) }
    }

    func imageSize(for entry: PageEntry) async -> CGSize? { CGSize(width: 2, height: 3) }
    func isEncrypted() async -> Bool { reportsEncryptionAfterFirstRead && entryCalls > 0 }
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage {
        let context = CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return try XCTUnwrap(context?.makeImage())
    }
}

private actor OpenFailurePasswordSource: BookSource {
    nonisolated let url = URL(fileURLWithPath: "/synthetic/secret.zip")
    nonisolated let supportsDateSort = false
    func entries() async throws -> [PageEntry] { [] }
    func isEncrypted() async -> Bool { true }
    func checkAndSetPassword(_ password: String) async -> PasswordCheck { password == "pw" ? .accepted : .rejected }
    func image(for entry: PageEntry, maxPixelSize: Int?) async throws -> CGImage { throw CancellationError() }
}
