import XCTest
@testable import cooViewer

/// 同一 URL の並行 EPUB 解析が 1 本に合流することの検証(cooViewer-7rl)。
@MainActor
final class EPUBParseCoalescingTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testConcurrentSameURLParsesOnce() async throws {
        let counter = Counter()
        let gate = DispatchSemaphore(value: 0)
        let coalescer = EPUBParseCoalescer(parse: { _ in
            counter.increment()
            gate.wait()  // 両呼び出しが登録されるまでブロック
            return nil
        })
        let url = URL(fileURLWithPath: "/x/a.epub")
        let a = Task { await coalescer.publication(at: url) }
        // 1 本目のパースが走り出す(= inFlight 登録済み)まで待つ
        while counter.count < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        let b = Task { await coalescer.publication(at: url) }
        // 2 本目が合流する猶予を与えてから解放(MainActor 直列なので b は
        // inFlight[key] を必ず観測する)
        try? await Task.sleep(for: .milliseconds(20))
        gate.signal()
        _ = await (a.value, b.value)
        XCTAssertEqual(counter.count, 1, "同一 URL の並行解析は 1 回だけ")
    }

    func testDifferentURLsParseIndependently() async {
        let counter = Counter()
        let coalescer = EPUBParseCoalescer(parse: { _ in
            counter.increment(); return nil
        })
        _ = await coalescer.publication(at: URL(fileURLWithPath: "/x/a.epub"))
        _ = await coalescer.publication(at: URL(fileURLWithPath: "/x/b.epub"))
        XCTAssertEqual(counter.count, 2)
    }

    func testInFlightClearedAfterCompletion() async {
        // 完了後は合流窓が閉じ、同 URL の再要求は新規パース(結果キャッシュなし)
        let counter = Counter()
        let coalescer = EPUBParseCoalescer(parse: { _ in
            counter.increment(); return nil
        })
        let url = URL(fileURLWithPath: "/x/a.epub")
        _ = await coalescer.publication(at: url)
        _ = await coalescer.publication(at: url)
        XCTAssertEqual(counter.count, 2)
    }
}
