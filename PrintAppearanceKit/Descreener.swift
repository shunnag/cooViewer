import Foundation
import Metal

// 1 ページの網点処理の本体(設計書 §5)。段の順序:
//   線形化 → パス 1(タイルのスペクトルと網点ピークの検出)→ 近傍の一致 → A2 判定 →
//   パス 2(ノッチ、逆 FFT、重ね合わせ)→ 後段(正規化、エネルギーゲート、q3 エッジクランプ、再符号化)。
// 既定の経路はパス 1 のスペクトルを CPU(vDSP)で、候補の絞り込み・パス 2・後段を GPU で行い、
// CPU のみの経路との差は最大 1 階調(パス 2 の GPU FFT が vDSP と丸めが異なるため)。
// インスタンスは再入できない(作業領域とワーカーの作業域を書き換え、出力を outS に残す)。1 度に 1 ページ。
// 段の間に止める位置(PrintAppearanceStopPoint)を置き、止めるときも失敗するときも、積んだコマンドバッファの
// 完了をすべて待ってから戻る(先に積んだバッファが共有の記憶域へ書くため。設計書 §5)。

enum StageDevice { case gpu, cpu }

struct EngineOptions {
    var prefilter = true               // GPU の候補絞り込み(stencil + 環の中央値 + 顕著さ)を CPU の検出の前に行う
    var pass2: StageDevice = .gpu      // ノッチ + 逆 FFT + 重ね合わせ
    var post: StageDevice = .gpu       // 正規化 + エネルギーゲート + q3 + 再符号化
    var chunk = 256                    // GPU の 1 回あたりのタイル数(スペクトルの記憶量を抑える)
    var needsGPU: Bool { prefilter || pass2 == .gpu || post == .gpu }

    /// 既定の経路
    static let automatic = EngineOptions()
    /// GPU を使わない厳密な経路
    static let cpuOnly = EngineOptions(prefilter: false, pass2: .cpu, post: .cpu)
}

struct DescreenResult {
    var tiles = 0, tilesWithPeaks = 0, tilesNotched = 0, dropped = 0, clamped = 0, changed = 0
    var a2: A2Outcome?
    var q3Touched = 0
}

/// 伸びるだけのホストまたは GPU 共有の記憶域。確保したらすぐ触れるので、初回のページフォルトは
/// 処理本体ではなく prepare() で起きる。ホストの記憶域は仮想記憶から確保し、手放したらすぐ OS へ返す
/// (malloc の大きな確保は手放した後もキャッシュに残るため。設計書 §2.3)
final class Store {
    let device: MTLDevice?
    private var mtl: MTLBuffer?
    private var host: UnsafeMutableRawPointer?
    private(set) var length = 0
    init(_ device: MTLDevice?) { self.device = device }
    @discardableResult func ensure(_ bytes: Int) throws -> UnsafeMutableRawPointer {
        if length >= bytes { return raw }
        let page = Int(getpagesize())
        let len = max(page, (bytes + page - 1) / page * page)
        if let d = device {
            guard let b = d.makeBuffer(length: len, options: .storageModeShared) else {
                throw PrintAppearanceError.allocationFailed("GPU バッファ \(len) バイト")
            }
            mtl = b
        } else {
            if let host { PageMemory.deallocate(host, length) }
            host = nil
            length = 0
            guard let made = PageMemory.allocate(len) else {
                throw PrintAppearanceError.allocationFailed("作業域 \(len) バイト")
            }
            host = made
        }
        length = len
        memset(raw, 0, len)
        return raw
    }
    /// ensure が成功した後にだけ参照する
    var buffer: MTLBuffer { mtl! }
    var raw: UnsafeMutableRawPointer { device != nil ? mtl!.contents() : host! }
    func f(_ offsetFloats: Int = 0) -> UnsafeMutablePointer<Float> { raw.bindMemory(to: Float.self, capacity: 1) + offsetFloats }
    func u8() -> UnsafeMutablePointer<UInt8> { raw.bindMemory(to: UInt8.self, capacity: 1) }
    func u32() -> UnsafeMutablePointer<UInt32> { raw.bindMemory(to: UInt32.self, capacity: 1) }
    deinit { if let host { PageMemory.deallocate(host, length) } }
}

