import Accelerate
import Foundation

// CPU の厳密な段(設計書 §5): vDSP によるタイルのスペクトル、ノッチ、重ね合わせ、エネルギーゲートと再符号化。
// タイル単位で並列に走るが、集め方・Float の式・vDSP_fft2d_zip の呼び方が検証済みの実装と同じなので、
// 出力はビット単位で一致する。既定の経路ではパス 1 のスペクトルをここで求め、CPU のみの経路では全段をここで行う。

final class CPUTileWorker {
    let setup: FFTSetup
    let re: UnsafeMutablePointer<Float>
    let im: UnsafeMutablePointer<Float>
    let gain: UnsafeMutablePointer<Float>
    let power: UnsafeMutablePointer<Float>
    var touched: [Int] = []
    /// この作業者の A2 位相揃いの作業領域(初めて使うときに確保する)
    lazy var fillScratch = FillScratch()

    init() throws {
        func alloc() -> UnsafeMutablePointer<Float>? {
            var raw: UnsafeMutableRawPointer?
            guard posix_memalign(&raw, 64, NN * 4) == 0, let raw else { return nil }
            return raw.bindMemory(to: Float.self, capacity: NN)
        }
        guard let setup = vDSP_create_fftsetup(7, FFTRadix(kFFTRadix2)) else {
            throw PrintAppearanceError.allocationFailed("FFT の準備")
        }
        let planes = [alloc(), alloc(), alloc(), alloc()]
        guard let re = planes[0], let im = planes[1], let gain = planes[2], let power = planes[3] else {
            for plane in planes { free(plane) }
            vDSP_destroy_fftsetup(setup)
            throw PrintAppearanceError.allocationFailed("タイルの作業領域")
        }
        self.setup = setup
        self.re = re; self.im = im; self.gain = gain; self.power = power
        for k in 0..<NN { gain[k] = 1 }
        touched.reserveCapacity(NN)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        free(re); free(im); free(gain); free(power)
    }

    @inline(__always) func fft(_ direction: Int32) {
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft2d_zip(setup, &split, 1, 0, 7, 7, FFTDirection(direction))
    }

    /// タイルを鏡像の端処理で集め、Float の逐次和で平均を求め、(v - 平均) * 窓 を順 FFT する。平均を返す
    @discardableResult
    func analyse(_ lin: UnsafePointer<Float>, w W: Int, h H: Int, x0: Int, y0: Int) -> Float {
        var sum: Float = 0
        for y in 0..<N {
            var yy = y0 + y
            if yy < 0 { yy = -yy - 1 } else if yy >= H { yy = 2 * H - yy - 1 }
            let row = lin + yy * W
            let dst = re + y * N
            for x in 0..<N {
                var xx = x0 + x
                if xx < 0 { xx = -xx - 1 } else if xx >= W { xx = 2 * W - xx - 1 }
                let value = row[xx]
                dst[x] = value
                sum += value
            }
        }
        let mean = sum / Float(NN)
        window2D.withUnsafeBufferPointer { wp in
            let w = wp.baseAddress!
            for k in 0..<NN {
                re[k] = (re[k] - mean) * w[k]
                im[k] = 0
            }
        }
        fft(Int32(FFT_FORWARD))
        return mean
    }

    func powerSpectrum(into out: UnsafeMutablePointer<Float>) {
        for k in 0..<NN { out[k] = re[k] * re[k] + im[k] * im[k] }
    }

