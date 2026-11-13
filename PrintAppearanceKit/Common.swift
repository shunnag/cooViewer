import Accelerate
import Foundation

// 網点処理エンジンの共通定義(設計書 §5): タイル寸法、調整値の型、線形化と再符号化の表、窓関数、並列実行。
// 演算は検証済みの実装から式・型(Float / Double)・ループ順を変えずに移したもので、出力のバイトはそれに一致する。
// 出力が変わる変更をしたら PrintAppearance.engineVersion を上げる。

let N = 128            // タイルの一辺(固定。調整値の tile と一致させる)
let NN = N * N
let HOP = 32

/// 26 項目の調整値。構造体の既定値は使わず、Params.printAppearance(Parameters.swift)を使う
struct Params {
    var tile = 128
    var hop = 32
    var rminBins = 3.0
    var kBackground = 20.0
    var kRadial = 4.0
    var radialOffsetBins = 3.0
    var ampMin = 0.006
    var notchFlatBins = 1.0
    var notchSigmaBins = 1.0
    var notchExtentBins = 4.5
    var notchFlatFrac = 0.0
    var notchSigmaFrac = 0.0
    var subMaxOrder = 16
    var subMinProminence = 4.0
    var screenMaxPeriodMM = 1.3
    var aliasMaxOrder = 4
    var aliasTolBins = 1.5
    var gateSigmaPx = 2.0
    var gateHighpassSigmaPx = 1.5
    var floorAtBinRetention = true
    var minNeighbours = 2
    var neighbourTolBins = 1.5
    var bMaskRetention = 0.5
    var bCutoffRetention = 0.5
    var colourLevel = 32
    var colourFrac = 0.005
}

/// A2 判定(連結成分の一貫性)の 15 項目の調整値。構造体の既定値は使わず、A2Params.printAppearance を使う
struct A2Params {
    var fillBlock = 16
    var clusterMinTiles = 1
    var fillCore = 0.0
    var clusterTolBins = 1.5
    var clusterBigTiles = 0
    var partnerAngleMin = 70.0
    var partnerAngleMax = 110.0
    var partnerRadiusTol = 0.15
    var partnerEnabled = false
    var partnerMinFill = 0.0
    var orthoAngleTol = 10.0
    var orthoRadiusTol = 0.08
    var closureOrder = 0
    var closureTolBins = 1.5
    var orthoMinTiles = 0
}

func validateA2Params(_ q: A2Params) throws {
    guard q.fillBlock >= 1 && q.fillBlock <= N else {
        throw PrintAppearanceError.invalidParameters("fillBlock は 1...128 (\(q.fillBlock))")
    }
}

/// このエンジンが実装していない調整値を断る(タイル寸法とホップは固定、エイリアスの付け替えは無し)
func validateParams(_ p: Params) throws {
    guard p.tile == 128 else { throw PrintAppearanceError.invalidParameters("tile は 128 固定 (\(p.tile))") }
    guard p.hop == 32 else { throw PrintAppearanceError.invalidParameters("hop は 32 固定 (\(p.hop))") }
    guard p.aliasMaxOrder == 0 else {
        throw PrintAppearanceError.invalidParameters("エイリアスの付け替えは未実装 (aliasMaxOrder = \(p.aliasMaxOrder))")
    }
    guard p.gateSigmaPx > 0 else { throw PrintAppearanceError.invalidParameters("gateSigmaPx は正") }
}

/// 観察距離とページの高さから、画素の周波数を視角あたりの周期(cpd)へ換算する
struct Geometry {
    let pageHeightMM: Double
    let distanceMM: Double
    let pageHeightPx: Int
    var thetaDeg: Double { 2 * atan(pageHeightMM / (2 * distanceMM)) * 180 / Double.pi }
    func cpd(_ nu: Double) -> Double { nu * Double(pageHeightPx) / thetaDeg }
}

/// 周波数 f(cpd)で見分けられる割合: 8 以下は 1、16 以上は 0、その間は余弦で下げる
func retention(_ f: Double) -> Double {
    if f <= 8 { return 1 }
    if f >= 16 { return 0 }
    return 0.5 * (1 + cos(Double.pi * (f - 8) / 8))
}

