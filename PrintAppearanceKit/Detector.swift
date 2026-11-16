import Foundation

// タイルごとの網点ピーク検出と、タイルをまたぐ近傍の一致による絞り込み(設計書 §5)。
//
// 検出器は 1 タイルのパワースペクトル(128x128 の Float、v が外側: ビン (u, v) は ((v & 127) << 7) | (u & 127)、
// vDSP_fft2d_zip の並び)だけを見て、走査順のピークの列を返す。近傍の一致は全タイルの列が揃ってから行う。
// スペクトルを作る側(CPU の vDSP)は検出の中身を知らない。GPU の候補絞り込みのビット列を受け取ったときは
// その候補だけを調べ、受け取らないときは全ビンを調べる(どちらも同じ結果になる)。

@inline(__always) func pidx(_ u: Int, _ v: Int) -> Int { ((v & 127) << 7) | (u & 127) }

protocol TileDetector: AnyObject {
    /// パス 1 の検出。candidates があれば、走査順(語 s/32 のビット s)のビット列で、ビンごとの絞り込み
    /// (pk > 0、3x3 の厳密な極大、s3 >= minPow3、径方向の孤立、顕著さ)を通ったものを表す。
    /// nil を返すのは、候補に顕著さの条件を満たさないビンが含まれていたとき(GPU の結果が CPU の判定と食い違った)
    func detect(power: UnsafePointer<Float>, candidates: UnsafePointer<UInt32>?) -> [Peak]?
}

protocol TileGate {
    /// 絞り込み前のパス 1 の列に対するタイル間の判定。残すピークに印を付け(PeakLists.keep)、
    /// 落としたピークの数を返す
    func gate(_ peaks: PeakLists, nx: Int, ny: Int) -> Int
}

/// 半平面の走査の 1 ビン(v = 0...63 が外側、u = -63...63 が内側。v = 0 かつ u <= 0 と、半径 rminBins 未満は除く)。
/// 径方向の孤立を調べる内外の点は Double で前もって求めておく
struct ScanEntry {
    var u: Int32, v: Int32
    var inner: Int32     // 内側の点の pidx(常に使う)
    var outer: Int32     // 外側の点の pidx。|.| <= 63 の外に出るときは -1
}

func makeScan(_ p: Params) -> [ScanEntry] {
    var out: [ScanEntry] = []
    let half = N / 2
    for v in 0..<half {
        for u in (-(half - 1))...(half - 1) {
            if v == 0 && u <= 0 { continue }
            let rr = Double(u * u + v * v).squareRoot()
            guard rr >= p.rminBins else { continue }
            let ui = Double(u) * (rr - p.radialOffsetBins) / rr, vi = Double(v) * (rr - p.radialOffsetBins) / rr
            let uo = Double(u) * (rr + p.radialOffsetBins) / rr, vo = Double(v) * (rr + p.radialOffsetBins) / rr
            let inner = pidx(Int(ui.rounded()), Int(vi.rounded()))
            var outer = -1
            if abs(uo.rounded()) <= Double(half - 1) && abs(vo.rounded()) <= Double(half - 1) {
                outer = pidx(Int(uo.rounded()), Int(vo.rounded()))
            }
            out.append(ScanEntry(u: Int32(u), v: Int32(v), inner: Int32(inner), outer: Int32(outer)))
        }
    }
    return out
}

/// (u, v) を囲むチェビシェフ距離 3..4 の環 56 値の上側の中央値(昇順 28 番目)。値だけが要るので、
/// 並べ替えの代わりに厳密な選択で同じ値を得る
@inline(__always) func ringMedianValue(_ power: UnsafePointer<Float>, _ u: Int, _ v: Int,
                                       _ scratch: UnsafeMutablePointer<Float>) -> Float {
    var k = 0
    for dv in -4...4 {
        let row = ((v + dv) & 127) << 7
        if abs(dv) >= 3 {
            for du in -4...4 { scratch[k] = power[row | ((u + du) & 127)]; k += 1 }
        } else {
            scratch[k] = power[row | ((u - 4) & 127)]; scratch[k + 1] = power[row | ((u - 3) & 127)]
            scratch[k + 2] = power[row | ((u + 3) & 127)]; scratch[k + 3] = power[row | ((u + 4) & 127)]
            k += 4
        }
    }
    // 56 個のうち添字 28 のクイックセレクト(値のみ)
    var lo = 0, hi = 55
    let target = 28
    while hi > lo {
        let pivot = scratch[(lo + hi) >> 1]
        var i = lo, j = hi
        while i <= j {
            while scratch[i] < pivot { i += 1 }
            while scratch[j] > pivot { j -= 1 }
            if i <= j { let t = scratch[i]; scratch[i] = scratch[j]; scratch[j] = t; i += 1; j -= 1 }
        }
        if target <= j { hi = j } else if target >= i { lo = i } else { break }
    }
    return scratch[target]
}

