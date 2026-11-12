import Darwin
import Foundation

// A2 の位相揃い(coherent fill)。Double で厳密に求める(設計書 §5)。
//
// タイルの生の値は、線形光のページから analyse() と同じ鏡像の集め方で取り直す(パス 1 の値は保持しない)。
//
// 厳密さの要点:
// - 余弦・正弦の表は __sincos_stret で求める。これは sin() と cos() を別々に呼んだ結果とビット単位では一致しない
//   (最下位ビットが違う引数がある)。検証済みの値に合わせるため、同じ引数式 ((2 * pi) * f) * i で明示的に呼ぶ。
//   __sincos_stret は libm の非公開の入口なので、無くなったら engineVersion を上げて照合し直す。
// - どの和も同じ順序で足す(ブロック平均: y が外側・x が内側。復調も同じ。一貫性: by が外側・bx が内側)。
//   fillBlock 16 の速い経路は 1 行の 8 ブロックを SIMD8<Double> の 8 レーンで扱う。各レーンは自分のブロックの
//   スカラーの演算列をそのまま行うので、和の順序は変わらない。Swift は a*b+c を FMA に融合しないので、積の丸めも同じ。

@inline(__always) func refSinCos(_ a: Double) -> (sin: Double, cos: Double) {
    let r = __sincos_stret(a)
    return (r.__sinval, r.__cosval)
}

/// 集めた 128x128 タイルに対する位相揃いのスカラー版(任意の fillBlock)。fillBlock != 16 のときと、
/// SIMD 版の照合(テスト)に使う
func coherentFillReference(raw: UnsafePointer<Float>, cu: Double, cv: Double, block b: Int) -> Double {
    let n = N
    let nb = n / b
    let fx = cu / Double(n), fy = cv / Double(n)
    var cx = [Double](repeating: 0, count: n), sx = [Double](repeating: 0, count: n)
    var cy = [Double](repeating: 0, count: n), sy = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let ax = refSinCos(2 * Double.pi * fx * Double(i)), ay = refSinCos(2 * Double.pi * fy * Double(i))
        cx[i] = ax.cos; sx[i] = -ax.sin
        cy[i] = ay.cos; sy[i] = -ay.sin
    }
    var zr = [Double](repeating: 0, count: nb * nb), zi = [Double](repeating: 0, count: nb * nb)
    for by in 0..<nb {
        for bx in 0..<nb {
            var m = 0.0
            for y in (by * b)..<(by * b + b) { for x in (bx * b)..<(bx * b + b) { m += Double(raw[y * n + x]) } }
            m /= Double(b * b)
            var ar = 0.0, ai = 0.0
            for y in (by * b)..<(by * b + b) {
                for x in (bx * b)..<(bx * b + b) {
                    let v = Double(raw[y * n + x]) - m
                    let er = cx[x] * cy[y] - sx[x] * sy[y], ei = cx[x] * sy[y] + sx[x] * cy[y]
                    ar += v * er; ai += v * ei
                }
            }
            zr[by * nb + bx] = ar; zi[by * nb + bx] = ai
        }
    }
    return coherenceMin(zr, zi, nb)
}

/// min(C(1,0), C(0,1))(和は by が外側、bx が内側)
@inline(__always) func coherenceMin(_ zr: UnsafePointer<Double>, _ zi: UnsafePointer<Double>, _ nb: Int) -> Double {
    func coherence(_ dx: Int, _ dy: Int) -> Double {
        var sr = 0.0, si = 0.0, den = 0.0
        for by in 0..<(nb - dy) {
            for bx in 0..<(nb - dx) {
                let a = by * nb + bx, c = (by + dy) * nb + bx + dx
                sr += zr[a] * zr[c] + zi[a] * zi[c]
                si += zi[a] * zr[c] - zr[a] * zi[c]
                den += (zr[a] * zr[a] + zi[a] * zi[a] + zr[c] * zr[c] + zi[c] * zi[c]) / 2
            }
        }
        return den > 0 ? (sr * sr + si * si).squareRoot() / den : 0
    }
    return min(coherence(1, 0), coherence(0, 1))
}

@inline(__always) func coherenceMin(_ zr: [Double], _ zi: [Double], _ nb: Int) -> Double {
    zr.withUnsafeBufferPointer { r in zi.withUnsafeBufferPointer { i in coherenceMin(r.baseAddress!, i.baseAddress!, nb) } }
}

/// 位相揃いの段の作業者ごとの作業領域。load() で 1 タイルを集め、fill() で読み込んだタイルの 1 ピークを評価する
final class FillScratch {
    let raw: UnsafeMutablePointer<Float>                 // 128 x 128 の集めたタイル(fillBlock 16 ではレーンの並び)
    let vL: UnsafeMutablePointer<SIMD8<Double>>          // [y][xl] のレーン bx: Double(raw) - ブロック平均(fillBlock 16)
    let cx, sx, cy, sy: UnsafeMutablePointer<Double>     // 各 128
    let cxL, sxL: UnsafeMutablePointer<SIMD8<Double>>    // [xl] のレーン bx: cx[bx * 16 + xl]
    let zr, zi: UnsafeMutablePointer<Double>             // 各 64
    private(set) var tile = -1
    private(set) var block = 0

