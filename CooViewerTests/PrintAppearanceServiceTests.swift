import Dispatch
import Foundation
import os
import XCTest
@testable import cooViewer
@testable import PrintAppearanceKit

/// 網点処理のサービスの順序・間引き・追い越し・取り消し・辞退・解放の検査(設計書 §5)。
/// エンジンは偽物(FakePrintAppearanceEngine)で、目印のページを処理した順を記録する。
/// 待ちの登録は統計を条件にして待ち、エンジンの進み具合はセマフォで止めて進める(時間で同期しない)
final class PrintAppearanceServiceTests: XCTestCase {

    // MARK: - 順序

    /// 表示の仕事を新しい順に、次に先読みの仕事を到着順に処理する
    func testDisplayBeforePrefetchNewestDisplayFirst() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let blocker = engine.hold(1, at: 0)
        var tasks = [Self.submit(service, 1)]
        try await Self.reach(blocker)
        tasks.append(Self.submit(service, 10, ticket: book.ticket(prefetch: true)))
        try await Self.waitUntil(service) { $0.waitingPrefetch == 1 }
        tasks.append(Self.submit(service, 11, ticket: book.ticket(prefetch: true)))
        try await Self.waitUntil(service) { $0.waitingPrefetch == 2 }
        tasks.append(Self.submit(service, 20, ticket: book.ticket(prefetch: false)))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        tasks.append(Self.submit(service, 21, ticket: book.ticket(prefetch: false)))
        try await Self.waitUntil(service) { $0.waitingDisplay == 2 }
        blocker.proceed.signal()
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(engine.markers, [1, 21, 20, 10, 11])
        // 表示の仕事は先に積まれた先読みの枠が拾っても表示の QoS で、先読みの仕事は先読みの QoS で処理する
        XCTAssertEqual(engine.calls.map(\.qos.rawValue),
                       [QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INITIATED,
                        QOS_CLASS_UTILITY, QOS_CLASS_UTILITY].map(\.rawValue))
        let stats = service.stats()
        XCTAssertEqual(stats.processedPages, 5)
        XCTAssertEqual(stats.waitingDisplay + stats.waitingPrefetch, 0)
        XCTAssertFalse(stats.isRunning)
    }

    /// touch は表示の仕事を最新へ動かし、先読みの仕事を表示の仕事に上げる
    func testTouchMovesDisplayJobAndPromotesPrefetchJob() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let blocker = engine.hold(1, at: 0)
        var tasks = [Self.submit(service, 1)]
        try await Self.reach(blocker)
        let p1 = book.ticket(prefetch: true)
        tasks.append(Self.submit(service, 10, ticket: p1))
        try await Self.waitUntil(service) { $0.waitingPrefetch == 1 }
        tasks.append(Self.submit(service, 11, ticket: book.ticket(prefetch: true)))
        try await Self.waitUntil(service) { $0.waitingPrefetch == 2 }
        let d1 = book.ticket(prefetch: false)
        tasks.append(Self.submit(service, 20, ticket: d1))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        tasks.append(Self.submit(service, 21, ticket: book.ticket(prefetch: false)))
        try await Self.waitUntil(service) { $0.waitingDisplay == 2 }
        p1.touch()
        XCTAssertEqual(p1.intent, .display)
        try await Self.waitUntil(service) { $0.waitingDisplay == 3 && $0.waitingPrefetch == 1 }
        d1.touch()
        blocker.proceed.signal()
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(engine.markers, [1, 20, 10, 21, 11])
        XCTAssertEqual(service.stats().promotions, 1)
        // 先読みのまま始まった仕事は先読みの並列数、表示に上げた仕事は表示の並列数で処理する
        XCTAssertEqual(engine.calls.first { $0.marker == 10 }?.threads, Self.configuration.displayThreads)
        XCTAssertEqual(engine.calls.first { $0.marker == 11 }?.threads, Self.configuration.prefetchThreads)
    }

    /// 券への touch・decline が仕事の届く前に来ても、届いたときに反映する
    func testTicketIntentBeforeSubmissionIsApplied() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let blocker = engine.hold(1, at: 0)
        var tasks = [Self.submit(service, 1)]
        try await Self.reach(blocker)
        tasks.append(Self.submit(service, 10, ticket: book.ticket(prefetch: true)))
        try await Self.waitUntil(service) { $0.waitingPrefetch == 1 }
        let promoted = book.ticket(prefetch: true)
        promoted.touch()
        tasks.append(Self.submit(service, 11, ticket: promoted))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        let declined = book.ticket(prefetch: true)
        declined.decline()
        XCTAssertEqual(declined.intent, .declined)
        let declinedTask = Self.submit(service, 12, ticket: declined)
        await Self.assertThrows(declinedTask, PrefetchDecodeGate.Declined.self)
        blocker.proceed.signal()
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(engine.markers, [1, 11, 10])
        XCTAssertEqual(service.stats().declinedJobs, 1)
    }

    // MARK: - 間引き

    /// 本ごとに待てる表示の仕事は 4 つまで。5 つ目で最も古く触れたものを Superseded で終える。
    /// 別の本の仕事は間引かず、券のない仕事(ルーペ)は数えず間引かない
    func testShedsOldestDisplayJobPerBookOnly() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let bookA = BookToken(), bookB = BookToken()
        let blocker = engine.hold(1, at: 0)
        let first = Self.submit(service, 1)
        try await Self.reach(blocker)
        var bookATasks: [Task<PrintAppearanceGray, any Error>] = []
        for i in 0..<5 {
            bookATasks.append(Self.submit(service, UInt8(30 + i), ticket: bookA.ticket(prefetch: false)))
            try await Self.waitUntil(service) { $0.waitingDisplay == min(i + 1, 4) && $0.shedJobs == max(0, i - 3) }
        }
        await Self.assertThrows(bookATasks[0], PrintAppearanceService.Superseded.self)
        var others: [Task<PrintAppearanceGray, any Error>] = []
        for i in 0..<4 {
            others.append(Self.submit(service, UInt8(40 + i), ticket: bookB.ticket(prefetch: false)))
            try await Self.waitUntil(service) { $0.waitingDisplay == 5 + i }
        }
        for i in 0..<5 {
            others.append(Self.submit(service, UInt8(50 + i)))
            try await Self.waitUntil(service) { $0.waitingDisplay == 9 + i }
        }
        XCTAssertEqual(service.stats().shedJobs, 1)
        blocker.proceed.signal()
        _ = try await first.value
        for task in bookATasks.dropFirst() + others { _ = try await task.value }
        XCTAssertFalse(engine.markers.contains(30), "間引いた仕事は処理しない")
        XCTAssertEqual(engine.markers.count, 1 + 4 + 4 + 5)
    }

    /// 先読みを表示へ上げて本の待ちが 5 つになったときも、最も古く触れたものを間引く
    func testPromotionCanShedOldestDisplayJob() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let blocker = engine.hold(1, at: 0)
        let first = Self.submit(service, 1)
        try await Self.reach(blocker)
        var displays: [Task<PrintAppearanceGray, any Error>] = []
        for i in 0..<4 {
            displays.append(Self.submit(service, UInt8(30 + i), ticket: book.ticket(prefetch: false)))
            try await Self.waitUntil(service) { $0.waitingDisplay == i + 1 }
        }
        let prefetch = book.ticket(prefetch: true)
        let promoted = Self.submit(service, 40, ticket: prefetch)
        try await Self.waitUntil(service) { $0.waitingPrefetch == 1 }
        prefetch.touch()
        try await Self.waitUntil(service) { $0.shedJobs == 1 }
        await Self.assertThrows(displays[0], PrintAppearanceService.Superseded.self)
        blocker.proceed.signal()
        _ = try await first.value
        _ = try await promoted.value
        for task in displays.dropFirst() { _ = try await task.value }
        XCTAssertEqual(engine.markers, [1, 40, 33, 32, 31])
    }

    // MARK: - 辞退

    /// decline は待っている先読みの仕事だけを Declined で終える。表示の券では何もせず、
    /// 実行中の先読みは最後まで処理する
    func testDeclineEndsOnlyWaitingPrefetchJobs() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let running = book.ticket(prefetch: true)
        let hold = engine.hold(10, at: 5)
        let runningTask = Self.submit(service, 10, ticket: running)
        try await Self.reach(hold)
        let waiting = book.ticket(prefetch: true)
        let waitingTask = Self.submit(service, 11, ticket: waiting)
        let display = book.ticket(prefetch: false)
        let displayTask = Self.submit(service, 20, ticket: display)
        try await Self.waitUntil(service) { $0.waitingPrefetch == 1 && $0.waitingDisplay == 1 }
        running.decline()
        waiting.decline()
        display.decline()
        XCTAssertEqual(display.intent, .display)
        await Self.assertThrows(waitingTask, PrefetchDecodeGate.Declined.self)
        hold.proceed.signal()
        _ = try await runningTask.value
        _ = try await displayTask.value
        XCTAssertEqual(engine.markers, [10, 20])
        XCTAssertEqual(service.stats().declinedJobs, 1)
    }

    /// 実行中に辞退された先読みは最後まで処理するが、追い越しで止めたらそこで辞退で終える(待ちに戻さない)
    func testDeclinedRunningPrefetchEndsWhenPreempted() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let ticket = book.ticket(prefetch: true)
        let hold = engine.hold(10, at: 1)
        let declined = Self.submit(service, 10, ticket: ticket)
        try await Self.reach(hold)
        ticket.decline()
        let display = Self.submit(service, 20, ticket: book.ticket(prefetch: false))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        hold.proceed.signal()
        await Self.assertThrows(declined, PrefetchDecodeGate.Declined.self)
        _ = try await display.value
        XCTAssertEqual(engine.markers, [10, 20])
        XCTAssertEqual(engine.calls[0].stoppedAt, .betweenPass1Chunks)
        let stats = service.stats()
        XCTAssertEqual(stats.declinedJobs, 1)
        XCTAssertEqual(stats.preemptions, 1)
        XCTAssertEqual(stats.waitingPrefetch, 0)
    }

    // MARK: - 作業域の予約

    /// 予約はページの仕事より先にエンジンのキューで作業域を用意し、予約が積まれている間は大きなページの後でも
    /// 作業域を手放さない。予約の後に仕事がなければ解放の予約を立てる
    func testReservationRunsBeforePageAndHoldsLargePageRelease() async throws {
        let engine = FakePrintAppearanceEngine()
        let scheduler = ManualDelayScheduler()
        var configuration = Self.configuration
        configuration.largePagePixels = 100 * 100
        let service = Self.service(engine, configuration: configuration, scheduler: scheduler)
        // 仕事のない予約: 予約の後に解放の予約を立てる
        service.reserve(width: 3000, height: 4000, colourPossible: false)
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["reserve(3000x4000,6)"])
        XCTAssertEqual(scheduler.live.count, 1, "ページが来なくても解放の予約を立てる")
        XCTAssertEqual(service.stats().reservations, 1)
        // 大きなページの処理中に予約が積まれたら、そのページの後で手放さない
        let hold = engine.hold(6, at: 0)
        let large = Task.detached {
            try await service.process(FakePrintAppearanceEngine.page(6, width: 128, height: 128),
                                      request: PrintAppearanceRequest(level: .standard))
        }
        try await Self.reach(hold)
        service.reserve(width: 128, height: 128, colourPossible: false)
        hold.proceed.signal()
        _ = try await large.value
        await service.flushForTesting()
        XCTAssertEqual(engine.events.suffix(2), ["process(6)", "reserve(128x128,6)"], "予約があるので手放さない")
        // 予約が終わって待ちがなければ、次の大きなページの後で手放す
        _ = try await service.process(FakePrintAppearanceEngine.page(7, width: 128, height: 128),
                                      request: PrintAppearanceRequest(level: .standard))
        await service.flushForTesting()
        XCTAssertEqual(engine.events.suffix(2), ["process(7)", "release(true)"])
    }

    /// 色のページになりうるページは、このプロセスでまだ 1 ページも処理していなければ予約しない。
    /// メモリ圧迫が critical なら予約しない
    func testReservationSkipsPossibleColourBeforeFirstPageAndUnderCriticalPressure() async throws {
        let engine = FakePrintAppearanceEngine()
        let center = NotificationCenter()
        let pressure = MutablePressure()
        let service = Self.service(engine, pressure: pressure, center: center)
        service.reserve(width: 2000, height: 3000, colourPossible: true)
        await service.flushForTesting()
        XCTAssertEqual(engine.events, [])
        _ = try await Self.submit(service, 5).value
        service.reserve(width: 2000, height: 3000, colourPossible: true)
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["process(5)", "reserve(2000x3000,6)"])
        pressure.set(.critical, center: center)
        await service.flushForTesting()
        let before = engine.events.count
        service.reserve(width: 2000, height: 3000, colourPossible: false)
        await service.flushForTesting()
        XCTAssertFalse(engine.events.dropFirst(before).contains { $0.hasPrefix("reserve") })
        XCTAssertEqual(service.stats().reservations, 1)
    }

    // MARK: - 追い越し

    /// 表示の仕事が来たら、パス 1 の途中の先読みのページを次のチャンクの境目で止めて表示を先に処理し、
    /// 止めたページは先読みの先頭へ戻す(後から来た先読みより先)
    func testDisplayPreemptsPrefetchInPass1AndRequeuesAtHead() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let hold = engine.hold(10, at: 2)
        let preempted = Self.submit(service, 10, ticket: book.ticket(prefetch: true))
        try await Self.reach(hold)
        let later = Self.submit(service, 11, ticket: book.ticket(prefetch: true))
        try await Self.waitUntil(service) { $0.waitingPrefetch == 1 }
        let display = Self.submit(service, 20, ticket: book.ticket(prefetch: false))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        hold.proceed.signal()
        for task in [preempted, later, display] { _ = try await task.value }
        XCTAssertEqual(engine.markers, [10, 20, 10, 11])
        // 先読みの枠が拾った表示の仕事も表示の QoS で処理し、表示の枠は先読みの仕事を処理しない
        XCTAssertEqual(engine.calls.map(\.qos.rawValue),
                       [QOS_CLASS_UTILITY, QOS_CLASS_USER_INITIATED, QOS_CLASS_UTILITY, QOS_CLASS_UTILITY].map(\.rawValue))
        XCTAssertEqual(engine.calls[0].stoppedAt, .betweenPass1Chunks)
        XCTAssertNil(engine.calls[2].stoppedAt)
        XCTAssertEqual(service.stats().preemptions, 1)
        XCTAssertEqual(service.stats().processedPages, 3)
    }

    /// パス 1 を過ぎた先読みのページは最後まで処理する。表示へ上げた実行中の仕事も止めない
    func testPrefetchPastPass1OrPromotedIsNotPreempted() async throws {
        for promote in [false, true] {
            let engine = FakePrintAppearanceEngine()
            let service = Self.service(engine)
            let book = BookToken()
            let ticket = book.ticket(prefetch: true)
            let hold = engine.hold(10, at: promote ? 1 : 5)
            let running = Self.submit(service, 10, ticket: ticket)
            try await Self.reach(hold)
            if promote { ticket.touch() }
            let display = Self.submit(service, 20, ticket: book.ticket(prefetch: false))
            try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
            hold.proceed.signal()
            _ = try await running.value
            _ = try await display.value
            XCTAssertEqual(engine.markers, [10, 20], "promote: \(promote)")
            XCTAssertEqual(engine.calls.compactMap(\.stoppedAt), [])
            XCTAssertEqual(service.stats().preemptions, 0)
        }
    }

    /// 表示の仕事は追い越されない(新しい表示が来ても実行中の表示は最後まで処理する)
    func testDisplayJobIsNotPreempted() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let hold = engine.hold(20, at: 1)
        let running = Self.submit(service, 20, ticket: book.ticket(prefetch: false))
        try await Self.reach(hold)
        let next = Self.submit(service, 21, ticket: book.ticket(prefetch: false))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        hold.proceed.signal()
        _ = try await running.value
        _ = try await next.value
        XCTAssertEqual(engine.markers, [20, 21])
        XCTAssertEqual(engine.calls.compactMap(\.stoppedAt), [])
    }

    // MARK: - 取り消し

    /// 待っている仕事の取り消しは外すだけ、実行中の仕事は次の停止位置で止める。どちらも CancellationError。
    /// 止めた後も同じエンジンで次のページを処理できる
    func testCancellationOfWaitingAndRunningJobs() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let book = BookToken()
        let hold = engine.hold(10, at: 6)
        let running = Self.submit(service, 10, ticket: book.ticket(prefetch: false))
        try await Self.reach(hold)
        let waiting = Self.submit(service, 11, ticket: book.ticket(prefetch: true))
        try await Self.waitUntil(service) { $0.waitingPrefetch == 1 }
        waiting.cancel()
        await Self.assertThrows(waiting, CancellationError.self)
        XCTAssertEqual(service.stats().waitingPrefetch, 0)
        running.cancel()
        hold.proceed.signal()
        await Self.assertThrows(running, CancellationError.self)
        _ = try await Self.submit(service, 12, ticket: book.ticket(prefetch: false)).value
        XCTAssertEqual(engine.markers, [10, 12])
        XCTAssertEqual(engine.calls[0].stoppedAt, .betweenFillRounds)
        XCTAssertEqual(service.stats().cancelledJobs, 2)
        XCTAssertEqual(service.stats().preemptions, 0)
    }

    /// 既に取り消されたタスクの要求は仕事を作らない
    func testAlreadyCancelledCallerCreatesNoJob() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        let page = FakePrintAppearanceEngine.page(5)
        let task = Task.detached { () async throws -> PrintAppearanceGray in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.process(page, request: PrintAppearanceRequest(level: .standard))
        }
        await Self.assertThrows(task, CancellationError.self)
        await service.flushForTesting()
        XCTAssertEqual(engine.markers, [])
    }

    // MARK: - 失敗

    /// エンジンの失敗はそのまま投げる(生の画素は返さない)。CPU の経路でも断られたページは断りとして数える
    func testEngineErrorsAreThrownAndCounted() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        engine.fail(with: .gpuFailed("試験用の失敗"))
        do {
            _ = try await Self.submit(service, 5).value
            XCTFail("失敗のはずのページが返った")
        } catch let error as PrintAppearanceError {
            XCTAssertEqual(error, .gpuFailed("試験用の失敗"))
        }
        engine.fail(with: .unsupportedPage("試験用の断り"))
        do {
            _ = try await Self.submit(service, 6).value
            XCTFail("断られたはずのページが返った")
        } catch let error as PrintAppearanceError {
            XCTAssertEqual(error, .unsupportedPage("試験用の断り"))
        }
        let stats = service.stats()
        XCTAssertEqual(stats.failedPages, 1)
        XCTAssertEqual(stats.refusedPages, 1)
        XCTAssertEqual(stats.processedPages, 0)
    }

    /// 実際のエンジンで GPU の失敗を起こすと、サービスは CPU の厳密な経路の結果を返す(未処理の画素ではない)
    func testInjectedGPUFailureGivesCPUResult() async throws {
        guard Self.gpuPathAvailable else { throw XCTSkip("GPU の経路を用意できない環境") }
        let width = 512, height = 2048
        let luma = PrintAppearanceTestPages.mix(width: width, height: height)
        let page = try PrintAppearancePage(luma: luma, width: width, height: height)
        let cpu = Self.bytes(try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: .standard, threads: 4))
        XCTAssertNotEqual(cpu, luma)
        let service = PrintAppearanceService(
            configuration: Self.configuration,
            makeEngine: {
                let engine = PrintAppearanceEngine(mode: .automatic)
                engine.gpuFaultForTesting = { $0 == .afterPass1 ? .gpuFailed("試験用の失敗") : nil }
                return engine
            },
            power: FixedPowerState(), pressure: FixedMemoryPressure(), center: NotificationCenter(),
            scheduler: ManualDelayScheduler().scheduler)
        let gray = try await service.process(page, request: PrintAppearanceRequest(level: .standard))
        XCTAssertEqual(Self.bytes(gray), cpu)
        let stats = service.stats()
        XCTAssertEqual(stats.processedPages, 1)
        XCTAssertEqual(stats.engine?.gpuFallbackPages, 1)
        service.releaseAll()
        await service.flushForTesting()
    }

    // MARK: - 並列数とキュー

    /// 表示は表示の並列数、先読みは先読みの並列数、省エネ中の先読みは 2。
    /// 既定は表示が全てのコア(16 まで)、先読みが min(8, 高性能コアの数)
    func testThreadBudgets() async throws {
        for conserving in [false, true] {
            let engine = FakePrintAppearanceEngine()
            let service = Self.service(engine, power: FixedPowerState(isLowPowerModeEnabled: conserving))
            let book = BookToken()
            _ = try await Self.submit(service, 1, ticket: book.ticket(prefetch: false)).value
            _ = try await Self.submit(service, 2, ticket: book.ticket(prefetch: true)).value
            _ = try await Self.submit(service, 3).value
            XCTAssertEqual(engine.calls.map(\.threads),
                           [Self.configuration.displayThreads, conserving ? 2 : 4, Self.configuration.displayThreads],
                           "conserving: \(conserving)")
        }
        let defaults = PrintAppearanceService.Configuration()
        XCTAssertEqual(defaults.displayThreads, min(16, ProcessInfo.processInfo.activeProcessorCount))
        XCTAssertEqual(defaults.prefetchThreads, min(8, PrintAppearanceService.performanceCoreCount()))
        XCTAssertGreaterThanOrEqual(defaults.displayThreads, defaults.prefetchThreads)
        XCTAssertEqual(defaults.conservingPrefetchThreads, 2)
        XCTAssertEqual(defaults.displayWaitLimit, 4)
        XCTAssertEqual(defaults.maxPixels, PrintAppearance.defaultMaxPixels)
    }

    /// エンジンはサービスの直列キューの上だけで動き、メインスレッドでは動かない。段階はそのまま渡す
    func testEngineRunsOnlyOnServiceQueue() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        service.prepareIfNeeded()
        for level in PrintAppearanceLevel.allCases {
            _ = try await service.process(FakePrintAppearanceEngine.page(7),
                                          request: PrintAppearanceRequest(level: level))
        }
        service.releaseAll()
        await service.flushForTesting()
        XCTAssertEqual(engine.queueLabels, [service.queueLabelForTesting])
        XCTAssertFalse(engine.calledOnMainThread)
        XCTAssertEqual(engine.calls.map(\.level), PrintAppearanceLevel.allCases)
    }

    // MARK: - 準備

    /// 準備は 1 度だけ積み、その間に来たページは後ろに並ぶ。省エネ中は合成ページを処理しない。
    /// releaseAll の後は改めて準備する。準備より先にページを処理したら準備を積まない
    func testPrepareIfNeededIsSingleFlight() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        service.prepareIfNeeded()
        service.prepareIfNeeded()
        _ = try await Self.submit(service, 5).value
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["warmUp(true)", "process(5)"])
        service.prepareIfNeeded()
        service.releaseAll()
        await service.flushForTesting()
        service.prepareIfNeeded()
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["warmUp(true)", "process(5)", "release(false)", "warmUp(true)"])
        XCTAssertNotNil(service.stats().lastWarmUpMilliseconds)

        let conservingEngine = FakePrintAppearanceEngine()
        let conserving = Self.service(conservingEngine, power: FixedPowerState(isLowPowerModeEnabled: true))
        conserving.prepareIfNeeded()
        await conserving.flushForTesting()
        XCTAssertEqual(conservingEngine.events, ["warmUp(false)"])

        let lazyEngine = FakePrintAppearanceEngine()
        let lazy = Self.service(lazyEngine)
        _ = try await Self.submit(lazy, 6).value
        lazy.prepareIfNeeded()
        await lazy.flushForTesting()
        XCTAssertEqual(lazyEngine.events, ["process(6)"])
    }

    /// 切ってすぐ入れ直したら(releaseAll の直後に prepareIfNeeded)、後からキューで走る解放は何もせず、
    /// 準備を積み直す。releaseAll だけなら解放する。準備の最中に切られたら、準備の後に解放し、
    /// 次の prepareIfNeeded は準備を積み直す(設計書 §5)
    func testPrepareRightAfterReleaseKeepsPipelines() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        _ = try await Self.submit(service, 5).value
        await service.flushForTesting()
        service.releaseAll()
        service.prepareIfNeeded()
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["process(5)", "warmUp(true)"])
        XCTAssertEqual(service.stats().storeReleases, 0)

        service.releaseAll()
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["process(5)", "warmUp(true)", "release(false)"])
        XCTAssertEqual(service.stats().storeReleases, 1)

        let hold = engine.hold(9, at: 0)
        let running = Self.submit(service, 9)
        try await Self.reach(hold)
        service.prepareIfNeeded()
        service.releaseAll()
        hold.proceed.signal()
        _ = try await running.value
        await service.flushForTesting()
        XCTAssertEqual(Array(engine.events.suffix(2)), ["process(9)", "release(false)"],
                       "ページの最中の prepare は準備を積み、その後の releaseAll が取り消す")
        service.prepareIfNeeded()
        await service.flushForTesting()
        XCTAssertEqual(engine.events.last, "warmUp(true)", "解放した後は準備を積み直す")
    }

    /// 稼働状況の時間: 待ちとエンジンは処理したページごとに、prepare と全体はデコードの入口が知らせた分だけ。
    /// 中央値は直近 timingWindow 件(偶数件は中央の 2 つの平均)
    func testTimingMediansCoverRecentPages() async throws {
        let engine = FakePrintAppearanceEngine()
        let service = Self.service(engine)
        XCTAssertNil(service.stats().medianEngineMilliseconds)
        for marker in UInt8(1)...3 { _ = try await Self.submit(service, marker).value }
        let stats = service.stats()
        XCTAssertNotNil(stats.medianWaitMilliseconds)
        XCTAssertNotNil(stats.medianEngineMilliseconds)
        XCTAssertNil(stats.medianPrepareMilliseconds)

        for value in [40, 10, 30, 20] { service.recordProcessedPage(prepare: .milliseconds(value),
                                                                     total: .milliseconds(value * 10)) }
        var recorded = service.stats()
        XCTAssertEqual(recorded.lastPrepareMilliseconds, 20)
        XCTAssertEqual(recorded.medianPrepareMilliseconds, 25)
        XCTAssertEqual(recorded.lastPageMilliseconds, 200)
        XCTAssertEqual(recorded.medianPageMilliseconds, 250)
        // 古いものから捨てる: 1000 を timingWindow 件足すと中央値は 1000
        for _ in 0..<PrintAppearanceService.timingWindow {
            service.recordProcessedPage(prepare: .milliseconds(1000), total: .milliseconds(1000))
        }
        recorded = service.stats()
        XCTAssertEqual(recorded.medianPrepareMilliseconds, 1000)
        XCTAssertEqual(recorded.medianPageMilliseconds, 1000)
    }

    // MARK: - 作業域の解放

    /// 仕事がなくなって 20 秒(省エネ中は 5 秒)で作業域を手放す。パイプラインは残す。
    /// 予約の後に仕事が来たら古い予約は何もしない
    func testIdleReleaseAfterIntervalAndStaleReservationIsIgnored() async throws {
        for conserving in [false, true] {
            let engine = FakePrintAppearanceEngine()
            let scheduler = ManualDelayScheduler()
            let service = Self.service(engine, power: FixedPowerState(isLowPowerModeEnabled: conserving),
                                       scheduler: scheduler)
            _ = try await Self.submit(service, 5).value
            await service.flushForTesting()
            XCTAssertEqual(scheduler.live.map(\.delay), [conserving ? .seconds(5) : .seconds(20)])
            _ = try await Self.submit(service, 6).value
            await service.flushForTesting()
            XCTAssertEqual(scheduler.live.count, 1, "前の予約は取り消す")
            XCTAssertEqual(scheduler.recorded.count, 2)
            scheduler.fire()
            await service.flushForTesting()
            XCTAssertEqual(engine.events, ["process(5)", "process(6)", "release(true)"], "conserving: \(conserving)")
            XCTAssertEqual(service.stats().storeReleases, 1)
            // 解放した後は予約を立てない
            XCTAssertEqual(scheduler.live.count, 0)
        }
    }

    /// 400 万画素を超えるページの後、待ちがなければすぐ手放す(待ちがあれば手放さない)
    func testLargePageReleasesWhenNothingWaits() async throws {
        let engine = FakePrintAppearanceEngine()
        var configuration = Self.configuration
        configuration.largePagePixels = 100 * 100
        let service = Self.service(engine, configuration: configuration)
        _ = try await service.process(FakePrintAppearanceEngine.page(5, width: 64, height: 64),
                                      request: PrintAppearanceRequest(level: .standard))
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["process(5)"])
        let hold = engine.hold(6, at: 0)
        let large = Task.detached {
            try await service.process(FakePrintAppearanceEngine.page(6, width: 128, height: 128),
                                      request: PrintAppearanceRequest(level: .standard))
        }
        try await Self.reach(hold)
        let next = Self.submit(service, 7)
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        hold.proceed.signal()
        _ = try await large.value
        _ = try await next.value
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["process(5)", "process(6)", "process(7)", "release(true)"])
    }

    /// メモリ圧迫: warning では仕事がなくなったら(圧迫が来た時点で暇ならすぐ)、critical では毎ページの後に手放す
    func testMemoryPressureReleasesStores() async throws {
        let engine = FakePrintAppearanceEngine()
        let center = NotificationCenter()
        let pressure = MutablePressure()
        let service = Self.service(engine, pressure: pressure, center: center)
        _ = try await Self.submit(service, 5).value
        await service.flushForTesting()
        pressure.set(.warning, center: center)
        await service.flushForTesting()
        XCTAssertEqual(engine.events, ["process(5)", "release(true)"], "暇なら warning ですぐ手放す")

        // warning のまま: 待ちがある間は手放さず、最後のページの後で手放す
        var hold = engine.hold(6, at: 0)
        var tasks = [Self.submit(service, 6)]
        try await Self.reach(hold)
        tasks.append(Self.submit(service, 7))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        hold.proceed.signal()
        for task in tasks { _ = try await task.value }
        await service.flushForTesting()
        XCTAssertEqual(engine.events.suffix(3), ["process(6)", "process(7)", "release(true)"])

        // critical: 待ちがあっても毎ページの後
        hold = engine.hold(8, at: 0)
        tasks = [Self.submit(service, 8)]
        try await Self.reach(hold)
        tasks.append(Self.submit(service, 9))
        try await Self.waitUntil(service) { $0.waitingDisplay == 1 }
        pressure.set(.critical, center: center)
        hold.proceed.signal()
        for task in tasks { _ = try await task.value }
        await service.flushForTesting()
        XCTAssertEqual(engine.events.suffix(4), ["process(8)", "release(true)", "process(9)", "release(true)"])

        // normal に戻れば小さなページの後は手放さない
        pressure.set(.normal, center: center)
        _ = try await Self.submit(service, 10).value
        await service.flushForTesting()
        XCTAssertEqual(engine.events.last, "process(10)")
    }

    // MARK: - 補助

    /// 本の代わりの同一性
    private final class BookToken {
        func ticket(prefetch: Bool) -> PrintAppearanceTicket {
            PrintAppearanceTicket(book: ObjectIdentifier(self), isPrefetch: prefetch)
        }
    }

    /// 段階を手で変えられる圧迫の提供者。変えたら圧迫源と同じ通知を送る
    private final class MutablePressure: MemoryPressureProviding, Sendable {
        private let level = OSAllocatedUnfairLock(initialState: MemoryPressureLevel.normal)
        var memoryPressureLevel: MemoryPressureLevel { level.withLock { $0 } }

        func set(_ newLevel: MemoryPressureLevel, center: NotificationCenter) {
            level.withLock { $0 = newLevel }
            center.post(name: MemoryPressureMonitor.didChangeNotification, object: self)
        }
    }

    static let configuration: PrintAppearanceService.Configuration = {
        var configuration = PrintAppearanceService.Configuration()
        configuration.displayThreads = 6
        configuration.prefetchThreads = 4
        configuration.conservingPrefetchThreads = 2
        return configuration
    }()

    private static func service(_ engine: FakePrintAppearanceEngine,
                                configuration: PrintAppearanceService.Configuration
                                    = PrintAppearanceServiceTests.configuration,
                                power: any PowerStateProviding = FixedPowerState(),
                                pressure: any MemoryPressureProviding = FixedMemoryPressure(),
                                center: NotificationCenter = NotificationCenter(),
                                scheduler: ManualDelayScheduler = ManualDelayScheduler()) -> PrintAppearanceService {
        PrintAppearanceService(configuration: configuration, makeEngine: { engine }, power: power,
                               pressure: pressure, center: center, scheduler: scheduler.scheduler)
    }

    private static func submit(_ service: PrintAppearanceService, _ marker: UInt8,
                               ticket: PrintAppearanceTicket? = nil) -> Task<PrintAppearanceGray, any Error> {
        let page = FakePrintAppearanceEngine.page(marker)
        return Task.detached {
            try await service.process(page, request: PrintAppearanceRequest(level: .standard, ticket: ticket))
        }
    }

    /// エンジンが止まる位置に来るまで待つ。協調スレッドを塞がないよう別のスレッドで待ち、待つ側の QoS は
    /// エンジンのどの仕事よりも低くする(高い QoS で低い QoS の先読みを待つ優先度の逆転を作らない)
    private static func reach(_ hold: FakePrintAppearanceEngine.Hold,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async(qos: .utility, flags: .enforceQoS) {
                continuation.resume(returning: hold.reached.wait(timeout: .now() + 10) == .success)
            }
        }
        guard reached else {
            XCTFail("エンジンが止まる位置に来ない", file: file, line: line)
            throw CancellationError()
        }
    }

    /// サービスの写しが条件を満たすまで待つ(登録は呼び出し側のタスクで非同期に起きるため)
    private static func waitUntil(_ service: PrintAppearanceService,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ condition: (PrintAppearanceService.Stats) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(service.stats()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("条件を満たさない: \(service.stats())", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func assertThrows<E: Error>(_ task: Task<PrintAppearanceGray, any Error>, _ type: E.Type,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("\(type) のはずが値を返した", file: file, line: line)
        } catch {
            XCTAssertTrue(error is E, "\(error)", file: file, line: line)
        }
    }

    /// エンジンが GPU の経路を用意できるか
    private static let gpuPathAvailable: Bool = {
        let engine = PrintAppearanceEngine(mode: .automatic)
        guard (try? engine.warmUp(runDummyPage: false)) != nil else { return false }
        return engine.status.path == .gpu
    }()

    /// 行の詰め物を除いた W * H バイト
    static func bytes(_ gray: PrintAppearanceGray) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: gray.width * gray.height)
        gray.pixels.withUnsafeBytes { raw in
            out.withUnsafeMutableBytes { o in
                for y in 0..<gray.height {
                    memcpy(o.baseAddress! + y * gray.width, raw.baseAddress! + y * gray.bytesPerRow, gray.width)
                }
            }
        }
        return out
    }
}

/// 予約を記録するだけの予約器。テストが fire で満了を再現し、時計を待たない
final class ManualDelayScheduler: Sendable {
    struct Entry: Sendable {
        let delay: Duration
        let action: @Sendable () -> Void
        var cancelled = false
        var fired = false
        var isLive: Bool { !cancelled && !fired }
    }

    private let entries = OSAllocatedUnfairLock(initialState: [Entry]())

    var scheduler: DelayedScheduler {
        DelayedScheduler { [entries] delay, action in
            let index = entries.withLock { list in
                list.append(Entry(delay: delay, action: action))
                return list.count - 1
            }
            return { entries.withLock { $0[index].cancelled = true } }
        }
    }

    var recorded: [Entry] { entries.withLock { $0 } }
    var live: [Entry] { recorded.filter(\.isLive) }

    /// 取り消されても発火してもいない予約を満了させる
    func fire() {
        let actions = entries.withLock { list in
            let indices = list.indices.filter { list[$0].isLive }
            for index in indices { list[index].fired = true }
            return indices.map { list[$0].action }
        }
        for action in actions { action() }
    }
}