/// 網点ピークの検出器(エイリアスの付け替えは無し)。
final class DetectorA: TileDetector {
    let p: Params
    let geo: Geometry
    let scan: [ScanEntry]
    let ampScale: Double
    let minPow3: Float
    let mmPerPx: Double
    /// A2 の直交フラグを付ける条件(半径の許容比、角度の許容度)。nil なら付けない
    var ortho: (radiusTol: Double, angleTol: Double)?

    convenience init(params: Params, geometry: Geometry) {
        self.init(params: params, geometry: geometry, scan: makeScan(params))
    }

    /// scan は makeScan(params) の結果(エンジンが作ったものを使い回し、ページごとに作らない。設計書 §2.3)
    init(params: Params, geometry: Geometry, scan: [ScanEntry]) {
        p = params
        geo = geometry
        self.scan = scan
        ampScale = 16.0 / (3.0 * Double(NN))
        minPow3 = Float(pow(Double(params.ampMin) / ampScale, 2) * 0.25)
        mmPerPx = geometry.pageHeightMM / Double(geometry.pageHeightPx)
    }

    func detect(power: UnsafePointer<Float>, candidates: UnsafePointer<UInt32>?) -> [Peak]? {
        var peaks: [Peak] = []
        return detect(power: power, candidates: candidates, into: &peaks) ? peaks : nil
    }

    /// detect と同じ検出を、呼び出し側が使い回す配列 peaks へ書く(中身を捨てて容量は残す。
    /// タイルごとに配列を確保しないため。設計書 §2.3)。断ったときは偽を返す(peaks の中身は使わない)
    func detect(power: UnsafePointer<Float>, candidates: UnsafePointer<UInt32>?, into peaks: inout [Peak]) -> Bool {
        peaks.removeAll(keepingCapacity: true)
        var refused = false
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 64) { sb in
            let scratch = sb.baseAddress!
            if let cand = candidates {
                let words = (scan.count + 31) / 32
                candidateWords: for wi in 0..<words {
                    var bits = cand[wi]
                    while bits != 0 {
                        let b = bits.trailingZeroBitCount
                        bits &= bits - 1
                        // 走査の外を指すビットは GPU の結果の破損なので、配列の外を読まずに断る
                        guard wi * 32 + b < scan.count else { refused = true; break candidateWords }
                        let e = scan[wi * 32 + b]
                        let u = Int(e.u), v = Int(e.v)
                        let pk = power[pidx(u, v)]
                        let background = max(Double(ringMedianValue(power, u, v, scratch)), 1e-20)
                        let prominence = Double(pk) / background
                        // 絞り込みは CPU の判定と厳密に一致するはずなので、通らないビンは GPU の結果の食い違い
                        guard prominence >= p.kBackground else { refused = true; break candidateWords }
                        finish(power, u, v, prominence, &peaks)
                    }
                }
            } else {
                for e in scan {
                    let u = Int(e.u), v = Int(e.v)
                    let pk = power[pidx(u, v)]
                    guard pk > 0 else { continue }
                    var isMax = true
                    var s3: Float = 0
                    for dv in -1...1 {
                        let row = ((v + dv) & 127) << 7
                        for du in -1...1 {
                            let q = power[row | ((u + du) & 127)]
                            s3 += q
                            if !(du == 0 && dv == 0) && q >= pk { isMax = false }
                        }
                    }
                    guard isMax, s3 >= minPow3 else { continue }
                    var radial = power[Int(e.inner)]
                    if e.outer >= 0 { radial = max(radial, power[Int(e.outer)]) }
                    guard Double(pk) >= p.kRadial * Double(radial) else { continue }
                    let background = max(Double(ringMedianValue(power, u, v, scratch)), 1e-20)
                    let prominence = Double(pk) / background
                    guard prominence >= p.kBackground else { continue }
                    finish(power, u, v, prominence, &peaks)
                }
            }
            if refused { return }
            subharmonicGate(&peaks, power, scratch)
            // A2 の位相揃いは近傍の判定を通ったピークにしか使わないので A2Gate へ回すが、直交フラグは
            // 絞り込み前の列を読むため、ここで付ける
            if let o = ortho { markOrtho(&peaks, radiusTol: o.radiusTol, angleTol: o.angleTol) }
        }
        return !refused
    }

    /// A2(倍音の判定の後): r < 1 - 1e-6 のピークは、同じタイルの絞り込み前の列に別のピーク(r は問わず kind != 1)
    /// があり、半径の差が orthoRadiusTol 以内で角度が 90 ± orthoAngleTol 度離れていれば ortho とする
    func markOrtho(_ peaks: inout [Peak], radiusTol: Double, angleTol: Double) {
        for i in peaks.indices where peaks[i].r < 1 - 1e-6 {
            let a = atan2(peaks[i].cv, peaks[i].cu) * 180 / Double.pi
            for j in peaks.indices where j != i && peaks[j].kind != 1 {
                guard abs(peaks[j].rho - peaks[i].rho) <= radiusTol * peaks[i].rho else { continue }
                var d = abs(atan2(peaks[j].cv, peaks[j].cu) * 180 / Double.pi - a).truncatingRemainder(dividingBy: 180)
                if d < 0 { d += 180 }
                if abs(d - 90) <= angleTol { peaks[i].ortho = true; break }
            }
        }
    }

    /// 振幅(5x5、Double)、重心(3x3、Double)、保持率を求め、振幅が ampMin 以上なら加える
    @inline(__always) func finish(_ power: UnsafePointer<Float>, _ u: Int, _ v: Int, _ prominence: Double,
                                  _ peaks: inout [Peak]) {
        var s5 = 0.0, su = 0.0, sv = 0.0, se = 0.0
        for dv in -2...2 {
            let row = ((v + dv) & 127) << 7
            for du in -2...2 {
                let q = Double(power[row | ((u + du) & 127)])
                s5 += q
                if abs(du) <= 1 && abs(dv) <= 1 { su += q * Double(u + du); sv += q * Double(v + dv); se += q }
            }
        }
        let amp = ampScale * s5.squareRoot()
        guard amp >= p.ampMin else { return }
        let cu = su / se, cv = sv / se
        let rho = (cu * cu + cv * cv).squareRoot()
        let f = geo.cpd(rho / Double(N))
        peaks.append(Peak(u: u, v: v, cu: cu, cv: cv, rho: rho, amp: amp, prominence: prominence, cpd: f, r: retention(f)))
    }

    /// 網点ではない構造(線の繰り返しなど)の倍音を見分け、そのピークは残す(r = 1)
    func subharmonicGate(_ peaks: inout [Peak], _ power: UnsafePointer<Float>, _ scratch: UnsafeMutablePointer<Float>) {
        func localMaxNear(_ qu: Double, _ qv: Double, atLeast: Float) -> Bool {
            for dv in -1...1 {
                for du in -1...1 {
                    let bu = Int(qu.rounded()) + du, bv = Int(qv.rounded()) + dv
                    let q = power[pidx(bu, bv)]
                    guard q >= atLeast, q > 0 else { continue }
                    var isMax = true
                    for ev in -1...1 { for eu in -1...1 where !(eu == 0 && ev == 0) {
                        if power[pidx(bu + eu, bv + ev)] >= q { isMax = false }
                    } }
                    if isMax && Double(q) / max(Double(ringMedianValue(power, bu, bv, scratch)), 1e-20)
                        >= p.subMinProminence { return true }
                }
            }
            return false
        }
        for i in peaks.indices where peaks[i].r < 1 {
            let pk = peaks[i]
            let periodPx = Double(N) / pk.rho
            let pPeak = power[pidx(pk.u, pk.v)]
            for m in 2...max(2, p.subMaxOrder) {
                guard Double(m) * periodPx * mmPerPx > p.screenMaxPeriodMM else { continue }
                let qu = pk.cu / Double(m), qv = pk.cv / Double(m)
                if (qu * qu + qv * qv).squareRoot() < 2 { break }
                guard localMaxNear(qu, qv, atLeast: pPeak) else { continue }
                var comb = 0
                if m > 2 { for j in 2..<m where localMaxNear(qu * Double(j), qv * Double(j), atLeast: 0) { comb += 1 } }
                guard comb * 2 >= m - 2 else { continue }
                peaks[i].kind = 1
                peaks[i].fundamentalPeriod = Double(m) * periodPx
                peaks[i].r = 1
                break
            }
        }
    }
}