    /// タイルの変化量(実部、スケール済み)を re に残す。利得の係数は Double で求めるので厳密
    func notchDelta(_ peaks: [Peak], _ p: Params, _ geo: Geometry) -> Bool {
        let active = peaks.filter { $0.r < 1 - 1e-6 }
        guard !active.isEmpty else { return false }
        func shape(_ rho: Double) -> (flat: Double, sigma: Double, extent: Double) {
            let flat = max(p.notchFlatBins, p.notchFlatFrac * rho)
            let sigma = max(p.notchSigmaBins, p.notchSigmaFrac * rho)
            return (flat, sigma, max(p.notchExtentBins, flat + 3 * sigma))
        }
        let rhoLow = active.map(\.rho).min()!
        let guardRadius = rhoLow - shape(rhoLow).extent
        for k in touched { gain[k] = 1 }
        touched.removeAll(keepingCapacity: true)
        for pk in active {
            let sh = shape(pk.rho)
            let e = Int(ceil(sh.extent))
            for sign in [1.0, -1.0] {
                let cu = sign * pk.cu, cv = sign * pk.cv
                let bu = Int(cu.rounded()), bv = Int(cv.rounded())
                for v in (bv - e)...(bv + e) {
                    for u in (bu - e)...(bu + e) {
                        let d = ((Double(u) - cu) * (Double(u) - cu) + (Double(v) - cv) * (Double(v) - cv)).squareRoot()
                        guard d <= sh.extent else { continue }
                        let k = pidx(u, v)
                        let su = k % N < N / 2 ? k % N : k % N - N, sv = k / N < N / 2 ? k / N : k / N - N
                        guard Double(su * su + sv * sv).squareRoot() >= max(1.5, guardRadius) else { continue }
                        let m = d <= sh.flat ? 1.0 : exp(-pow(d - sh.flat, 2) / (2 * sh.sigma * sh.sigma))
                        if gain[k] == 1 { touched.append(k) }
                        gain[k] *= Float(1 - (1 - pk.r) * m)
                    }
                }
            }
        }
        if p.floorAtBinRetention {
            for k in touched {
                let su = k % N < N / 2 ? k % N : k % N - N, sv = k / N < N / 2 ? k / N : k / N - N
                let rb = Float(retention(geo.cpd(Double(su * su + sv * sv).squareRoot() / Double(N))))
                if gain[k] < rb { gain[k] = rb }
            }
        }
        // 差分スペクトル = X * (G - 1)(触れたビンだけ、他は 0)。power を新しい実部の作業域に使う
        let dre = power, dim = UnsafeMutablePointer<Float>.allocate(capacity: NN)
        defer { dim.deallocate() }
        memset(dre, 0, NN * 4)
        memset(dim, 0, NN * 4)
        for k in touched {
            let g = gain[k] - 1
            dre[k] = re[k] * g
            dim[k] = im[k] * g
        }
        memcpy(re, dre, NN * 4)
        memcpy(im, dim, NN * 4)
        fft(Int32(FFT_INVERSE))
        let scale = 1 / Float(NN)
        for k in 0..<NN { re[k] *= scale }
        return true
    }
}

/// CPU 段の作業者の集まり。必要な並列数まで作業者を作り足し(減らさない)、1 回の実行では threads 本までを使う。
/// 作業者ごとの作業領域は同時に走る反復の間で共有しない
final class WorkerPool {
    private(set) var workers: [CPUTileWorker] = []

    init(count: Int) throws { try reserve(count) }

    func reserve(_ count: Int) throws {
        while workers.count < count { workers.append(try CPUTileWorker()) }
    }

    /// body(作業者, i) を i = 0..<count について動的に割り当てて実行する
    func run(_ count: Int, threads: Int, _ body: (CPUTileWorker, Int) -> Void) {
        if count == 0 { return }
        let n = max(1, min(workers.count, threads, count))
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        var lock = os_unfair_lock()
        withUnsafeMutablePointer(to: &lock) { lp in
            withoutActuallyEscaping(body) { body in
                let shared = ParallelShared(value: (lock: lp, counter: counter, workers: workers, body: body))
                DispatchQueue.concurrentPerform(iterations: n) { wi in
                    let lp = shared.value.lock, counter = shared.value.counter, body = shared.value.body
                    let worker = shared.value.workers[wi]
                    while true {
                        os_unfair_lock_lock(lp)
                        let i = counter.pointee
                        counter.pointee += 1
                        os_unfair_lock_unlock(lp)
                        if i >= count { break }
                        body(worker, i)
                    }
                }
            }
        }
    }
}

