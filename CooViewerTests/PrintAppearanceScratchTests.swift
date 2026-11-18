import XCTest
@testable import PrintAppearanceKit

/// 1 ページの間だけ使う作業域(EngineScratch.swift)の検査。ピークの列・A2 の表・ノッチの項目を
/// ページごとに malloc せず、エンジンが持つ仮想記憶の領域に置く(設計書 §2.3)。
/// 伸ばし方・巻き戻し・印の読み方が、列や表の中身を変えないことを確かめる
final class PrintAppearanceScratchTests: XCTestCase {

    // MARK: - FlatLists

    /// 見込みより多く書くと並列の put の途中で伸びるが、どの欄も書いた列のまま読める
    func testFlatListsGrowUnderParallelPuts() throws {
        let lists = FlatLists<Int>()
        let slots = 2000
        try lists.begin(slots: slots, expected: 1)
        parallelFor(slots, grain: 1, threads: 8) { i in
            var list: [Int] = []
            for k in 0..<(i % 9) { list.append(i * 100 + k) }
            _ = list.withUnsafeBufferPointer { lists.put(i, $0) }
        }
        let view = try lists.finish()
        var total = 0
        for i in 0..<slots {
            let expected = (0..<(i % 9)).map { i * 100 + $0 }
            XCTAssertEqual(Array(view[i]), expected, "欄 \(i)")
            total += expected.count
        }
        XCTAssertEqual(lists.total, total)
    }

    /// begin は前の回の列を残さない: 書かなかった欄は空(前の回より欄が多くても少なくても)
    func testFlatListsBeginLeavesUnwrittenSlotsEmpty() throws {
        let lists = FlatLists<Int>()
        try lists.begin(slots: 100, expected: 10)
        for i in 0..<100 { _ = [i, i + 1].withUnsafeBufferPointer { lists.put(i, $0) } }
        _ = try lists.finish()
        for slots in [300, 50] {
            try lists.begin(slots: slots, expected: 10)
            for i in stride(from: 0, to: slots, by: 2) { _ = [7 * i].withUnsafeBufferPointer { lists.put(i, $0) } }
            let view = try lists.finish()
            for i in 0..<slots {
                XCTAssertEqual(Array(view[i]), i % 2 == 0 ? [7 * i] : [], "欄 \(i) / \(slots)")
            }
        }
    }

    // MARK: - PeakTable と KeptPeaks

    /// 残した列は検出の列から印の付いたものを順に読んだもの。空の欄は検出の列も残した列も空
    func testKeptPeaksFollowTheKeepFlags() throws {
        func peak(_ u: Int) -> Peak {
            Peak(u: u, v: 0, cu: Double(u), cv: 0, rho: Double(u), amp: 1, prominence: 30, cpd: 10, r: 0.5)
        }
        let table = PeakTable()
        try table.begin(tiles: 3)
        table.put(tile: 0, [peak(1), peak(2), peak(3)])
        table.put(tile: 2, [peak(4), peak(5)])
        let peaks = try table.finishPass1()
        let keep0 = peaks.keep(0), keep2 = peaks.keep(2)
        keep0[0] = 1; keep0[1] = 0; keep0[2] = 1
        keep2[0] = 0; keep2[1] = 0
        XCTAssertEqual(peaks.found(0).map(\.u), [1, 2, 3])
        XCTAssertEqual(peaks.kept(0).map(\.u), [1, 3])
        XCTAssertTrue(peaks.found(1).isEmpty)
        XCTAssertEqual(peaks.kept(1).map(\.u), [])
        XCTAssertEqual(peaks.found(2).map(\.u), [4, 5])
        XCTAssertEqual(peaks.kept(2).map(\.u), [])
        // 次のページは前のページの列を残さない
        try table.begin(tiles: 2)
        table.put(tile: 1, [peak(9)])
        let next = try table.finishPass1()
        next.keep(1)[0] = 1
        XCTAssertTrue(next.found(0).isEmpty)
        XCTAssertEqual(next.kept(1).map(\.u), [9])
    }

    // MARK: - ScratchArena

