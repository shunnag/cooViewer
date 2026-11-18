import Foundation

// q3 エッジクランプと強さの段階(設計書 §5)。
//
// q3: エネルギーゲートの後、[0, 1] への丸めの前に、各画素の出力を「その画素を含む 3x3 窓のうち最も平らなもの」の
// 元の範囲 [lo, hi] に収める。比較は同じ 256 段の EOTF 表を通した線形光で行う。演算の順序:
//   enc = encodeByte(lin)(lin = eotf[src] なので enc = q3EncLUT[src])。boxMinMaxTL(enc, k: 3) = 左上が (x, y) の
//   3x3 窓の最小・最大(端は (min(W-1, x+d), min(H-1, y+d)) で打ち切る)。
//   ゲート後の delta != 0 の各画素について、(max(0, x-ox), max(0, y-oy)) に置いた 9 窓を oy が外側・ox が内側の
//   昇順に調べ、hi - lo が最小の最初の窓を選ぶ(厳密な <)。
//   l = eotf[lo]、h = eotf[hi]、v = lin + delta、c = min(h, max(l, v))。c != v なら delta = c - lin(触れた画素)。
//   その後、通常どおり delta != 0 の画素で範囲外を数え、lin + delta を符号化する。

/// q3 が使う元の符号値: encodeByte(eotf[v])。この libm では恒等だが(テストで確かめる)、そうでない環境でも
/// 結果が変わらないよう表で持つ
let q3EncLUT: [UInt8] = (0..<256).map { encodeByte(eotf[$0]) }

/// 左上が (x, y) の 3x3 窓の符号値の最小・最大(端は打ち切り)。横、縦の 2 回の分離した走査で、行ごとに並列。
/// どの順でも厳密に同じ。scratch は 2 * W * H バイト、結果は lo / hi(各 W * H バイト)へ書く
func q3BoxTL(src: UnsafePointer<UInt8>, W: Int, H: Int, lo: UnsafeMutablePointer<UInt8>, hi: UnsafeMutablePointer<UInt8>,
             scratch: UnsafeMutablePointer<UInt8>, threads: Int) {
    let tlo = scratch, thi = scratch + W * H
    q3EncLUT.withUnsafeBufferPointer { e in
        let ep = e.baseAddress!
        parallelFor(H, grain: 16, threads: threads) { y in
            let s = src + y * W
            for x in 0..<W {
                var a = ep[Int(s[x])], b = a
                for d in 1..<3 {
                    let q = ep[Int(s[min(W - 1, x + d)])]
                    if q < a { a = q }
                    if q > b { b = q }
                }
                tlo[y * W + x] = a; thi[y * W + x] = b
            }
        }
    }
    parallelFor(H, grain: 16, threads: threads) { y in
        for x in 0..<W {
            var a = tlo[y * W + x], b = thi[y * W + x]
            for d in 1..<3 {
                let yy = min(H - 1, y + d)
                let q = tlo[yy * W + x], r = thi[yy * W + x]
                if q < a { a = q }
                if r > b { b = r }
            }
            lo[y * W + x] = a; hi[y * W + x] = b
        }
    }
}

/// 画素 (x, y) の選んだ窓: 9 窓のうち最も平らな最初のものの (lo, hi)
@inline(__always) func q3Select(_ blo: UnsafePointer<UInt8>, _ bhi: UnsafePointer<UInt8>, x: Int, y: Int, W: Int) -> (UInt8, UInt8) {
    var bestR = 256, lo: UInt8 = 0, hi: UInt8 = 255
    for oy in 0..<3 {
        let row = max(0, y - oy) * W
        for ox in 0..<3 {
            let j = row + max(0, x - ox)
            let r = Int(bhi[j]) - Int(blo[j])
            if r < bestR { bestR = r; lo = blo[j]; hi = bhi[j] }
        }
    }
    return (lo, hi)
}

/// CPU の q3(厳密、余裕なし)。ゲート後の delta をその場で直す。範囲外の数えと符号化の前に呼ぶ。
/// 行ごとに並列(画素は互いに独立)。触れた画素の数を返す
func q3ClampCPU(lin: UnsafePointer<Float>, delta: UnsafeMutablePointer<Float>, src: UnsafePointer<UInt8>, W: Int, H: Int,
                threads: Int) -> Int {
    let n = W * H
    // ページの 4 倍の一時領域は仮想記憶に置き、手放したらすぐ OS へ返す(設計書 §2.3)。
    // 確保できなければ従来の確保に戻る(どちらも確保できなければ止まるのは従来と同じ)
    let vm = try? PageBuffer(byteCount: 4 * n)
    let heap = vm == nil ? UnsafeMutablePointer<UInt8>.allocate(capacity: 4 * n) : nil
    defer {
        heap?.deallocate()
        withExtendedLifetime(vm) {}
    }
    let buf = vm?.bytes ?? heap!
    let blo = buf, bhi = buf + n
    q3BoxTL(src: src, W: W, H: H, lo: blo, hi: bhi, scratch: buf + 2 * n, threads: threads)
    let rows = UnsafeMutablePointer<Int>.allocate(capacity: H)
    defer { rows.deallocate() }
    eotf.withUnsafeBufferPointer { e in
        let ep = e.baseAddress!
        parallelFor(H, grain: 16, threads: threads) { y in
            var touched = 0
            for x in 0..<W {
                let i = y * W + x
                guard delta[i] != 0 else { continue }
                let (lo, hi) = q3Select(blo, bhi, x: x, y: y, W: W)
                let l = ep[Int(lo)], h = ep[Int(hi)]
                let v = lin[i] + delta[i]
                let c = min(h, max(l, v))
                if c != v { delta[i] = c - lin[i]; touched += 1 }
            }
            rows[y] = touched
        }
    }
    var total = 0
    for y in 0..<H { total += rows[y] }
    return total
}

/// 全画素の選んだ窓の (lo, hi) を交互に並べたもの(GPU の q3Window の出力と同じ並び)。照合用
func q3BoundsCPU(src: UnsafePointer<UInt8>, W: Int, H: Int, threads: Int) -> [UInt8] {
    let n = W * H
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4 * n)
    defer { buf.deallocate() }
    q3BoxTL(src: src, W: W, H: H, lo: buf, hi: buf + n, scratch: buf + 2 * n, threads: threads)
    var out = [UInt8](repeating: 0, count: 2 * n)
    out.withUnsafeMutableBufferPointer { o in
        let op = o.baseAddress!
        parallelFor(H, grain: 16, threads: threads) { y in
            for x in 0..<W {
                let (lo, hi) = q3Select(buf, buf + n, x: x, y: y, W: W)
                op[2 * (y * W + x)] = lo; op[2 * (y * W + x) + 1] = hi
            }
        }
    }
    return out
}

// MARK: - 強さの段階

/// 強め を 標準 に留める高さの境(この値未満の高さのページ)
let levelCapHeightPx = 800

extension PrintAppearanceLevel {
    /// 段階ごとの観察距離(mm)。距離は内部の値で、設定キーや画面の文言には出さない
    var distanceMM: Double {
        switch self {
        case .low: return 250
        case .standard: return 300
        case .strong: return 400
        }
    }
}

/// 実際に使う段階: 強め は高さ 800 px 未満のページでは 標準 にする(低解像度のスキャンでの強めすぎを避ける)
func effectiveLevel(_ level: PrintAppearanceLevel, heightPx: Int) -> PrintAppearanceLevel {
    level == .strong && heightPx < levelCapHeightPx ? .standard : level
}
