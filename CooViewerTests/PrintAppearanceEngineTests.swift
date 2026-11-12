import XCTest
@testable import PrintAppearanceKit

/// 網点処理エンジンの性質の検査(設計書 §5)。合成ページだけを使い、期待バイト列は持たない
/// (出力は OS の vDSP・libm・GPU に依存するため、性質と「CPU 経路から 1 階調以内」を確かめる)。
/// GPU を使う検査は、エンジンが GPU の経路を用意できない環境(Metal が無い・カーネルの前提を満たさない)では飛ばす
final class PrintAppearanceEngineTests: XCTestCase {

    // MARK: - 速度

    /// エンジンは Debug のアプリからでも最適化済み(-O)のフレームワークとして呼ばれる。最適化なしでは
    /// 1362x2046 の 1 ページに数秒かかるので、温まった後の 1 ページが 0.3 秒未満であることで確かめる
    func testOptimizedEngineProcessesFullPageQuickly() throws {
        try Self.requireGPUPath()
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
        try Self.requireGPUPath()
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

    /// process は高さ 799 px のページの 強め を 標準 として処理し、800 px では 強め のまま処理する
    func testProcessAppliesTheLevelCapAt800px() throws {
        let engine = PrintAppearanceEngine(mode: .cpuOnly)
        for height in [799, 800] {
            let page = try PrintAppearancePage(
                luma: PrintAppearanceTestPages.screen(width: 512, height: height, period: 3, angle: 45),
                width: 512, height: height)
            let standard = Self.bytes(try engine.process(page, level: .standard, threads: 4))
            let strong = Self.bytes(try engine.process(page, level: .strong, threads: 4))
            if height < 800 {
                XCTAssertEqual(strong, standard)
            } else {
                XCTAssertNotEqual(strong, standard)
            }
        }
    }

    // MARK: - 止める位置

    /// 合成ページの通常の処理は 6 つの停止位置をすべて通る(パス 1 は 3 チャンク、位相揃いは複数の回)。
    /// どの位置で止めても stopped を投げ、同じエンジンで処理し直すと止めなかったときと同じバイトになる
    func testStopsAtEveryPointAndRecovers() throws {
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 384, height: 1024, seed: 11),
                                           width: 384, height: 1024)
        for mode in Self.modes() {
            let engine = PrintAppearanceEngine(mode: mode)
            var seen: [PrintAppearanceStopPoint] = []
            let reference = Self.bytes(try engine.process(page, level: .standard, threads: 4) { point in
                seen.append(point)
                return false
            })
            XCTAssertEqual(Set(seen), Set(PrintAppearanceStopPoint.allCases), "\(mode)")
            XCTAssertEqual(seen.first, .beforeRun, "\(mode)")
            XCTAssertEqual(seen.last, .beforeOutput, "\(mode)")
            XCTAssertGreaterThanOrEqual(seen.filter { $0 == .betweenPass1Chunks }.count, 2, "\(mode)")
            XCTAssertGreaterThanOrEqual(seen.filter { $0 == .betweenFillRounds }.count, 2, "\(mode)")
            for point in PrintAppearanceStopPoint.allCases {
                // 同じ位置を何度も通るものは、最初と最後の両方で止めてみる
                let visits = seen.filter { $0 == point }.count
                for stopAt in Set([1, visits]) {
                    var reached = 0
                    XCTAssertThrowsError(try engine.process(page, level: .standard, threads: 4) { p in
                        if p == point { reached += 1 }
                        return p == point && reached == stopAt
                    }) { error in
                        XCTAssertEqual(error as? PrintAppearanceError, .stopped(point), "\(mode) \(point)")
                    }
                    let again = Self.bytes(try engine.process(page, level: .standard, threads: 4))
                    XCTAssertEqual(again, reference, "\(mode) \(point) #\(stopAt)")
                }
            }
            XCTAssertEqual(engine.status.gpuFallbackPages, 0, "止めたページは GPU の失敗に数えない")
        }
    }

    /// パス 1 の途中で止めた直後に別のページを処理しても、どちらのページも新しいエンジンと同じバイトになる
    /// (止める前に積んだ GPU の仕事を待ってから戻るので、共有の記憶域へ遅れて書かれない)
    func testStopInPass1ThenOtherPageGivesFreshBytes() throws {
        let first = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 512, height: 2048, seed: 21),
                                            width: 512, height: 2048)
        let second = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 384, height: 1024, seed: 22),
                                             width: 384, height: 1024)
        for mode in Self.modes() {
            let expectedFirst = Self.bytes(try PrintAppearanceEngine(mode: mode).process(first, level: .low, threads: 4))
            let expectedSecond = Self.bytes(try PrintAppearanceEngine(mode: mode).process(second, level: .low, threads: 4))
            let engine = PrintAppearanceEngine(mode: mode)
            XCTAssertThrowsError(try engine.process(first, level: .low, threads: 4) { $0 == .betweenPass1Chunks })
            XCTAssertEqual(Self.bytes(try engine.process(second, level: .low, threads: 4)), expectedSecond, "\(mode)")
            XCTAssertEqual(Self.bytes(try engine.process(first, level: .low, threads: 4)), expectedFirst, "\(mode)")
        }
    }

    // MARK: - GPU の失敗からの回復

    /// GPU の経路が失敗したページは CPU の厳密な経路で処理し直し、その結果を返す(生の画素は返さない)。
    /// 1 回だけなら GPU の経路に戻り、2 ページ続けて失敗すると以後は CPU だけで動く
    func testGPUFailureFallsBackToCPUThenCPUOnlyAfterTwo() throws {
        try Self.requireGPUPath()
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 512, height: 2048),
                                           width: 512, height: 2048)
        let cpuBytes = Self.bytes(try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: .standard, threads: 4))
        let gpuBytes = Self.bytes(try PrintAppearanceEngine(mode: .automatic).process(page, level: .standard,
                                                                                     threads: 4))
        let engine = PrintAppearanceEngine(mode: .automatic)
        let fail: (PrintAppearanceStopPoint) -> PrintAppearanceError? = {
            $0 == .betweenPass1Chunks ? .gpuFailed("試験用の失敗") : nil
        }
        // 1 回目の失敗: CPU の結果を返し、GPU の経路は保つ
        engine.gpuFaultForTesting = fail
        XCTAssertEqual(Self.bytes(try engine.process(page, level: .standard, threads: 4)), cpuBytes)
        XCTAssertEqual(engine.status.path, .gpu)
        XCTAssertEqual(engine.status.gpuFallbackPages, 1)
        // 成功すれば連続の数え直し
        engine.gpuFaultForTesting = nil
        XCTAssertEqual(Self.bytes(try engine.process(page, level: .standard, threads: 4)), gpuBytes)
        engine.gpuFaultForTesting = fail
        XCTAssertEqual(Self.bytes(try engine.process(page, level: .standard, threads: 4)), cpuBytes)
        XCTAssertEqual(engine.status.path, .gpu, "成功を挟んだ失敗は 1 回目として数える")
        // 2 ページ続けて失敗すると CPU だけになる
        XCTAssertEqual(Self.bytes(try engine.process(page, level: .standard, threads: 4)), cpuBytes)
        XCTAssertEqual(engine.status.path, .cpuOnly(.repeatedGPUFailures))
        XCTAssertEqual(engine.status.gpuFallbackPages, 3)
        engine.gpuFaultForTesting = nil
        XCTAssertEqual(Self.bytes(try engine.process(page, level: .standard, threads: 4)), cpuBytes)
        XCTAssertEqual(engine.status.path, .cpuOnly(.repeatedGPUFailures))
    }

    /// GPU の集約に収まらないページ(GPU だけの制約)は CPU の経路で処理し直す。GPU の失敗には数えない
    func testGPUOnlyRefusalIsRerunOnCPUWithoutCountingAsFailure() throws {
        try Self.requireGPUPath()
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 384, height: 1024, seed: 11),
                                           width: 384, height: 1024)
        let cpuBytes = Self.bytes(try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: .strong, threads: 4))
        let engine = PrintAppearanceEngine(mode: .automatic)
        engine.gpuFaultForTesting = { $0 == .beforeOutput ? .unsupportedPage("試験用の制約") : nil }
        for _ in 0..<3 {
            XCTAssertEqual(Self.bytes(try engine.process(page, level: .strong, threads: 4)), cpuBytes)
        }
        XCTAssertEqual(engine.status.path, .gpu)
        XCTAssertEqual(engine.status.gpuFallbackPages, 0)
    }

    /// 止める求めは GPU の失敗の回復より優先し、CPU でやり直さずに投げる
    func testStopIsNotTreatedAsGPUFailure() throws {
        try Self.requireGPUPath()
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 384, height: 1024, seed: 11),
                                           width: 384, height: 1024)
        let engine = PrintAppearanceEngine(mode: .automatic)
        var points: [PrintAppearanceStopPoint] = []
        XCTAssertThrowsError(try engine.process(page, level: .standard, threads: 4) { point in
            points.append(point)
            return point == .afterPass1
        }) { error in
            XCTAssertEqual(error as? PrintAppearanceError, .stopped(.afterPass1))
        }
        XCTAssertEqual(points.filter { $0 == .beforeRun }.count, 1, "CPU の経路で処理し直していない")
        XCTAssertEqual(engine.status.gpuFallbackPages, 0)
    }

    /// GPU を今は作れない(ファイル記述子の余裕が無いなど)ときはそのページを CPU で処理し、後のページで作る
    func testGPUCreationDeferredWhileNotAllowed() throws {
        try Self.requireGPUPath()
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 512, height: 2048),
                                           width: 512, height: 2048)
        let cpuBytes = Self.bytes(try PrintAppearanceEngine(mode: .cpuOnly).process(page, level: .low, threads: 4))
        let gpuBytes = Self.bytes(try PrintAppearanceEngine(mode: .automatic).process(page, level: .low, threads: 4))
        let allowed = Flag()
        let engine = PrintAppearanceEngine(mode: .automatic, canCreateGPU: { allowed.value })
        XCTAssertEqual(Self.bytes(try engine.process(page, level: .low, threads: 4)), cpuBytes)
        XCTAssertEqual(engine.status.path, .idle)
        allowed.value = true
        XCTAssertEqual(Self.bytes(try engine.process(page, level: .low, threads: 4)), gpuBytes)
        XCTAssertEqual(engine.status.path, .gpu)
    }

    // MARK: - 準備・解放・状態

    func testCPUOnlyModeReportsRequestedReason() throws {
        let engine = PrintAppearanceEngine(mode: .cpuOnly)
        try engine.warmUp(runDummyPage: false)
        XCTAssertEqual(engine.status.path, .cpuOnly(.requested))
        XCTAssertEqual(engine.status.workingBytes, 0)
        XCTAssertNil(engine.status.compileMilliseconds)
    }

    /// warmUp はパイプラインを作り、合成ページで作業域を用意する。解放すると作業域は 0 に戻り、
    /// パイプラインを残すかどうかで状態が変わる。どの段階の後でも出力は同じ
    func testWarmUpReleaseAndStatus() throws {
        let page = try PrintAppearancePage(luma: PrintAppearanceTestPages.mix(width: 384, height: 1024, seed: 11),
                                           width: 384, height: 1024)
        for mode in Self.modes() {
            let expected = Self.bytes(try PrintAppearanceEngine(mode: mode).process(page, level: .low, threads: 4))
            let engine = PrintAppearanceEngine(mode: mode)
            let gpuPath: PrintAppearanceEngineStatus.Path = mode == .automatic ? .gpu : .cpuOnly(.requested)
            XCTAssertEqual(engine.status.path, mode == .automatic ? .idle : .cpuOnly(.requested))
            try engine.warmUp(runDummyPage: false)
            XCTAssertEqual(engine.status.path, gpuPath)
            XCTAssertEqual(engine.status.workingBytes, 0)
            if mode == .automatic { XCTAssertNotNil(engine.status.compileMilliseconds) }
            try engine.warmUp(runDummyPage: true)
            XCTAssertGreaterThan(engine.status.workingBytes, 0)
            XCTAssertEqual(Self.bytes(try engine.process(page, level: .low, threads: 4)), expected, "\(mode)")
            let working = engine.status.workingBytes
            XCTAssertGreaterThan(working, 0)
            engine.releaseWorkingMemory(keepPipelines: true)
            XCTAssertEqual(engine.status.workingBytes, 0)
            XCTAssertEqual(engine.status.path, gpuPath)
            XCTAssertEqual(Self.bytes(try engine.process(page, level: .low, threads: 4)), expected, "\(mode)")
            XCTAssertGreaterThan(engine.status.workingBytes, 0)
            engine.releaseWorkingMemory(keepPipelines: false)
            XCTAssertEqual(engine.status.workingBytes, 0)
            XCTAssertEqual(engine.status.path, mode == .automatic ? .idle : .cpuOnly(.requested))
            XCTAssertEqual(Self.bytes(try engine.process(page, level: .low, threads: 4)), expected, "\(mode)")
            XCTAssertEqual(engine.status.path, gpuPath)
        }
    }

    // MARK: - 補助

    /// エンジンが GPU の経路を用意できるか(Metal があり、パイプラインがカーネルの前提を満たす)
    private static let gpuPathAvailable: Bool = {
        let engine = PrintAppearanceEngine(mode: .automatic)
        guard (try? engine.warmUp(runDummyPage: false)) != nil else { return false }
        return engine.status.path == .gpu
    }()

    private static func requireGPUPath() throws {
        guard gpuPathAvailable else { throw XCTSkip("GPU の経路を用意できない環境") }
    }

    /// CPU の経路は常に、GPU の経路は用意できるときだけ調べる
    private static func modes() -> [PrintAppearanceEngine.Mode] {
        gpuPathAvailable ? [.cpuOnly, .automatic] : [.cpuOnly]
    }

    /// canCreateGPU に渡す切り替え(テストの中で同じスレッドからだけ触る)
    private final class Flag {
        var value = false
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