/// 重ね合わせを画素ごとの集約として行う: 覆う 16 タイルを (ty, tx) の昇順に足し、wsum で割る
/// (タイルごとに足し込む順と同じ和になる)
func overlapAddGatherCPU(delta: UnsafeMutablePointer<Float>, W: Int, H: Int, nx: Int,
                         slotOf: [Int32], changes: UnsafePointer<Float>, threads: Int) {
    slotOf.withUnsafeBufferPointer { sp in
        window2D.withUnsafeBufferPointer { wp in
            wsumPattern.withUnsafeBufferPointer { pp in
                let slot = sp.baseAddress!, win = wp.baseAddress!, pat = pp.baseAddress!
                parallelFor(H, grain: 16, threads: threads) { y in
                    let ty0 = (y + 96) / 32 - 3
                    let row = delta + y * W
                    for x in 0..<W {
                        let tx0 = (x + 96) / 32 - 3
                        var acc: Float = 0
                        for ty in ty0...(ty0 + 3) {
                            let ly = y - (ty * 32 - 96)
                            for tx in tx0...(tx0 + 3) {
                                let s = Int(slot[ty * nx + tx])
                                if s < 0 { continue }
                                let lx = x - (tx * 32 - 96)
                                let k = ly * N + lx
                                acc += changes[s * NN + k] * win[k]
                            }
                        }
                        if acc != 0 { acc /= pat[(y & 31) * 32 + (x & 31)] }
                        row[x] = acc
                    }
                }
            }
        }
    }
}

struct PostCPUResult { var clamped = 0; var q3Touched = 0 }

/// エネルギーゲート + q3 エッジクランプ + 再符号化(厳密)。q3 はゲートの後、範囲外の数えと符号化の前に掛ける。
/// 範囲外の画素数(q3 の後で数える)と q3 が触れた画素数を返す
func gateAndEncodeCPU(lin: UnsafeMutablePointer<Float>, delta: UnsafeMutablePointer<Float>, src: UnsafePointer<UInt8>,
                      out: UnsafeMutablePointer<UInt8>, W: Int, H: Int, p: Params, threads: Int) throws -> PostCPUResult {
    let count = W * H
    let low = try FloatPlane(count: count), tmp = try FloatPlane(count: count), a = try FloatPlane(count: count),
        ex = try FloatPlane(count: count), ed = try FloatPlane(count: count)
    try gaussianBlurVImage(lin, low.ptr, tmp.ptr, w: W, h: H, sigma: p.gateHighpassSigmaPx)
    for i in 0..<count { let h = lin[i] - low.ptr[i]; a.ptr[i] = h * h }
    try gaussianBlurVImage(a.ptr, ex.ptr, tmp.ptr, w: W, h: H, sigma: p.gateSigmaPx)
    for i in 0..<count { a.ptr[i] = delta[i] * delta[i] }
    try gaussianBlurVImage(a.ptr, ed.ptr, tmp.ptr, w: W, h: H, sigma: p.gateSigmaPx)
    var clamp = 0
    for i in 0..<count where delta[i] != 0 {
        let g = ed.ptr[i] > 1e-12 ? min(1, (ex.ptr[i] / ed.ptr[i]).squareRoot()) : 1
        delta[i] *= g
    }
    var res = PostCPUResult()
    res.q3Touched = q3ClampCPU(lin: UnsafePointer(lin), delta: delta, src: src, W: W, H: H, threads: threads)
    memcpy(out, src, count)
    for i in 0..<count where delta[i] != 0 {
        let raw = lin[i] + delta[i]
        if raw < 0 || raw > 1 { clamp += 1 }
        out[i] = encodeByte(raw)
    }
    res.clamped = clamp
    return res
}
