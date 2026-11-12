import Metal
import XCTest
@testable import PrintAppearanceKit

/// 網点処理エンジンの内部の自己検査(設計書 §5)。合成データだけを使い、黄金値(期待バイト列)は持たない。
/// GPU を使う検査は Metal が無い環境では飛ばす。CPU の検査は常に走る
final class PrintAppearanceKernelTests: XCTestCase {

    // MARK: - 調整値

    /// 調整値は出力のバイトを決めるので、41 項目すべてを固定する(変えるなら engineVersion も上げる)
    func testParameterConstants() throws {
        let p = Params.printAppearance
        XCTAssertEqual(p.tile, 128)
        XCTAssertEqual(p.hop, 32)
        XCTAssertEqual(p.rminBins, 3)
        XCTAssertEqual(p.kBackground, 20)
        XCTAssertEqual(p.kRadial, 4)
        XCTAssertEqual(p.radialOffsetBins, 3)
        XCTAssertEqual(p.ampMin, 0.006)
        XCTAssertEqual(p.notchFlatBins, 1)
        XCTAssertEqual(p.notchSigmaBins, 1)
        XCTAssertEqual(p.notchExtentBins, 4.5)
        XCTAssertEqual(p.notchFlatFrac, 0.15)
        XCTAssertEqual(p.notchSigmaFrac, 0.07)
        XCTAssertEqual(p.subMaxOrder, 16)
        XCTAssertEqual(p.subMinProminence, 4)
        XCTAssertEqual(p.screenMaxPeriodMM, 1.3)
        XCTAssertEqual(p.aliasMaxOrder, 0)
        XCTAssertEqual(p.aliasTolBins, 1.5)
        XCTAssertEqual(p.gateSigmaPx, 2)
        XCTAssertEqual(p.gateHighpassSigmaPx, 1.5)
        XCTAssertTrue(p.floorAtBinRetention)
        XCTAssertEqual(p.minNeighbours, 2)
        XCTAssertEqual(p.neighbourTolBins, 1.5)
        XCTAssertEqual(p.bMaskRetention, 0.5)
        XCTAssertEqual(p.bCutoffRetention, 0.5)
        XCTAssertEqual(p.colourLevel, 32)
        XCTAssertEqual(p.colourFrac, 0.005)

        let q = A2Params.printAppearance
        XCTAssertEqual(q.fillBlock, 16)
        XCTAssertEqual(q.clusterMinTiles, 5)
        XCTAssertEqual(q.fillCore, 0.65)
        XCTAssertEqual(q.clusterTolBins, 2.5)
        XCTAssertEqual(q.clusterBigTiles, 48)
        XCTAssertEqual(q.partnerAngleMin, 70)
        XCTAssertEqual(q.partnerAngleMax, 110)
        XCTAssertEqual(q.partnerRadiusTol, 0.15)
        XCTAssertTrue(q.partnerEnabled)
        XCTAssertEqual(q.partnerMinFill, 0.35)
        XCTAssertEqual(q.orthoAngleTol, 10)
        XCTAssertEqual(q.orthoRadiusTol, 0.08)
        XCTAssertEqual(q.closureOrder, 3)
        XCTAssertEqual(q.closureTolBins, 1.5)
        XCTAssertEqual(q.orthoMinTiles, 2)

        XCTAssertNoThrow(try validateParams(p))
        XCTAssertNoThrow(try validateA2Params(q))
        // GPU の候補絞り込みは両係数が Float で正確に表せることを前提にする
        XCTAssertEqual(Double(Float(p.kRadial)), p.kRadial)
        XCTAssertEqual(Double(Float(p.kBackground)), p.kBackground)
        XCTAssertEqual(PrintAppearance.engineVersion, 1)
    }

    // MARK: - 表と選択