final class Descreener {
    let p: Params
    let a2: A2Params
    let opts: EngineOptions
    let gpu: GPUContext?
    let pool: WorkerPool
    let scan: [ScanEntry]
    let words: Int
    let scanBuf: MTLBuffer?
    let srcS, linS, deltaS, exS, aS, tmpS, outS, meansS, actS, zS, psS, candS, ntS, neS, rbS, cntS: Store
    let qS: Store              // q3: 画素ごとの選んだ窓の (lo, hi)(GPU の後段のみ)、1 画素 2 バイト
    /// パス 1 の検出の列と残したかの印、A2 の辺の列、1 ページの間だけ使う配列(EngineScratch.swift。設計書 §2.3)
    let peakTable = PeakTable()
    let edgeLists = FlatLists<UInt64>()
    let arena = ScratchArena()
    var q3OnGPU: Bool { opts.post == .gpu && gpu != nil }
    /// 実行中のページの CPU 段の並列数
    private var threads = 1
    /// この run で積んだコマンドバッファ。run のどの出口でも drain() で完了を待つ
    private var committed: [MTLCommandBuffer] = []

    init(params: Params, a2: A2Params, options: EngineOptions, gpu: GPUContext?, threads: Int) throws {
        try validateParams(params)
        try validateA2Params(a2)
        if options.needsGPU && gpu == nil {
            throw PrintAppearanceError.gpuUnavailable("GPU の段を選んだのに GPU が無い")
        }
        p = params
        self.a2 = a2
        opts = options
        self.gpu = gpu
        pool = try WorkerPool(count: max(1, threads))
        scan = makeScan(params)
        words = (scan.count + 31) / 32
        let dev = gpu?.device
        if let dev {
            var packed = [SIMD4<Int32>]()
            for e in scan { packed.append(SIMD4(e.u, e.v, e.inner, e.outer)) }
            guard let b = packed.withUnsafeBytes({
                dev.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }) else {
                throw PrintAppearanceError.allocationFailed("走査表のバッファ")
            }
            scanBuf = b
        } else { scanBuf = nil }
        srcS = Store(dev); linS = Store(dev); deltaS = Store(dev); exS = Store(dev); aS = Store(dev); tmpS = Store(dev)
        outS = Store(dev); meansS = Store(dev); actS = Store(dev); zS = Store(dev); psS = Store(dev)
        candS = Store(dev); ntS = Store(dev); neS = Store(dev); rbS = Store(dev); cntS = Store(dev)
        qS = Store(dev)
    }

    private func grid(_ W: Int, _ H: Int) -> (nx: Int, ny: Int) {
        (tileOrigins(W, maxExtent: max(W, H)).count, tileOrigins(H, maxExtent: max(W, H)).count)
    }

    /// この大きさのページに要る記憶域を確保して触れておく(伸びるだけ)。それまでより大きいページでだけ仕事をする
    func prepare(W: Int, H: Int) throws {
        let count = W * H
        let (nx, ny) = grid(W, H)
        let T = nx * ny
        let K = min(opts.chunk, T)
        try srcS.ensure(count); try linS.ensure(count * 4); try deltaS.ensure(count * 4); try exS.ensure(count * 4)
        try aS.ensure(count * 4); try tmpS.ensure(count * 4); try outS.ensure(count); try meansS.ensure(T * 4)
        try actS.ensure(T * 4); try zS.ensure(K * 8192 * 8)
        try psS.ensure(max(2 * K * NN * 4, K * 8320 * 8)); try candS.ensure(2 * K * words * 4)
        try ntS.ensure(T * 16); try rbS.ensure(8193 * 4); try cntS.ensure(16)
        if q3OnGPU { try qS.ensure(count * 2) }
    }

    /// 直前の run の出力(W * H バイト)。次の run まで有効
    var output: UnsafePointer<UInt8> { UnsafePointer(outS.u8()) }

