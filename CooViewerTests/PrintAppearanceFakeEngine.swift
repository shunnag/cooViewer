import Dispatch
import Foundation
import os
@testable import cooViewer
@testable import PrintAppearanceKit

/// 網点処理のサービスのテスト用のエンジン(設計書 §5)。画素は処理せず、入力の輝度をそのまま返す。
/// ページは輝度の先頭の値(目印)で見分け、呼ばれた順・並列数・段階・止めた位置・実行したキューを記録する。
/// 停止位置は Kit と同じ順に問い合わせ(パス 1 のチャンクの境目は 3 つ)、shouldStop が真なら
/// Kit と同じく PrintAppearanceError.stopped を投げる。hold で指定した位置では、テストが進めるまで待つ
final class FakePrintAppearanceEngine: PrintAppearanceProcessing, @unchecked Sendable {
    struct Call: Equatable {
        let marker: UInt8
        let threads: Int
        let level: PrintAppearanceLevel
        /// 止めた位置。最後まで処理したら nil
        let stoppedAt: PrintAppearanceStopPoint?
        /// 処理したスレッドの QoS(concurrentPerform の作業者はこれを受け継ぐ)
        let qos: qos_class_t
    }

    /// 1 度だけ、指定のページの指定の位置で止まって待つ
    final class Hold: Sendable {
        let reached = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
    }

    /// 1 ページで問い合わせる停止位置の並び
    static let points: [PrintAppearanceStopPoint] = [
        .beforeRun, .betweenPass1Chunks, .betweenPass1Chunks, .betweenPass1Chunks,
        .afterPass1, .afterNeighbourGate, .betweenFillRounds, .beforeOutput,
    ]

    private struct State {
        var calls: [Call] = []
        /// 呼ばれた操作の順("warmUp(true)"・"process(5)"・"release(true)" など)
        var events: [String] = []
        var holds: [UInt8: (index: Int, hold: Hold)] = [:]
        var failure: PrintAppearanceError?
        var queueLabels: Set<String> = []
        var calledOnMainThread = false
        var workingBytes = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var calls: [Call] { state.withLockUnchecked { $0.calls } }
    var markers: [UInt8] { calls.map(\.marker) }
    var events: [String] { state.withLockUnchecked { $0.events } }
    var queueLabels: Set<String> { state.withLockUnchecked { $0.queueLabels } }
    var calledOnMainThread: Bool { state.withLockUnchecked { $0.calledOnMainThread } }

    /// 以後のページをすべてこの例外で終える(停止位置の問い合わせの後)
    func fail(with error: PrintAppearanceError?) {
        state.withLockUnchecked { $0.failure = error }
    }

    /// marker のページが points[index] に来たら、テストが proceed を送るまで待つ(1 度だけ)
    func hold(_ marker: UInt8, at index: Int) -> Hold {
        let hold = Hold()
        state.withLockUnchecked { $0.holds[marker] = (index, hold) }
        return hold
    }

    var status: PrintAppearanceEngineStatus {
        PrintAppearanceEngineStatus(path: .gpu, workingBytes: state.withLockUnchecked { $0.workingBytes },
                                    gpuFallbackPages: 0, compileMilliseconds: nil)
    }

    func warmUp(runDummyPage: Bool, threads: Int) throws {
        recordContext()
        state.withLockUnchecked { state in
            state.events.append("warmUp(\(runDummyPage))")
            if runDummyPage { state.workingBytes = 1000 }
        }
    }

    func releaseWorkingMemory(keepPipelines: Bool) {
        recordContext()
        state.withLockUnchecked { state in
            state.events.append("release(\(keepPipelines))")
            state.workingBytes = 0
        }
    }

    func process(_ page: PrintAppearancePage, level: PrintAppearanceLevel, threads: Int,
                 shouldStop: (PrintAppearanceStopPoint) -> Bool) throws -> PrintAppearanceGray {
        recordContext()
        let qos = qos_class_self()
        let marker = page.luma[0]
        let hold = state.withLockUnchecked { $0.holds.removeValue(forKey: marker) }
        for (index, point) in Self.points.enumerated() {
            if let hold, hold.index == index {
                hold.hold.reached.signal()
                hold.hold.proceed.wait()
            }
            if shouldStop(point) {
                record(Call(marker: marker, threads: threads, level: level, stoppedAt: point, qos: qos))
                throw PrintAppearanceError.stopped(point)
            }
        }
        if let failure = state.withLockUnchecked({ $0.failure }) {
            record(Call(marker: marker, threads: threads, level: level, stoppedAt: nil, qos: qos))
            throw failure
        }
        state.withLockUnchecked { $0.workingBytes = 1000 }
        record(Call(marker: marker, threads: threads, level: level, stoppedAt: nil, qos: qos))
        return page.luma.withUnsafeBufferPointer {
            PrintAppearanceGray(copying: $0.baseAddress!, width: page.width, height: page.height,
                                changed: marker != 255)
        }
    }

    private func record(_ call: Call) {
        state.withLockUnchecked { state in
            state.calls.append(call)
            state.events.append("process(\(call.marker))")
        }
    }

    private func recordContext() {
        let label = String(cString: __dispatch_queue_get_label(nil))
        let main = Thread.isMainThread
        state.withLockUnchecked { state in
            state.queueLabels.insert(label)
            if main { state.calledOnMainThread = true }
        }
    }

    /// 目印 marker で埋めたページ
    static func page(_ marker: UInt8, width: Int = 128, height: Int = 128) -> PrintAppearancePage {
        PrintAppearancePage(checked: [UInt8](repeating: marker, count: width * height), width: width, height: height)
    }
}