    /// 環の中央値のクイックセレクトは、56 値を並べ替えた 28 番目と一致する(同値の多い整数値の面も含む)
    func testRingMedianSelectionEqualsSort() {
        var rng = SplitMix64(seed: 0x52_494E_47)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let power = UnsafeMutablePointer<Float>.allocate(capacity: NN)
        defer { scratch.deallocate(); power.deallocate() }
        var bad = 0, checks = 0
        for fill in 0..<40 {
            for k in 0..<NN {
                power[k] = fill % 3 == 0 ? Float(Int.random(in: 0...5, using: &rng)) : Float.random(in: 0...100, using: &rng)
            }
            for _ in 0..<500 {
                let u = Int.random(in: -63...63, using: &rng), v = Int.random(in: 0...63, using: &rng)
                var ring: [Float] = []
                for dv in -4...4 {
                    for du in -4...4 where max(abs(du), abs(dv)) >= 3 { ring.append(power[pidx(u + du, v + dv)]) }
                }
                ring.sort()
                if ringMedianValue(power, u, v, scratch) != ring[28] { bad += 1 }
                checks += 1
            }
        }
        XCTAssertEqual(checks, 20_000)
        XCTAssertEqual(bad, 0)
    }

    /// GPU の再符号化が数えるしきい値は encodeByte と一致する: 各しきい値はちょうど境目にあり、
    /// 任意の値でしきい値を数えた結果が encodeByte に等しい
    func testEncodeThresholdsMatchEncodeByte() {
        for b in 1...255 {
            let t = encodeThresholds[b]
            XCTAssertGreaterThanOrEqual(Int(encodeByte(t)), b, "b = \(b)")
            XCTAssertLessThan(Int(encodeByte(t.nextDown)), b, "b = \(b)")
        }
        var rng = SplitMix64(seed: 0x454E_43)
        var bad = 0
        for _ in 0..<20_000 {
            let x = Float.random(in: -0.1...1.1, using: &rng)
            if thresholdCount(x) != Int(encodeByte(x)) { bad += 1 }
        }
        for v in 0..<256 where thresholdCount(eotf[v]) != v { bad += 1 }
        XCTAssertEqual(bad, 0)
    }

    /// q3 の前提: 線形化してから符号化し直すと元の値に戻り(この libm では恒等)、クランプした値
    /// lin + (eotf[b] - lin) も CPU・GPU の両方の符号化で b に戻る
    func testEncodedScanAndClampRoundTrip() {
        for v in 0..<256 {
            XCTAssertEqual(encodeByte(eotf[v]), UInt8(v))
            XCTAssertEqual(q3EncLUT[v], UInt8(v))
        }
        var bad = 0, badThreshold = 0
        for s in 0..<256 {
            for b in 0..<256 {
                let lin = eotf[s], d = eotf[b] - lin
                let raw = lin + d
                if encodeByte(raw) != UInt8(b) { bad += 1 }
                if thresholdCount(raw) != b { badThreshold += 1 }
            }
        }
        XCTAssertEqual(bad, 0)
        XCTAssertEqual(badThreshold, 0)
    }

    /// 重ね合わせの重みの和は 32x32 の周期模様で、周期的な Hann 窓の 4 重の重なりなので理論上は一定(2.25)。
    /// Float の丸めの範囲でそれに一致し、割り算の分母として安全であること
    func testWindowSumPatternIsFlat() {
        XCTAssertEqual(wsumPattern.count, 32 * 32)
        for value in wsumPattern {
            XCTAssertEqual(value, 2.25, accuracy: 1e-5)
        }
    }