    /// 確保済みの作業域のバイト数(記憶域と作業者のタイル面。稼働状況の表示用の概算)
    var workingBytes: Int {
        let stores = [srcS, linS, deltaS, exS, aS, tmpS, outS, meansS, actS, zS, psS, candS, ntS, neS, rbS, cntS, qS]
        return stores.reduce(0) { $0 + $1.length } + pool.workers.count * 4 * NN * 4
            + peakTable.byteCount + edgeLists.byteCount + arena.byteCount
    }

    private func commit(_ cb: MTLCommandBuffer) {
        cb.commit()
        committed.append(cb)
    }

    /// 積んだコマンドバッファの完了をすべて待つ。正常な出口ではもう終わっているので待たない
    private func drain() {
        for cb in committed { cb.waitUntilCompleted() }
        committed.removeAll()
    }

    /// stop は各停止位置で呼ばれ、止めるときは例外を投げる。呼ぶのは run を呼んだスレッドだけ
    /// (並列の反復の中からは呼ばない)
    func run(src: UnsafePointer<UInt8>, W: Int, H: Int, geo: Geometry, threads requested: Int,
             stop: (PrintAppearanceStopPoint) throws -> Void = { _ in }) throws -> DescreenResult {
        guard W >= N && H >= N else {
            throw PrintAppearanceError.unsupportedPage("辺が 128 px 未満 (\(W)x\(H))")
        }
        defer { drain() }
        try stop(.beforeRun)
        let threads = max(1, requested)
        self.threads = threads
        try pool.reserve(threads)
        var res = DescreenResult()
        let count = W * H
        let (nx, ny) = grid(W, H)
        let T = nx * ny
        let K = min(opts.chunk, T)
        res.tiles = T
        try prepare(W: W, H: H)   // それまでより大きいページでなければ何もしない
        arena.rewind()
        let detector = DetectorA(params: p, geometry: geo, scan: scan)
        detector.ortho = (a2.orthoRadiusTol, a2.orthoAngleTol)
        var pg = PageInfo(W: Int32(W), H: Int32(H), nx: Int32(nx), ny: Int32(ny))
        memcpy(srcS.raw, src, count)
        let lin = linS.f()
        // ---- 段 0: 線形化は CPU で行う(パス 1 のスペクトルと A2 の位相揃いが CPU で lin を読む。GPU と同じ表で同じ値)
        eotf.withUnsafeBufferPointer { e in
            let ep = e.baseAddress!
            parallelFor(H, grain: 64, threads: threads) { y in
                let o = lin + y * W, s = src + y * W
                for x in 0..<W { o[x] = ep[Int(s[x])] }
            }
        }
        // ---- パス 1: スペクトルと検出
        let peaks = try pass1(detector: detector, W: W, H: H, nx: nx, T: T, K: K, stop: stop)
        try stop(.afterPass1)
        // ---- GPU の前段(lin と src だけに依存する)。パス 1 の後に積み、近傍の一致・A2・パス 2 の準備で GPU が
        // 空いている間に走らせる(パス 1 の前に積むと、パス 1 の最初のチャンクの絞り込みが同じキューで前段の後ろに
        // 並んで待つ)。止める位置の後に積むので、ここで止めるときは前段の完了を待たない
        try commitFrontWork(count: count, T: T, pg: &pg)
        // ---- 近傍の一致(タイルをまたぐ唯一の同期点)。残したピークは peaks の印で表す
        res.dropped = NeighbourGateA(p: p, threads: threads).gate(peaks, nx: nx, ny: ny)
        try stop(.afterNeighbourGate)
        // ---- A2: 連結成分の一貫性(CPU、Double)を残った列に対して行う
        res.a2 = try A2Gate(a2).run(peaks: peaks, nx: nx, ny: ny, lin: UnsafePointer(lin), W: W, H: H, pool: pool,
                                    arena: arena, edges: edgeLists, threads: threads,
                                    stop: { try stop(.betweenFillRounds) })
        let activeSlots = try arena.take(Int.self, T)
        var activeCount = 0
        for ti in 0..<T {
            var any = false, notched = false
            for pk in peaks.kept(ti) {
                any = true
                if pk.r < 1 - 1e-6 { notched = true; break }
            }
            if !any { continue }
            res.tilesWithPeaks += 1
            if notched { activeSlots[activeCount] = ti; activeCount += 1 }
        }
        let active = UnsafeBufferPointer(rebasing: activeSlots[0..<activeCount])
        res.tilesNotched = active.count
        // 出力を作る段(最後のコマンドバッファ)に入る前の最後の停止位置
        try stop(.beforeOutput)
        // ---- パス 2 + 後段
        let delta = deltaS.f()
        if opts.pass2 == .gpu, let g = gpu {
            let cb = try g.makeCommandBuffer()
            try encodePass2(cb, g, active: active, kept: peaks, geo: geo, W: W, H: H, nx: nx, K: K, pg: &pg)
            if opts.post == .gpu {
                try encodePost(cb, g, count: count, pg: &pg)
                commit(cb); cb.waitUntilCompleted()
                try checkStatus(cb)
            } else {
                commit(cb); cb.waitUntilCompleted()
                try checkStatus(cb)
                wsumPattern.withUnsafeBufferPointer { pat in
                    for y in 0..<H { for x in 0..<W where delta[y * W + x] != 0 { delta[y * W + x] /= pat[(y & 31) * 32 + (x & 31)] } }
                }
                let pr = try gateAndEncodeCPU(lin: lin, delta: delta, src: src, out: outS.u8(), W: W, H: H, p: p,
                                              threads: threads)
                res.clamped = pr.clamped
                res.q3Touched = pr.q3Touched
            }
        } else {
            // 厳密な CPU のパス 2(解析し直し、Double のノッチ、vDSP の逆変換、タイル走査順の集約による重ね合わせ)
            var slotOf = [Int32](repeating: -1, count: T)
            let changes = try FloatPlane(count: max(1, active.count) * NN)
            for (s, ti) in active.enumerated() { slotOf[ti] = Int32(s) }
            pool.run(active.count, threads: threads) { w, s in
                let ti = active[s]
                w.analyse(lin, w: W, h: H, x0: -96 + 32 * (ti % nx), y0: -96 + 32 * (ti / nx))
                // 残した列を作業者の配列へ写して渡す(タイルごとに配列を確保しない)
                w.peakList.removeAll(keepingCapacity: true)
                for pk in peaks.kept(ti) { w.peakList.append(pk) }
                _ = w.notchDelta(w.peakList, p, geo)
                memcpy(changes.ptr + s * NN, w.re, NN * 4)
            }
            overlapAddGatherCPU(delta: delta, W: W, H: H, nx: nx, slotOf: slotOf, changes: changes.ptr, threads: threads)
            if opts.post == .gpu, let g = gpu {
                let cb = try g.makeCommandBuffer()
                try encodePost(cb, g, count: count, pg: &pg, divide: false)
                commit(cb); cb.waitUntilCompleted()
                try checkStatus(cb)
            } else {
                let pr = try gateAndEncodeCPU(lin: lin, delta: delta, src: src, out: outS.u8(), W: W, H: H, p: p,
                                              threads: threads)
                res.clamped = pr.clamped
                res.q3Touched = pr.q3Touched
            }
        }
        // 前段(タイル平均・delta の 0 埋め・ゲートの高域エネルギー・q3 の窓)の結果も出力に入るので、積んだ
        // すべてのコマンドバッファの成否を確かめる(失敗は GPU の失敗として CPU でやり直させる)。
        // 出力の段が同じキューで後に走ったので、どれももう終わっている
        for cb in committed {
            cb.waitUntilCompleted()
            try checkStatus(cb)
        }
        if opts.post == .gpu {
            let c = cntS.u32()
            res.clamped = Int(c[0]); res.changed = Int(c[1]); res.q3Touched = Int(c[2])
        } else {
            let o = outS.u8()
            var ch = 0
            for i in 0..<count where o[i] != src[i] { ch += 1 }
            res.changed = ch
        }
        return res
    }