    init() {
        raw = .allocate(capacity: NN)
        vL = .allocate(capacity: N * 16)
        cx = .allocate(capacity: N); sx = .allocate(capacity: N); cy = .allocate(capacity: N); sy = .allocate(capacity: N)
        cxL = .allocate(capacity: 16); sxL = .allocate(capacity: 16)
        zr = .allocate(capacity: 64); zi = .allocate(capacity: 64)
    }

    deinit {
        raw.deallocate(); vL.deallocate(); cx.deallocate(); sx.deallocate(); cy.deallocate(); sy.deallocate()
        cxL.deallocate(); sxL.deallocate(); zr.deallocate(); zi.deallocate()
    }

    /// タイル t(原点 (x0, y0))を analyse() と同じ鏡像の読み方で lin から集め、fillBlock 16 ではブロック平均と
    /// v = Double(raw) - 平均 をレーンの並びで求める。平均はピークによらないのでタイルごとに一度だけ求め、
    /// 各レーンは自分のブロックを同じ順序で足す
    func load(_ lin: UnsafePointer<Float>, W: Int, H: Int, tile t: Int, x0: Int, y0: Int, block b: Int) {
        tile = t; block = b   // ページや繰り返しで lin が変わるので常に読み直す
        var xs = (0..<N).map { x -> Int in
            var xx = x0 + x
            if xx < 0 { xx = -xx - 1 } else if xx >= W { xx = 2 * W - xx - 1 }
            return xx
        }
        if b != 16 {
            // スカラー版のための自然な並び
            xs.withUnsafeMutableBufferPointer { xp in
                for y in 0..<N {
                    var yy = y0 + y
                    if yy < 0 { yy = -yy - 1 } else if yy >= H { yy = 2 * H - yy - 1 }
                    let row = lin + yy * W
                    let dst = raw + y * N
                    for x in 0..<N { dst[x] = row[xp[x]] }
                }
            }
            return
        }
        // Float のレーンの並び: raw[(y * 16 + xl) * 8 + bx] = タイルの (y, bx * 16 + xl) の値
        xs.withUnsafeMutableBufferPointer { xp in
            for y in 0..<N {
                var yy = y0 + y
                if yy < 0 { yy = -yy - 1 } else if yy >= H { yy = 2 * H - yy - 1 }
                let row = lin + yy * W
                let dst = raw + y * N
                for bx in 0..<8 {
                    for xl in 0..<16 { dst[xl * 8 + bx] = row[xp[bx * 16 + xl]] }
                }
            }
        }
        let lanesF = UnsafeRawPointer(raw).bindMemory(to: SIMD8<Float>.self, capacity: N * 16)
        for by in 0..<8 {
            var m = SIMD8<Double>(repeating: 0)
            for k in (by * 256)..<(by * 256 + 256) { m += SIMD8<Double>(lanesF[k]) }   // レーンごとに (yl, xl) の順
            m /= 256.0   // Double(b * b)
            for k in (by * 256)..<(by * 256 + 256) { vL[k] = SIMD8<Double>(lanesF[k]) - m }
        }
    }

    /// 読み込んだタイルを自然な並びで返す(テスト用。fillBlock 16 ではレーンの並びで持っているため)
    func naturalRaw() -> [Float] {
        var out = [Float](repeating: 0, count: NN)
        if block != 16 { for k in 0..<NN { out[k] = raw[k] }; return out }
        for y in 0..<N { for bx in 0..<8 { for xl in 0..<16 { out[y * N + bx * 16 + xl] = raw[(y * 16 + xl) * 8 + bx] } } }
        return out
    }

    /// 読み込んだタイルで、重心 (cu, cv) のピークの位相揃いを求める
    func fill(cu: Double, cv: Double) -> Double {
        if block != 16 { return coherentFillReference(raw: raw, cu: cu, cv: cv, block: block) }
        let fx = cu / Double(N), fy = cv / Double(N)
        for i in 0..<N {
            let ax = refSinCos(2 * Double.pi * fx * Double(i)), ay = refSinCos(2 * Double.pi * fy * Double(i))
            cx[i] = ax.cos; sx[i] = -ax.sin
            cy[i] = ay.cos; sy[i] = -ay.sin
        }
        for xl in 0..<16 {
            cxL[xl] = SIMD8<Double>(cx[xl], cx[16 + xl], cx[32 + xl], cx[48 + xl], cx[64 + xl], cx[80 + xl], cx[96 + xl], cx[112 + xl])
            sxL[xl] = SIMD8<Double>(sx[xl], sx[16 + xl], sx[32 + xl], sx[48 + xl], sx[64 + xl], sx[80 + xl], sx[96 + xl], sx[112 + xl])
        }
        for by in 0..<8 {
            var ar = SIMD8<Double>(repeating: 0), ai = SIMD8<Double>(repeating: 0)
            for yl in 0..<16 {
                let y = by * 16 + yl
                let cyy = cy[y], syy = sy[y]
                let vrow = vL + y * 16
                for xl in 0..<16 {
                    let c = cxL[xl], s = sxL[xl]
                    let er = c * cyy - s * syy, ei = c * syy + s * cyy
                    let v = vrow[xl]
                    ar += v * er; ai += v * ei
                }
            }
            for bx in 0..<8 { zr[by * 8 + bx] = ar[bx]; zi[by * 8 + bx] = ai[bx] }
        }
        return coherenceMin(UnsafePointer(zr), UnsafePointer(zi), 8)
    }
}