/// sRGB の符号値から線形光への表(Double で計算して Float に丸める)
let eotf: [Float] = (0..<256).map { v in
    let c = Double(v) / 255
    return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
}

@inline(__always) func oetf255(_ x: Float) -> Float {
    let l = Double(min(1, max(0, x)))
    return Float(255 * (l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055))
}

@inline(__always) func encodeByte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, oetf255(value).rounded()))) }

/// encodeThresholds[b](b = 1...255)は encodeByte(x) >= b となる最小の Float x。
/// したがって encodeByte(x) は x >= encodeThresholds[b] となる b の個数に等しい(GPU の再符号化はこれを数える)。
/// encodeByte は x について単調非減少なので、Float のビット列上の二分探索で厳密に求まる
let encodeThresholds: [Float] = {
    var t = [Float](repeating: 0, count: 256)
    t[0] = -Float.infinity
    for b in 1...255 {
        // 非負の Float [0, 1.0] を探す: encodeByte(0) == 0、encodeByte(1) == 255
        var lo: UInt32 = 0, hi: UInt32 = Float(1).bitPattern   // 不変条件: f(lo) < b <= f(hi)
        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            if Int(encodeByte(Float(bitPattern: mid))) >= b { hi = mid } else { lo = mid }
        }
        t[b] = Float(bitPattern: hi)
    }
    return t
}()

/// 1 タイルのスペクトルで見つかったピーク
struct Peak {
    var u: Int, v: Int
    var cu: Double, cv: Double
    var rho: Double
    var amp: Double
    var prominence: Double
    var cpd: Double
    var r: Double
    var kind = 0
    var fundamentalPeriod = 0.0
    var ortho = false           // A2: 同じタイルの別のピークが 90 ± orthoAngleTol 度、半径差 orthoRadiusTol 以内にある
    var fill = 0.0              // A2: 位相の揃い方(それを使うピークについてだけ求める。A2Gate.swift)
}

/// 周期的な Hann 窓(Double で求めて Float に丸める)と、その Float の積による 2 次元窓
let hann: [Float] = (0..<128).map { i in Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / 128)) }
let window2D: [Float] = {
    var w = [Float](repeating: 0, count: NN)
    for y in 0..<N { for x in 0..<N { w[y * N + x] = hann[y] * hann[x] } }
    return w
}()

/// 重ね合わせの重みの和は 32x32 の周期模様になる: 画素 (x, y) は覆う 16 タイルの w^2 を
/// タイルの走査順(ty 昇順 = タイル内 y 降順、次に tx 昇順 = タイル内 x 降順)に足したもの
let wsumPattern: [Float] = {
    var pat = [Float](repeating: 0, count: 32 * 32)
    for b in 0..<32 {
        for a in 0..<32 {
            var s: Float = 0
            for ly in [b + 96, b + 64, b + 32, b] {
                for lx in [a + 96, a + 64, a + 32, a] {
                    let w = window2D[ly * N + lx]
                    let w2 = w * w
                    s += w2
                }
            }
            pat[b * 32 + a] = s
        }
    }
    return pat
}()

/// 1 軸のタイル原点(-96 から 32 刻み、ページの外へ 96 px はみ出す位置から始める)
func tileOrigins(_ extent: Int, maxExtent: Int) -> [Int] {
    var origins: [Int] = []
    var o = -(N - HOP)
    while o < maxExtent { origins.append(o); o += HOP }
    return origins.filter { $0 < extent }
}

/// ガウスぼかしの係数(Double で求めて Float に丸め、Float の逐次和で正規化する)
func gaussianTaps(_ sigma: Double) -> [Float] {
    let radius = max(1, Int(ceil(3 * sigma)))
    let size = 2 * radius + 1
    var kernel = [Float](repeating: 0, count: size)
    var sum: Float = 0
    for i in 0..<size {
        let d = Double(i - radius)
        kernel[i] = Float(exp(-d * d / (2 * sigma * sigma)))
        sum += kernel[i]
    }
    for i in 0..<size { kernel[i] /= sum }
    return kernel
}