    func checkStatus(_ cb: MTLCommandBuffer) throws {
        if cb.status != .completed {
            throw PrintAppearanceError.gpuFailed("コマンドバッファが失敗: \(String(describing: cb.error))")
        }
    }

    /// GPU の前段を積む。パス 2 が GPU のとき: タイル平均(colFwd が引く)と delta の 0 埋め(colInvScatter が
    /// 足し込む先。出力の段から外して GPU が空いている間に済ませる)。後段が GPU のとき: ゲートの高域エネルギーと、
    /// 別のコマンドバッファで q3 の窓の選択。どれも lin と src だけに依存し、同じキューで後に積む出力の段が読む。
    /// 例外を投げうる呼び出しはエンコードの外に置く(積み終えたものは run の出口の drain() が待つ)
    private func commitFrontWork(count: Int, T: Int, pg: inout PageInfo) throws {
        guard let g = gpu, opts.pass2 == .gpu || opts.post == .gpu else { return }
        let cb = try g.makeCommandBuffer()
        let enc = try g.makeEncoder(cb)
        if opts.pass2 == .gpu {
            enc.set([linS.buffer]); enc.bytes(pg, 1); enc.setBuffer(meansS.buffer, offset: 0, index: 2)
            enc.grid1D(g.pipe(.tileMeans), T)
        }
        if opts.post == .gpu {
            encodeBlur(enc, g, src: linS.buffer, dst: aS.buffer, sigma: p.gateHighpassSigmaPx, pg: &pg)
            enc.set([linS.buffer, aS.buffer]); enc.bytes(UInt32(count), 2)
            enc.grid1D(g.pipe(.highpassSq), count)
            encodeBlur(enc, g, src: aS.buffer, dst: exS.buffer, sigma: p.gateSigmaPx, pg: &pg)
        }
        if opts.pass2 == .gpu {
            enc.setBuffer(deltaS.buffer, offset: 0, index: 0); enc.bytes(UInt32(count), 1)
            enc.grid1D(g.pipe(.fillZero), count)
        }
        enc.endEncoding()
        commit(cb)
        if q3OnGPU {
            let cbQ = try g.makeCommandBuffer()
            let encQ = try g.makeEncoder(cbQ)
            encQ.set([srcS.buffer, qS.buffer, g.q3EncBuf]); encQ.bytes(pg, 3)
            encQ.grid2D(g.pipe(.q3Window), Int(pg.W), Int(pg.H))
            encQ.endEncoding()
            commit(cbQ)
        }
    }