/// 近傍の一致: 消すべきピーク(r < 1)は、周り 8 タイルのうち minNeighbours 個以上に近い重心のピークがあるときだけ残す。
/// 残した列はパス 1 の列への印で表す(タイルごとの配列を作らない。設計書 §2.3)。印は列の全部のピークに書く
struct NeighbourGateA: TileGate {
    let p: Params
    let threads: Int
    func gate(_ peaks: PeakLists, nx: Int, ny: Int) -> Int {
        let T = nx * ny
        let drops = UnsafeMutablePointer<Int>.allocate(capacity: T)
        drops.initialize(repeating: 0, count: T)
        defer { drops.deallocate() }
        let tol = p.neighbourTolBins, minN = p.minNeighbours
        parallelFor(T, grain: 64, threads: threads) { t in
            let list = peaks.found(t)
            if list.isEmpty { return }
            let keep = peaks.keep(t)
            let tx = t % nx, ty = t / nx
            func recurs(_ pk: Peak) -> Int {
                var count = 0
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let x = tx + dx, y = ty + dy
                        guard x >= 0, x < nx, y >= 0, y < ny else { continue }
                        if peaks.found(y * nx + x).contains(where: { q in
                            let du = q.cu - pk.cu, dv = q.cv - pk.cv
                            return (du * du + dv * dv).squareRoot() <= tol
                        }) { count += 1 }
                    }
                }
                return count
            }
            var d = 0
            for j in 0..<list.count {
                let pk = list[j]
                let kept: Bool
                if pk.r >= 1 - 1e-6 {
                    kept = true
                } else if recurs(pk) >= minN {
                    kept = true
                } else {
                    d += 1
                    kept = false
                }
                keep[j] = kept ? 1 : 0
            }
            drops[t] = d
        }
        var dropped = 0
        for t in 0..<T { dropped += drops[t] }
        return dropped
    }
}
