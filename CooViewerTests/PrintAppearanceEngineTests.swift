import Metal
import XCTest
@testable import PrintAppearanceKit

/// 網点処理エンジンの性質の検査(設計書 §5)。合成ページだけを使い、期待バイト列は持たない
/// (出力は OS の vDSP・libm・GPU に依存するため、性質と「CPU 経路から 1 階調以内」を確かめる)。
/// GPU を使う検査は Metal が無い環境では飛ばす
final class PrintAppearanceEngineTests: XCTestCase {

    // MARK: - 速度

    /// エンジンは Debug のアプリからでも最適化済み(-O)のフレームワークとして呼ばれる。最適化なしでは
    /// 1362x2046 の 1 ページに数秒かかるので、温まった後の 1 ページが 0.3 秒未満であることで確かめる
    func testOptimizedEngineProcessesFullPageQuickly() throws {
        try Self.requireMetal()
        let W = 1362, H = 2046
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: W, height: H), width: W, height: H)
        let engine = PrintAppearanceEngine(mode: .automatic)
        _ = try engine.process(page, level: .standard, threads: 8)   // カーネルのコンパイルと記憶域の確保
        var best = Double.infinity
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let gray = try engine.process(page, level: .standard, threads: 8)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            XCTAssertTrue(gray.changed)
        }
        print("PrintAppearanceEngineTests: 1362x2046 の温まった 1 ページの最短時間 \(best) 秒")
        XCTAssertLessThan(best, 0.3, "温まった 1 ページの最短時間 \(best) 秒")
    }

    // MARK: - 出力の性質

    /// 一様なページ(0 / 128 / 255)は変わらない
    func testFlatPagesStayUnchanged() throws {
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            for value in [UInt8(0), 128, 255] {
                let luma = PrintAppearanceTestPages.flat(width: 256, height: 256, value: value)
                for level in PrintAppearanceLevel.allCases {
                    let gray = try engine.process(try PrintAppearancePage(luma: luma, width: 256, height: 256),
                                                  level: level, threads: 4)
                    XCTAssertFalse(gray.changed, "\(mode) \(value) \(level)")
                    XCTAssertEqual(Self.bytes(gray), luma, "\(mode) \(value) \(level)")
                }
            }
        }
    }

    /// 紙の本では見分けられない細かい網点(高さ 2048 px のページで周期 4 px)は変調の大部分を失う
    func testFineScreenLosesItsModulation() throws {
        let W = 512, H = 2048
        let luma = PrintAppearanceTestPages.screen(width: W, height: H, period: 4, angle: 45)
        let rect = (x0: 64, y0: 64, x1: W - 64, y1: H - 64)
        let before = PrintAppearanceTestPages.modulation(luma, width: W, rect: rect)
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            for level in PrintAppearanceLevel.allCases {
                let gray = try engine.process(try PrintAppearancePage(luma: luma, width: W, height: H), level: level,
                                              threads: 4)
                let after = PrintAppearanceTestPages.modulation(Self.bytes(gray), width: W, rect: rect)
                XCTAssertTrue(gray.changed)
                XCTAssertLessThan(after, before * 0.5, "\(mode) \(level): \(before) -> \(after)")
            }
        }
    }

    /// 見分けられる粗い網点(周期 11 px)は基本の周期を保つ
    func testCoarseScreenKeepsItsFundamental() throws {
        let W = 512, H = 2048
        let luma = PrintAppearanceTestPages.screen(width: W, height: H, period: 11, angle: 45)
        let rect = (x0: 64, y0: 64, x1: W - 64, y1: H - 64)
        let before = PrintAppearanceTestPages.modulation(luma, width: W, rect: rect)
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            for level in PrintAppearanceLevel.allCases {
                let gray = try engine.process(try PrintAppearancePage(luma: luma, width: W, height: H), level: level,
                                              threads: 4)
                let after = PrintAppearanceTestPages.modulation(Self.bytes(gray), width: W, rect: rect)
                XCTAssertGreaterThan(after, before * 0.95, "\(mode) \(level): \(before) -> \(after)")
            }
        }
    }

    /// 線画と文字は残る: 線と紙の平均はほぼ変わらず、変わる画素はわずか
    func testLineArtKeepsItsContrast() throws {
        let W = 512, H = 2048
        let luma = PrintAppearanceTestPages.lineArt(width: W, height: H)
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            for level in PrintAppearanceLevel.allCases {
                let out = Self.bytes(try engine.process(try PrintAppearancePage(luma: luma, width: W, height: H),
                                                        level: level, threads: 4))
                var inkIn = 0.0, inkOut = 0.0, inkCount = 0, paperIn = 0.0, paperOut = 0.0, paperCount = 0, changed = 0
                for i in 0..<(W * H) {
                    if luma[i] <= 20 {
                        inkIn += Double(luma[i]); inkOut += Double(out[i]); inkCount += 1
                    } else {
                        paperIn += Double(luma[i]); paperOut += Double(out[i]); paperCount += 1
                    }
                    if out[i] != luma[i] { changed += 1 }
                }
                XCTAssertGreaterThan(inkCount, 10_000)
                XCTAssertEqual(inkOut / Double(inkCount), inkIn / Double(inkCount), accuracy: 1, "\(mode) \(level)")
                XCTAssertEqual(paperOut / Double(paperCount), paperIn / Double(paperCount), accuracy: 1, "\(mode) \(level)")
                XCTAssertLessThan(Double(changed) / Double(W * H), 0.01, "\(mode) \(level)")
            }
        }
    }

    /// 既定の経路(GPU)は CPU だけの厳密な経路から 1 階調より離れない
    func testDefaultPathStaysWithinOneLevelOfCPUPath() throws {
        try Self.requireMetal()
        let W = 512, H = 2048
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: W, height: H), width: W, height: H)
        let gpu = PrintAppearanceEngine(mode: .automatic), cpu = PrintAppearanceEngine(mode: .cpuOnly)
        for level in PrintAppearanceLevel.allCases {
            let a = Self.bytes(try gpu.process(page, level: level, threads: 4))
            let b = Self.bytes(try cpu.process(page, level: level, threads: 4))
            var maxDifference = 0, changed = 0
            for i in 0..<(W * H) {
                maxDifference = max(maxDifference, abs(Int(a[i]) - Int(b[i])))
                if b[i] != page.luma[i] { changed += 1 }
            }
            XCTAssertGreaterThan(changed, 0, "\(level)")
            XCTAssertLessThanOrEqual(maxDifference, 1, "\(level)")
        }
    }

    /// 出力は並列数によらない
    func testOutputDoesNotDependOnThreadCount() throws {
        let W = 512, H = 2048
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: W, height: H), width: W, height: H)
        let many = max(2, ProcessInfo.processInfo.activeProcessorCount)
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            let two = Self.bytes(try engine.process(page, level: .standard, threads: 2))
            let all = Self.bytes(try engine.process(page, level: .standard, threads: many))
            let one = Self.bytes(try engine.process(page, level: .standard, threads: 1))
            XCTAssertEqual(two, all, "\(mode)")
            XCTAssertEqual(two, one, "\(mode)")
        }
    }

    /// 記憶域は伸びるだけなので、大きいページの後に小さいページを処理しても結果は同じ
    func testSameBytesAfterALargerPage() throws {
        let small = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 384, height: 1024, seed: 11),
                                            width: 384, height: 1024)
        let large = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 768, height: 2048, seed: 12),
                                            width: 768, height: 2048)
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            let first = Self.bytes(try engine.process(small, level: .strong, threads: 4))
            _ = try engine.process(large, level: .strong, threads: 4)
            let again = Self.bytes(try engine.process(small, level: .strong, threads: 4))
            XCTAssertEqual(first, again, "\(mode)")
            // 別のエンジンで初めて処理した結果とも一致する
            let fresh = Self.bytes(try PrintAppearanceEngine(mode: mode).process(small, level: .strong, threads: 4))
            XCTAssertEqual(first, fresh, "\(mode)")
        }
    }

    /// 出力の行は 16 バイト境界に揃い、行末の詰め物は 0
    func testOutputRowsAreAlignedAndPadded() throws {
        let W = 333, H = 257
        let luma = PrintAppearanceTestPages.flat(width: W, height: H, value: 77)
        let gray = try PrintAppearanceEngine(mode: .cpuOnly).process(try PrintAppearancePage(luma: luma, width: W, height: H),
                                                                     level: .standard, threads: 2)
        XCTAssertEqual(gray.width, W)
        XCTAssertEqual(gray.height, H)
        XCTAssertEqual(gray.bytesPerRow % 16, 0)
        XCTAssertGreaterThanOrEqual(gray.bytesPerRow, W)
        XCTAssertEqual(gray.pixels.count, gray.bytesPerRow * H)
        gray.pixels.withUnsafeBytes { raw in
            for y in 0..<H {
                for x in W..<gray.bytesPerRow { XCTAssertEqual(raw[y * gray.bytesPerRow + x], 0) }
            }
        }
        XCTAssertEqual(Self.bytes(gray), luma)
    }

    // MARK: - 入力の扱い

    /// 辺が 128 px 未満のページはエンジンが断る(素通しの判断は呼び出し側が先に行う)
    func testRejectsPagesSmallerThanOneTile() throws {
        let engine = PrintAppearanceEngine(mode: .cpuOnly)
        for (w, h) in [(127, 512), (512, 127)] {
            let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.flat(width: w, height: h, value: 200),
                                               width: w, height: h)
            XCTAssertThrowsError(try engine.process(page, level: .standard, threads: 2)) { error in
                guard case PrintAppearanceError.unsupportedPage = error else {
                    return XCTFail("想定外のエラー \(error)")
                }
            }
        }
        let edge = try PrintAppearancePage(luma: PrintAppearanceTestPages.flat(width: 128, height: 128, value: 200),
                                           width: 128, height: 128)
        XCTAssertNoThrow(try engine.process(edge, level: .standard, threads: 2))
    }

    func testPageRejectsMismatchedLumaSize() {
        XCTAssertThrowsError(try PrintAppearancePage(luma: [UInt8](repeating: 0, count: 10), width: 4, height: 4))
        XCTAssertThrowsError(try PrintAppearancePage(luma: [], width: 0, height: 0))
    }

    /// 強め は高さ 800 px 未満のページでは 標準 に留める。他の段階は高さによらない
    func testEffectiveLevelCapsStrongBelow800px() {
        XCTAssertEqual(PrintAppearance.effectiveLevel(.strong, heightPx: 799), .standard)
        XCTAssertEqual(PrintAppearance.effectiveLevel(.strong, heightPx: 800), .strong)
        XCTAssertEqual(PrintAppearance.effectiveLevel(.standard, heightPx: 799), .standard)
        XCTAssertEqual(PrintAppearance.effectiveLevel(.low, heightPx: 100), .low)
        XCTAssertEqual(PrintAppearanceLevel.low.distanceMM, 250)
        XCTAssertEqual(PrintAppearanceLevel.standard.distanceMM, 300)
        XCTAssertEqual(PrintAppearanceLevel.strong.distanceMM, 400)
    }

    // MARK: - 補助

    private static func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal が使えない環境") }
    }

    /// CPU の経路は常に、GPU の経路は Metal があるときだけ調べる
    private static func modes() -> [PrintAppearanceEngine.Mode] {
        MTLCreateSystemDefaultDevice() != nil ? [.cpuOnly, .automatic] : [.cpuOnly]
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