    private func encodeBlur(_ enc: MTLComputeCommandEncoder, _ g: GPUContext, src: MTLBuffer, dst: MTLBuffer, sigma: Double,
                            pg: inout PageInfo) {
        let taps = gaussianTaps(sigma)
        let r = (taps.count - 1) / 2
        taps.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        enc.setBuffer(src, offset: 0, index: 0); enc.setBuffer(tmpS.buffer, offset: 0, index: 1)
        enc.bytes(SIMD2<Int32>(Int32(r), 0), 3); enc.bytes(pg, 4)
        enc.grid2D(g.pipe(.blur), Int(pg.W), Int(pg.H))
        enc.setBuffer(tmpS.buffer, offset: 0, index: 0); enc.setBuffer(dst, offset: 0, index: 1)
        enc.bytes(SIMD2<Int32>(Int32(r), 1), 3)
        enc.grid2D(g.pipe(.blur), Int(pg.W), Int(pg.H))
    }

    // MARK: パス 1

    /// 検出の列は peakTable に書く(作業者の配列で検出し、タイルの欄へ写す。断ったタイルの列は空)
    private func pass1(detector: DetectorA, W: Int, H: Int, nx: Int, T: Int, K: Int,
                       stop: (PrintAppearanceStopPoint) throws -> Void) throws -> PeakLists {
        let lin = linS.f()
        let threads = self.threads
        let table = peakTable
        try table.begin(tiles: T)
        if !opts.prefilter {
            // CPU のみ: 各作業者がタイルを解析してその場で検出する(スペクトルを保持しない)。
            // 止められるよう K タイルずつに分ける。各タイルは自分の欄だけを書くので、分け方で結果は変わらない
            var start = 0
            while start < T {
                if start > 0 { try stop(.betweenPass1Chunks) }
                let first = start, n = min(K, T - start)
                pool.run(n, threads: threads) { w, i in
                    let ti = first + i
                    w.analyse(lin, w: W, h: H, x0: -96 + 32 * (ti % nx), y0: -96 + 32 * (ti / nx))
                    w.powerSpectrum(into: w.power)
                    // 候補を渡さない全走査は断らない
                    if detector.detect(power: w.power, candidates: nil, into: &w.peakList) {
                        table.put(tile: ti, w.peakList)
                    }
                }
                start += n
            }
            return try table.finishPass1()
        }
        guard let g = gpu else { throw PrintAppearanceError.gpuUnavailable("候補の絞り込みに GPU が要る") }
        let minPow3 = detector.minPow3
        let pp = PrefilterParams(scanCount: UInt32(scan.count), words: UInt32(words), minPow3: minPow3,
                                 kRadial: Float(p.kRadial), kBackground: Float(p.kBackground),
                                 tinyRing: Float(1e-20), tinyThresh: Float(p.kBackground * 1e-20))
        guard Double(Float(p.kRadial)) == p.kRadial, Double(Float(p.kBackground)) == p.kBackground else {
            throw PrintAppearanceError.invalidParameters("候補の絞り込みには kRadial と kBackground が Float で正確に表せる必要がある")
        }
        var pending: (cb: MTLCommandBuffer, start: Int, n: Int, parity: Int)? = nil
        func detectChunk(_ c: (cb: MTLCommandBuffer, start: Int, n: Int, parity: Int)) throws {
            c.cb.waitUntilCompleted()
            try checkStatus(c.cb)
            let P = psS.f(c.parity * K * NN)
            let surv = candS.u32() + c.parity * K * words
            let refused = UnsafeMutablePointer<Bool>.allocate(capacity: c.n)
            defer { refused.deallocate() }
            pool.run(c.n, threads: threads) { w, i in
                let pw = UnsafePointer(P + i * NN)
                let ok = detector.detect(power: pw, candidates: UnsafePointer(surv + i * words), into: &w.peakList)
                if ok { table.put(tile: c.start + i, w.peakList) }
                refused[i] = !ok
            }
            for i in 0..<c.n where refused[i] {
                throw PrintAppearanceError.gpuFailed("候補の絞り込みが顕著さの条件を満たさないビンを通した")
            }
        }
        // チャンクごとに CPU がスペクトルを書き、GPU が絞り込む。2 面を交互に使い、次のチャンクの解析と
        // 前のチャンクの検出を重ねる
        var start = 0, ci = 0
        while start < T {
            if start > 0 { try stop(.betweenPass1Chunks) }
            let n = min(K, T - start), parity = ci & 1
            let pOff = parity * K * NN * 4
            let base = psS.f(parity * K * NN)
            pool.run(n, threads: threads) { w, i in
                let ti = start + i
                w.analyse(lin, w: W, h: H, x0: -96 + 32 * (ti % nx), y0: -96 + 32 * (ti / nx))
                w.powerSpectrum(into: base + i * NN)
            }
            let cb = try g.makeCommandBuffer()
            let enc = try g.makeEncoder(cb)
            let wOff = parity * K * words * 4
            enc.setComputePipelineState(g.pipe(.prefilterStencil))
            enc.setBuffer(psS.buffer, offset: pOff, index: 0); enc.setBuffer(scanBuf, offset: 0, index: 1)
            enc.bytes(pp, 2); enc.setBuffer(candS.buffer, offset: wOff, index: 3)
            enc.dispatchThreads(MTLSize(width: words * 32, height: n, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
            commit(cb)
            if let pd = pending { try detectChunk(pd) }
            pending = (cb, start, n, parity)
            start += n
            ci += 1
        }
        if let pd = pending { try detectChunk(pd) }
        return try table.finishPass1()
    }

    // MARK: パス 2(GPU)

    private func encodePass2(_ cb: MTLCommandBuffer, _ g: GPUContext, active: UnsafeBufferPointer<Int>, kept: PeakLists,
                             geo: Geometry, W: Int, H: Int, nx: Int, K: Int, pg: inout PageInfo) throws {
        // タイルの順: 位相 (tx mod 4, ty mod 4) を主キーにして、1 回のディスパッチに重なるタイルが入らないようにする
        // (比較は全順序なので、並べ替えの方法によらず同じ並びになる。並びは 1 ページの間の作業域に置く)
        var orderSlots = try arena.take(Int.self, active.count)
        _ = orderSlots.initialize(fromContentsOf: active)
        orderSlots.sort { a, b in
            let pa = ((a / nx) & 3) << 2 | ((a % nx) & 3), pb = ((b / nx) & 3) << 2 | ((b % nx) & 3)
            return pa != pb ? pa < pb : a < b
        }
        let order = UnsafeBufferPointer(orderSlots)
        let A = order.count
        let act = actS.u32()
        for (i, ti) in order.enumerated() { act[i] = UInt32(ti) }
        // タイルごとのノッチのパラメータは Double で求め、Float で渡す
        let nt = try ntS.ensure(max(1, A) * 16).bindMemory(to: NotchTile.self, capacity: max(1, A))
        func shape(_ rho: Double) -> (flat: Double, sigma: Double, extent: Double) {
            let flat = max(p.notchFlatBins, p.notchFlatFrac * rho)
            let sigma = max(p.notchSigmaBins, p.notchSigmaFrac * rho)
            return (flat, sigma, max(p.notchExtentBins, flat + 3 * sigma))
        }
        // ノッチの項目は neS へ直接書く(配列を append で伸ばすと 11 MP のページで 32 MB とその倍々の列を
        // malloc に残すため。設計書 §2.3)。先に数を数え、ノッチの範囲が GPU の集約に収まるかもここで確かめる
        var entryCount = 0
        for ti in order {
            for pk in kept.kept(ti) where pk.r < 1 - 1e-6 {
                let sh = shape(pk.rho)
                let e = Int(ceil(sh.extent))
                guard 2 * e + 1 <= 127 else {
                    throw PrintAppearanceError.unsupportedPage("ノッチの範囲 \(sh.extent) が GPU の集約に収まらない")
                }
                entryCount += 2
            }
        }
        let entries = try neS.ensure(max(1, entryCount) * 48).bindMemory(to: NotchEntry.self, capacity: max(1, entryCount))
        var written = 0
        for (i, ti) in order.enumerated() {
            // 列の最小の半径(Sequence.min と同じく、先頭から小さいものに置き換える)
            var actCount = 0, rhoLow = 0.0
            for pk in kept.kept(ti) where pk.r < 1 - 1e-6 {
                if actCount == 0 || pk.rho < rhoLow { rhoLow = pk.rho }
                actCount += 1
            }
            precondition(actCount > 0)
            let guardR = max(1.5, rhoLow - shape(rhoLow).extent)
            var nGuard = max(0, Int((guardR * guardR).rounded(.down)) - 2)
            while Double(nGuard).squareRoot() < guardR { nGuard += 1 }
            nt[i] = NotchTile(entryStart: UInt32(written), entryCount: UInt32(actCount * 2), nGuard: Int32(nGuard))
            for pk in kept.kept(ti) where pk.r < 1 - 1e-6 {
                let sh = shape(pk.rho)
                let e = Int(ceil(sh.extent))
                for sign in [1.0, -1.0] {
                    let cx = sign * pk.cu, cy = sign * pk.cv
                    let cxh = Float(cx), cyh = Float(cy)
                    entries[written] = NotchEntry(cxh: cxh, cxl: Float(cx - Double(cxh)), cyh: cyh, cyl: Float(cy - Double(cyh)),
                                                  bu: Int32(Int(cx.rounded())), bv: Int32(Int(cy.rounded())), e: Int32(e),
                                                  flat: Float(sh.flat), extent: Float(sh.extent),
                                                  inv2s2: Float(1 / (2 * sh.sigma * sh.sigma)), omr: Float(1 - pk.r))
                    written += 1
                }
            }
        }
        let rb = rbS.f()
        for n2 in 0...8192 {
            rb[n2] = p.floorAtBinRetention ? Float(retention(geo.cpd(Double(n2).squareRoot() / Double(N)))) : 0
        }
        // delta の 0 埋めは前段で済ませてある(commitFrontWork。同じキューで先に走る)
        let enc = try g.makeEncoder(cb)
        var start = 0
        while start < A {
            let n = min(K, A - start)
            enc.setComputePipelineState(g.pipe(.colFwd))
            enc.set([linS.buffer]); enc.bytes(pg, 1); enc.setBuffer(actS.buffer, offset: 0, index: 2)
            enc.bytes(UInt32(start), 3); enc.setBuffer(meansS.buffer, offset: 0, index: 4)
            enc.setBuffer(g.hannBuf, offset: 0, index: 5); enc.setBuffer(g.twBuf, offset: 0, index: 6)
            enc.setBuffer(zS.buffer, offset: 0, index: 7)
            enc.dispatchThreadgroups(MTLSize(width: 4, height: n, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))
            enc.setComputePipelineState(g.pipe(.rowNotch))
            enc.setBuffer(zS.buffer, offset: 0, index: 0); enc.setBuffer(g.twBuf, offset: 0, index: 1)
            enc.setBuffer(psS.buffer, offset: 0, index: 2); enc.setBuffer(ntS.buffer, offset: 0, index: 3)
            enc.bytes(UInt32(start), 4); enc.setBuffer(neS.buffer, offset: 0, index: 5)
            enc.setBuffer(rbS.buffer, offset: 0, index: 6)
            enc.dispatchThreadgroups(MTLSize(width: 5, height: n, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 416, height: 1, depth: 1))
            enc.setComputePipelineState(g.pipe(.colInvScatter))
            enc.setBuffer(psS.buffer, offset: 0, index: 0); enc.setBuffer(g.twBuf, offset: 0, index: 1)
            enc.bytes(pg, 2); enc.setBuffer(actS.buffer, offset: 0, index: 3)
            enc.setBuffer(g.hannBuf, offset: 0, index: 5); enc.setBuffer(deltaS.buffer, offset: 0, index: 6)
            var a = 0
            while a < n {
                let ti = order[start + a]
                let phase = ((ti / nx) & 3) << 2 | ((ti % nx) & 3)
                var b = a + 1
                while b < n, ((order[start + b] / nx) & 3) << 2 | ((order[start + b] % nx) & 3) == phase { b += 1 }
                enc.bytes(SIMD2<UInt32>(UInt32(start + a), UInt32(a)), 4)
                enc.dispatchThreadgroups(MTLSize(width: 4, height: b - a, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 512, height: 1, depth: 1))
                a = b
            }
            start += n
        }
        enc.endEncoding()
    }

    // MARK: 後段(GPU)

    private func encodePost(_ cb: MTLCommandBuffer, _ g: GPUContext, count: Int, pg: inout PageInfo,
                            divide: Bool = true) throws {
        cntS.u32()[0] = 0; cntS.u32()[1] = 0; cntS.u32()[2] = 0
        let enc = try g.makeEncoder(cb)
        enc.setBuffer(deltaS.buffer, offset: 0, index: 0); enc.setBuffer(aS.buffer, offset: 0, index: 1)
        enc.setBuffer(divide ? g.wsumBuf : nil, offset: 0, index: 2); enc.bytes(pg, 3)
        if !divide {
            // CPU の集約で正規化済み: 1 で割る
            let ones = [Float](repeating: 1, count: 1024)
            ones.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        }
        enc.grid2D(g.pipe(.normalise), Int(pg.W), Int(pg.H))
        encodeBlur(enc, g, src: aS.buffer, dst: aS.buffer, sigma: p.gateSigmaPx, pg: &pg)
        enc.setBuffer(linS.buffer, offset: 0, index: 0); enc.setBuffer(deltaS.buffer, offset: 0, index: 1)
        enc.setBuffer(exS.buffer, offset: 0, index: 2); enc.setBuffer(aS.buffer, offset: 0, index: 3)
        enc.setBuffer(srcS.buffer, offset: 0, index: 4); enc.setBuffer(outS.buffer, offset: 0, index: 5)
        enc.setBuffer(g.thrBuf, offset: 0, index: 6); enc.setBuffer(cntS.buffer, offset: 0, index: 7)
        enc.bytes(UInt32(count), 8)
        // ゲート + q3 + 符号化
        enc.setBuffer(qS.buffer, offset: 0, index: 9); enc.setBuffer(g.eotfBuf, offset: 0, index: 10)
        enc.grid1D(g.pipe(.gateEncodeQ3), count)
        enc.endEncoding()
    }
}