/// CPU 経路のガウスぼかし(vImage、端は延長)
func gaussianBlurVImage(_ src: UnsafeMutablePointer<Float>, _ dst: UnsafeMutablePointer<Float>,
                        _ tmp: UnsafeMutablePointer<Float>, w: Int, h: Int, sigma: Double) throws {
    let kernel = gaussianTaps(sigma)
    let size = kernel.count
    let rowBytes = w * MemoryLayout<Float>.stride
    var s = vImage_Buffer(data: src, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
    var t = vImage_Buffer(data: tmp, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
    var d = vImage_Buffer(data: dst, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
    var error: vImage_Error = kvImageNoError
    kernel.withUnsafeBufferPointer { kp in
        error = vImageConvolve_PlanarF(&s, &t, nil, 0, 0, kp.baseAddress!, 1, UInt32(size), 0,
                                       vImage_Flags(kvImageEdgeExtend))
        if error == kvImageNoError {
            error = vImageConvolve_PlanarF(&t, &d, nil, 0, 0, kp.baseAddress!, UInt32(size), 1, 0,
                                           vImage_Flags(kvImageEdgeExtend))
        }
    }
    guard error == kvImageNoError else { throw PrintAppearanceError.allocationFailed("vImageConvolve: \(error)") }
}

/// ページ境界に揃えて 0 で埋めた Float の作業面(CPU 経路の後段で使う)。仮想記憶から確保し
/// (vm_allocate の領域は 0 で埋まっている)、手放したらすぐ OS へ返す(設計書 §2.3)
final class FloatPlane {
    let count: Int
    let byteCount: Int
    let ptr: UnsafeMutablePointer<Float>
    init(count: Int) throws {
        self.count = count
        let page = Int(getpagesize())
        byteCount = max(page, ((count * 4) + page - 1) / page * page)
        guard let raw = PageMemory.allocate(byteCount) else {
            throw PrintAppearanceError.allocationFailed("作業面 \(byteCount) バイト")
        }
        ptr = raw.bindMemory(to: Float.self, capacity: byteCount / 4)
    }
    deinit { PageMemory.deallocate(UnsafeMutableRawPointer(ptr), byteCount) }
}

/// concurrentPerform の各反復へ非 Sendable な値(ロック・カウンタ・本体・作業者)を渡す箱。
/// 共有してよい理由: ロックとカウンタはロックの下でだけ触り、本体は反復ごとに別の添字を受け持って
/// その添字の書き込み先だけを書く。箱は concurrentPerform が戻る前に捨てられ、呼び出しの外へ出ない
struct ParallelShared<Value>: @unchecked Sendable {
    let value: Value
}

/// body(i) を i = 0..<count について最大 threads 本で実行する(grain 個ずつ動的に割り当てる)。
/// 各反復は自分の i に対応する書き込み先だけを触ること。結果は並列数に依存しない
func parallelFor(_ count: Int, grain: Int = 1, threads: Int, _ body: (Int) -> Void) {
    if count == 0 { return }
    let blocks = (count + grain - 1) / grain
    let workers = max(1, min(threads, blocks))
    if workers == 1 { for i in 0..<count { body(i) }; return }
    let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    counter.initialize(to: 0)
    var lock = os_unfair_lock()
    withUnsafeMutablePointer(to: &lock) { lp in
        withoutActuallyEscaping(body) { body in
            let shared = ParallelShared(value: (lock: lp, counter: counter, body: body))
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                let lp = shared.value.lock, counter = shared.value.counter, body = shared.value.body
                while true {
                    os_unfair_lock_lock(lp)
                    let b = counter.pointee
                    counter.pointee += 1
                    os_unfair_lock_unlock(lp)
                    if b >= blocks { break }
                    let lo = b * grain, hi = min(count, lo + grain)
                    for i in lo..<hi { body(i) }
                }
            }
        }
    }
    counter.deallocate()
}