    /// 塊に収まらなければ塊を足し、切り出した領域は動かない(同じページの中で前の領域が壊れない)。
    /// 次のページの初めに、要った大きさの 1 つの塊へまとめ直す。領域は 64 バイト境界で、malloc の外
    func testScratchArenaAddsChunksThenConsolidates() throws {
        let arena = ScratchArena()
        let sizes = [400_000, 400_000, 400_000, 3, 700_000]
        func takeAll() throws -> [UnsafeMutableBufferPointer<UInt8>] {
            var out: [UnsafeMutableBufferPointer<UInt8>] = []
            for (i, n) in sizes.enumerated() {
                let b = try arena.take(UInt8.self, n, repeating: UInt8(i + 1))
                XCTAssertEqual(b.count, n)
                XCTAssertEqual(Int(bitPattern: b.baseAddress!) % 64, 0, "領域 \(i) の揃え")
                XCTAssertEqual(malloc_size(UnsafeRawPointer(b.baseAddress!)), 0, "領域 \(i) は malloc の外")
                out.append(b)
            }
            return out
        }
        arena.rewind()
        let first = try takeAll()
        for (i, b) in first.enumerated() {
            XCTAssertTrue(b.allSatisfy { $0 == UInt8(i + 1) }, "領域 \(i) は後の切り出しで壊れない")
        }
        let grown = arena.byteCount
        XCTAssertGreaterThan(grown, 1 << 20, "1 MB の塊に収まらず塊を足した")
        arena.rewind()
        let second = try takeAll()
        for (i, b) in second.enumerated() { XCTAssertTrue(b.allSatisfy { $0 == UInt8(i + 1) }, "領域 \(i)") }
        let consolidated = arena.byteCount
        XCTAssertGreaterThanOrEqual(consolidated, sizes.reduce(0, +))
        // まとめ直した塊は次のページでもそのまま使う(塊を足さない)
        arena.rewind()
        _ = try takeAll()
        XCTAssertEqual(arena.byteCount, consolidated)
        // 0 個の領域も取れる
        XCTAssertEqual(try arena.take(Int.self, 0).count, 0)
    }

    /// 伸びるだけの領域は仮想記憶にあり、伸ばすときに先頭の preserving 個を写す
    func testGrowableBufferPreservesPrefixWhenGrowing() throws {
        let buffer = GrowableBuffer<Int>()
        let p = try buffer.ensure(10)
        XCTAssertEqual(Int(bitPattern: p) % Int(getpagesize()), 0)
        XCTAssertEqual(malloc_size(UnsafeRawPointer(p)), 0)
        for i in 0..<10 { p[i] = i * 3 }
        let capacity = buffer.capacity
        let q = try buffer.ensure(capacity + 1, preserving: 10)
        XCTAssertGreaterThan(buffer.capacity, capacity)
        XCTAssertEqual((0..<10).map { q[$0] }, (0..<10).map { $0 * 3 })
        // 足りていれば領域を替えない
        XCTAssertEqual(try buffer.ensure(5), q)
    }

    // MARK: - エンジン

    /// 作業域はページをまたいで使い回す(伸びる・まとめ直す)が、大きいページ → 小さいページ → 大きいページの
    /// どの結果も、新しいエンジンで初めて処理した結果と同じ
    func testScratchReuseAcrossPagesKeepsBytes() throws {
        let small = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 512, height: 768, seed: 21),
                                            width: 512, height: 768)
        let large = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 1024, height: 2048, seed: 22),
                                            width: 1024, height: 2048)
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            let large1 = Self.bytes(try engine.process(large, level: .standard, threads: 4))
            let small1 = Self.bytes(try engine.process(small, level: .standard, threads: 4))
            let large2 = Self.bytes(try engine.process(large, level: .standard, threads: 4))
            XCTAssertEqual(large1, large2, "\(mode)")
            let freshSmall = Self.bytes(try PrintAppearanceEngine(mode: mode).process(small, level: .standard, threads: 4))
            XCTAssertEqual(small1, freshSmall, "\(mode)")
        }
    }

    // MARK: - 補助

    private static let gpuPathAvailable: Bool = {
        let engine = PrintAppearanceEngine(mode: .automatic)
        guard (try? engine.warmUp(runDummyPage: false)) != nil else { return false }
        return engine.status.path == .gpu
    }()

    /// CPU の経路は常に、GPU の経路は用意できるときだけ調べる
    private static func modes() -> [PrintAppearanceEngine.Mode] {
        gpuPathAvailable ? [.cpuOnly, .automatic] : [.cpuOnly]
    }

    /// 行の詰め物を除いた W * H バイト
    private static func bytes(_ gray: PrintAppearanceGray) -> [UInt8] {
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