    /// 位相揃いの SIMD 版(fillBlock 16)はスカラー版とビット単位で一致する
    func testCoherentFillSIMDMatchesScalarReference() {
        var rng = SplitMix64(seed: 0x46_494C_4C)
        let W = 333, H = 517
        var lin = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let s = 0.5 + 0.3 * sin(2 * Double.pi * (Double(x) * 0.21 + Double(y) * 0.13)) * cos(Double(y) * 0.05)
                lin[y * W + x] = eotf[max(0, min(255, Int((s * 255).rounded()) + Int.random(in: -6...6, using: &rng)))]
            }
        }
        let scratch = FillScratch()
        var bad = 0, trials = 0
        lin.withUnsafeBufferPointer { lp in
            for t in 0..<400 {
                let tx = Int.random(in: 0..<((W + 96) / 32), using: &rng), ty = Int.random(in: 0..<((H + 96) / 32), using: &rng)
                scratch.load(lp.baseAddress!, W: W, H: H, tile: t, x0: -96 + 32 * tx, y0: -96 + 32 * ty, block: 16)
                let natural = scratch.naturalRaw()
                for _ in 0..<5 {
                    let cu = Double.random(in: -63...63, using: &rng), cv = Double.random(in: 0...63, using: &rng)
                    let a = scratch.fill(cu: cu, cv: cv)
                    let b = natural.withUnsafeBufferPointer {
                        coherentFillReference(raw: $0.baseAddress!, cu: cu, cv: cv, block: 16)
                    }
                    if a.bitPattern != b.bitPattern { bad += 1 }
                    trials += 1
                }
            }
        }
        XCTAssertEqual(trials, 2000)
        XCTAssertEqual(bad, 0)
    }

    // MARK: - q3 の窓

    /// CPU の窓の選択(行ごとに並列)は、規則をそのまま書き写した単一スレッドの実装と一致する
    func testQ3BoundsCPUMatchesTranscription() {
        var rng = SplitMix64(seed: 0x5133_2026_1113)
        var images = 0, differing = 0
        for (w, h, repeats) in Self.q3Sizes {
            for _ in 0..<repeats {
                let src = Self.q3SampleImage(w: w, h: h, rng: &rng)
                let reference = Self.q3BoundsTranscription(enc: src.map { q3EncLUT[Int($0)] }, w: w, h: h)
                let cpu = src.withUnsafeBufferPointer { q3BoundsCPU(src: $0.baseAddress!, W: w, H: h, threads: 4) }
                for i in 0..<(w * h) where reference[2 * i] != cpu[2 * i] || reference[2 * i + 1] != cpu[2 * i + 1] {
                    differing += 1
                }
                images += 1
            }
        }
        XCTAssertGreaterThan(images, 40)
        XCTAssertEqual(differing, 0)
    }

    /// GPU の q3Window カーネルは書き写した実装と一致する
    func testQ3WindowKernelMatchesTranscription() throws {
        let g = try Self.gpuContext()
        var rng = SplitMix64(seed: 0x5133_2026_1113)
        var differing = 0
        for (w, h, repeats) in Self.q3Sizes {
            for _ in 0..<repeats {
                let n = w * h
                let src = Self.q3SampleImage(w: w, h: h, rng: &rng)
                let reference = Self.q3BoundsTranscription(enc: src.map { q3EncLUT[Int($0)] }, w: w, h: h)
                let srcB = try Self.buffer(g, src)
                let boundsB = try XCTUnwrap(g.device.makeBuffer(length: max(4, 2 * n), options: .storageModeShared))
                let cb = try g.makeCommandBuffer()
                let enc = try g.makeEncoder(cb)
                enc.set([srcB, boundsB, g.q3EncBuf]); enc.bytes(PageInfo(W: Int32(w), H: Int32(h), nx: 0, ny: 0), 3)
                enc.grid2D(g.pipe(.q3Window), w, h)
                enc.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
                XCTAssertEqual(cb.status, .completed)
                let gb = boundsB.contents().bindMemory(to: UInt8.self, capacity: 2 * n)
                for i in 0..<n where gb[2 * i] != reference[2 * i] || gb[2 * i + 1] != reference[2 * i + 1] {
                    differing += 1
                }
            }
        }
        XCTAssertEqual(differing, 0)
    }

    /// ゲート = 1(ex = ed)のときの GPU の gateEncodeQ3 は、CPU の q3 + 範囲外の数え + 符号化と
    /// 出力バイト・delta のビット・触れた数・範囲外の数がすべて一致する
    func testGPUGateEncodeQ3MatchesCPU() throws {
        let g = try Self.gpuContext()
        var rng = SplitMix64(seed: 0x4741_5445)
        var outBad = 0, deltaBad = 0, changedPixels = 0
        var touchedCPU = 0, touchedGPU = 0, clampedCPU = 0, clampedGPU = 0
        for (w, h, repeats) in Self.q3Sizes {
            for _ in 0..<repeats {
                let n = w * h
                let src = Self.q3SampleImage(w: w, h: h, rng: &rng)
                let lin = src.map { eotf[Int($0)] }
                var delta = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let r = Int.random(in: 0..<10, using: &rng)
                    delta[i] = r < 2 ? 0 : (r < 4 ? Float.random(in: -1e-3...1e-3, using: &rng)
                                                  : Float.random(in: -0.6...0.6, using: &rng))
                }
                let srcB = try Self.buffer(g, src)
                let boundsB = try XCTUnwrap(g.device.makeBuffer(length: max(4, 2 * n), options: .storageModeShared))
                let linB = try Self.buffer(g, lin), deltaB = try Self.buffer(g, delta)
                let onesB = try Self.buffer(g, [Float](repeating: 1, count: n))
                let outB = try XCTUnwrap(g.device.makeBuffer(length: max(4, n), options: .storageModeShared))
                let countB = try XCTUnwrap(g.device.makeBuffer(length: 16, options: .storageModeShared))
                memset(countB.contents(), 0, 16)
                let cb = try g.makeCommandBuffer()
                let enc = try g.makeEncoder(cb)
                enc.set([srcB, boundsB, g.q3EncBuf]); enc.bytes(PageInfo(W: Int32(w), H: Int32(h), nx: 0, ny: 0), 3)
                enc.grid2D(g.pipe(.q3Window), w, h)
                enc.set([linB, deltaB, onesB, onesB, srcB, outB, g.thrBuf, countB]); enc.bytes(UInt32(n), 8)
                enc.setBuffer(boundsB, offset: 0, index: 9); enc.setBuffer(g.eotfBuf, offset: 0, index: 10)
                enc.grid1D(g.pipe(.gateEncodeQ3), n)
                enc.endEncoding()
                cb.commit(); cb.waitUntilCompleted()
                XCTAssertEqual(cb.status, .completed)
                // CPU: ゲート 1、q3、範囲外の数え、符号化
                var cpuDelta = delta
                touchedCPU += lin.withUnsafeBufferPointer { lp in
                    cpuDelta.withUnsafeMutableBufferPointer { dp in
                        src.withUnsafeBufferPointer { sp in
                            q3ClampCPU(lin: lp.baseAddress!, delta: dp.baseAddress!, src: sp.baseAddress!, W: w, H: h,
                                       threads: 4)
                        }
                    }
                }
                var cpuOut = src
                for i in 0..<n where cpuDelta[i] != 0 {
                    let raw = lin[i] + cpuDelta[i]
                    if raw < 0 || raw > 1 { clampedCPU += 1 }
                    cpuOut[i] = encodeByte(raw)
                }
                let gpuOut = outB.contents().bindMemory(to: UInt8.self, capacity: n)
                let gpuDelta = deltaB.contents().bindMemory(to: Float.self, capacity: n)
                for i in 0..<n {
                    if gpuOut[i] != cpuOut[i] { outBad += 1 }
                    if gpuDelta[i].bitPattern != cpuDelta[i].bitPattern { deltaBad += 1 }
                    if cpuOut[i] != src[i] { changedPixels += 1 }
                }
                let counters = countB.contents().bindMemory(to: UInt32.self, capacity: 4)
                clampedGPU += Int(counters[0]); touchedGPU += Int(counters[2])
            }
        }
        XCTAssertGreaterThan(changedPixels, 0)
        XCTAssertGreaterThan(touchedCPU, 0)
        XCTAssertEqual(outBad, 0)
        XCTAssertEqual(deltaBad, 0)
        XCTAssertEqual(touchedGPU, touchedCPU)
        XCTAssertEqual(clampedGPU, clampedCPU)
    }

    // MARK: - 候補の絞り込み

    /// GPU の候補絞り込みを通した検出は、全ビンを CPU で調べた検出と同じピークの列になる
    func testGPUPrefilterMatchesFullCPUScan() throws {
        let g = try Self.gpuContext()
        let p = Params.printAppearance
        let W = 512, H = 1024
        let lin = PrintAppearanceTestPages.mix(width: W, height: H).map { eotf[Int($0)] }
        let geo = Geometry(pageHeightMM: 173, distanceMM: 300, pageHeightPx: H)
        let detector = DetectorA(params: p, geometry: geo)
        let scan = makeScan(p)
        let words = (scan.count + 31) / 32
        let nx = tileOrigins(W, maxExtent: max(W, H)).count, ny = tileOrigins(H, maxExtent: max(W, H)).count
        let T = nx * ny
        let worker = try CPUTileWorker()
        let spectra = try XCTUnwrap(g.device.makeBuffer(length: T * NN * 4, options: .storageModeShared))
        let power = spectra.contents().bindMemory(to: Float.self, capacity: T * NN)
        lin.withUnsafeBufferPointer { lp in
            for ti in 0..<T {
                worker.analyse(lp.baseAddress!, w: W, h: H, x0: -96 + 32 * (ti % nx), y0: -96 + 32 * (ti / nx))
                worker.powerSpectrum(into: power + ti * NN)
            }
        }
        let packed = scan.map { SIMD4<Int32>($0.u, $0.v, $0.inner, $0.outer) }
        let scanB = try Self.buffer(g, packed)
        let candidates = try XCTUnwrap(g.device.makeBuffer(length: T * words * 4, options: .storageModeShared))
        let pp = PrefilterParams(scanCount: UInt32(scan.count), words: UInt32(words), minPow3: detector.minPow3,
                                 kRadial: Float(p.kRadial), kBackground: Float(p.kBackground),
                                 tinyRing: Float(1e-20), tinyThresh: Float(p.kBackground * 1e-20))
        let cb = try g.makeCommandBuffer()
        let enc = try g.makeEncoder(cb)
        enc.setComputePipelineState(g.pipe(.prefilterStencil))
        enc.setBuffer(spectra, offset: 0, index: 0); enc.setBuffer(scanB, offset: 0, index: 1)
        enc.bytes(pp, 2); enc.setBuffer(candidates, offset: 0, index: 3)
        enc.dispatchThreads(MTLSize(width: words * 32, height: T, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed)
        let bits = candidates.contents().bindMemory(to: UInt32.self, capacity: T * words)
        var mismatched = 0, peaks = 0
        for ti in 0..<T {
            let pw = UnsafePointer(power + ti * NN)
            let full = try XCTUnwrap(detector.detect(power: pw, candidates: nil))
            let filtered = try XCTUnwrap(detector.detect(power: pw, candidates: UnsafePointer(bits + ti * words)))
            if !Self.samePeaks(full, filtered) { mismatched += 1 }
            peaks += full.count
        }
        XCTAssertGreaterThan(peaks, 100, "網点のあるページなのにピークが見つからない")
        XCTAssertEqual(mismatched, 0)
    }

    // MARK: - 補助

    /// encodeThresholds[1...255] のうち x 以下のものの数(GPU の再符号化と同じ数え方)
    private func thresholdCount(_ x: Float) -> Int {
        var count = 0
        for j in 1...255 where x >= encodeThresholds[j] { count += 1 }
        return count
    }

    /// 大きさと繰り返し回数(大きいものは 1 回にして -Onone のテストでも短く保つ)
    private static let q3Sizes: [(Int, Int, Int)] = [
        (1, 1, 4), (2, 2, 4), (3, 3, 4), (1, 9, 4), (9, 1, 4), (2, 5, 4), (4, 7, 4), (17, 5, 4), (31, 33, 4),
        (128, 128, 4), (129, 131, 4), (333, 517, 2), (640, 480, 1), (1362, 300, 1),
    ]

    private static func gpuContext() throws -> GPUContext {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal が使えない環境") }
        return try GPUContext()
    }

    private static func buffer<T>(_ g: GPUContext, _ values: [T]) throws -> MTLBuffer {
        try XCTUnwrap(values.withUnsafeBytes {
            g.device.makeBuffer(bytes: $0.baseAddress!, length: max(4, $0.count), options: .storageModeShared)
        })
    }

    private static func samePeaks(_ a: [Peak], _ b: [Peak]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.u != y.u || x.v != y.v || x.cu.bitPattern != y.cu.bitPattern || x.cv.bitPattern != y.cv.bitPattern
                || x.amp.bitPattern != y.amp.bitPattern || x.prominence.bitPattern != y.prominence.bitPattern
                || x.r.bitPattern != y.r.bitPattern || x.kind != y.kind
                || x.fundamentalPeriod.bitPattern != y.fundamentalPeriod.bitPattern || x.ortho != y.ortho {
                return false
            }
        }
        return true
    }

    /// 窓の選択を規則どおりに書き写した単一スレッドの実装(配列で素直に書く)
    private static func q3BoundsTranscription(enc v: [UInt8], w: Int, h: Int) -> [UInt8] {
        let k = 3
        var lo1 = v, hi1 = v
        for y in 0..<h {
            for x in 0..<w {
                var a = v[y * w + x], b = a
                for d in 0..<k { let q = v[y * w + min(w - 1, x + d)]; if q < a { a = q }; if q > b { b = q } }
                lo1[y * w + x] = a; hi1[y * w + x] = b
            }
        }
        var blo = lo1, bhi = hi1
        for y in 0..<h {
            for x in 0..<w {
                var a = lo1[y * w + x], b = hi1[y * w + x]
                for d in 0..<k {
                    let yy = min(h - 1, y + d)
                    let q = lo1[yy * w + x], r = hi1[yy * w + x]
                    if q < a { a = q }
                    if r > b { b = r }
                }
                blo[y * w + x] = a; bhi[y * w + x] = b
            }
        }
        var out = [UInt8](repeating: 0, count: 2 * w * h)
        for y in 0..<h {
            for x in 0..<w {
                var bestR = 256, lo: UInt8 = 0, hi: UInt8 = 255
                for oy in 0..<k {
                    for ox in 0..<k {
                        let xx = min(w - 1, max(0, x - ox)), yy = min(h - 1, max(0, y - oy))
                        let j = yy * w + xx
                        let r = Int(bhi[j]) - Int(blo[j])
                        if r < bestR { bestR = r; lo = blo[j]; hi = bhi[j] }
                    }
                }
                out[2 * (y * w + x)] = lo; out[2 * (y * w + x) + 1] = hi
            }
        }
        return out
    }

    /// q3 の検査用の合成画像: 乱数の一様な面、硬い縁、雑音、1 px の線、同値の多い台地
    private static func q3SampleImage(w: Int, h: Int, rng: inout SplitMix64) -> [UInt8] {
        var v = [UInt8](repeating: 0, count: w * h)
        let mode = Int.random(in: 0..<4, using: &rng)
        let base = UInt8.random(in: 0...255, using: &rng)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                switch mode {
                case 0: v[i] = UInt8.random(in: 0...255, using: &rng)
                case 1: v[i] = ((x / 3 + y / 2) % 2 == 0) ? base : base &+ UInt8.random(in: 0...40, using: &rng)
                case 2: v[i] = (x % 5 == 2 || y % 7 == 3) ? 20 : 235
                default:
                    let block = ((x / 4) * 31 + (y / 4) * 17) % 6
                    v[i] = block < 3 ? UInt8(block * 50) : UInt8(min(255, block * 50 + Int.random(in: 0...3, using: &rng)))
                }
            }
        }
        // 一様な矩形と段差を上に重ねる
        for _ in 0..<(w * h / 400 + 1) {
            let rw = Int.random(in: 1...max(1, w / 3), using: &rng), rh = Int.random(in: 1...max(1, h / 3), using: &rng)
            let rx = Int.random(in: 0..<w, using: &rng), ry = Int.random(in: 0..<h, using: &rng)
            let level = UInt8.random(in: 0...255, using: &rng)
            for y in ry..<min(h, ry + rh) { for x in rx..<min(w, rx + rw) { v[y * w + x] = level } }
        }
        return v
    }
}
