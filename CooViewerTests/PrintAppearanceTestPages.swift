import Foundation

/// 網点処理(PrintAppearanceKit)のテスト用の合成ページ。実際のスキャンは使わず、式と SplitMix64 だけで描く。
/// 値は 8 bit の輝度(上の行から順、詰め物なし)。紙は 240、インクは 20 前後
enum PrintAppearanceTestPages {
    /// 網点 1 画素の値: 周期 period(px)、角度 angle(度)、インクの面積率 coverage(0...1)。
    /// 縁は柔らかいしきい値で描く
    static func screenValue(x: Int, y: Int, period: Double, cosT: Double, sinT: Double, coverage: Double) -> Double {
        let u = Double(x) * cosT + Double(y) * sinT, v = -Double(x) * sinT + Double(y) * cosT
        let s = (cos(2 * Double.pi * u / period) + cos(2 * Double.pi * v / period)) / 4 + 0.5
        let ink = min(1, max(0, (s - (1 - coverage)) * period / 1.5 + 0.5))
        return 240 - 220 * ink
    }

    /// 一様な網点のページ(±2 の雑音つき)
    static func screen(width: Int, height: Int, period: Double, angle: Double, coverage: Double = 0.5,
                       seed: UInt64 = 1) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        let t = angle * Double.pi / 180
        let cosT = cos(t), sinT = sin(t)
        var rng = SplitMix64(seed: seed)
        for y in 0..<height {
            for x in 0..<width {
                let v = screenValue(x: x, y: y, period: period, cosT: cosT, sinT: sinT, coverage: coverage)
                out[y * width + x] = clampByte(v + noise(&rng))
            }
        }
        return out
    }

    /// 一様な値のページ(雑音なし)
    static func flat(width: Int, height: Int, value: UInt8) -> [UInt8] {
        [UInt8](repeating: value, count: width * height)
    }

    /// 紙の上の線画と文字のような短い線(雑音つき)。線は 15、紙は 240
    static func lineArt(width: Int, height: Int, seed: UInt64 = 3) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var rng = SplitMix64(seed: seed)
        for i in 0..<(width * height) { out[i] = clampByte(240 + noise(&rng)) }
        drawLines(&out, width: width, x0: 0, y0: 0, x1: width, y1: height, count: 120, rng: &rng)
        drawGlyphs(&out, width: width, x0: width / 8, y0: height / 2, x1: width * 7 / 8, y1: height * 7 / 8, rng: &rng)
        return out
    }

    /// 縦に 4 段: 細かい網点(4 px、45 度)、粗い網点(11 px、45 度)、中くらいの網点(5 px、15 度)、線画と文字
    static func mix(width: Int, height: Int, seed: UInt64 = 5) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var rng = SplitMix64(seed: seed)
        let bands: [(period: Double, angle: Double, coverage: Double)?] = [(4, 45, 0.5), (11, 45, 0.5), (5, 15, 0.45), nil]
        for (index, band) in bands.enumerated() {
            let y0 = height * index / bands.count, y1 = height * (index + 1) / bands.count
            if let band {
                let t = band.angle * Double.pi / 180
                let cosT = cos(t), sinT = sin(t)
                for y in y0..<y1 {
                    for x in 0..<width {
                        let v = screenValue(x: x, y: y, period: band.period, cosT: cosT, sinT: sinT,
                                            coverage: band.coverage)
                        out[y * width + x] = clampByte(v + noise(&rng))
                    }
                }
            } else {
                for i in (y0 * width)..<(y1 * width) { out[i] = clampByte(240 + noise(&rng)) }
                drawLines(&out, width: width, x0: 0, y0: y0, x1: width, y1: y1, count: 30, rng: &rng)
                drawGlyphs(&out, width: width, x0: width / 8, y0: y0 + (y1 - y0) / 2, x1: width * 7 / 8, y1: y1 - 8,
                           rng: &rng)
            }
        }
        return out
    }

    /// 輝度のページを、インク(値 20)と紙(値 240)の 2 色の間の色で塗った sRGB の画素にする
    /// (1 画素 4 バイト R, G, B, 255)。2 色とも最大と最小の差を 32 未満にすれば、混ざった画素も含めて
    /// 色なしの判定になる(差は 2 色の差の内分に丸めの 1 を足した値を超えない)
    static func tinted(_ values: [UInt8], ink: [UInt8], paper: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: values.count * 4)
        for i in 0..<values.count {
            let f = min(1, max(0, (Double(values[i]) - 20) / 220))
            for c in 0..<3 {
                out[4 * i + c] = clampByte(Double(ink[c]) + (Double(paper[c]) - Double(ink[c])) * f)
            }
        }
        return out
    }

    /// 紫の 1 色刷り: 薄い紫のインクの網点と白い紙(どちらも最大と最小の差が 32 未満)
    static let purpleInk: [UInt8] = [100, 78, 108]
    static let whitePaper: [UInt8] = [248, 246, 250]
    /// 黄ばんだ紙: 墨の網点とクリーム色の紙(どちらも最大と最小の差が 32 未満)
    static let blackInk: [UInt8] = [38, 34, 30]
    static let creamPaper: [UInt8] = [242, 234, 214]

    /// 帯 index(mix の 4 段のうち)の内側の矩形(端から margin px 離す)
    static func mixBand(_ index: Int, width: Int, height: Int, margin: Int = 64) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let y0 = height * index / 4, y1 = height * (index + 1) / 4
        return (margin, y0 + margin, width - margin, y1 - margin)
    }

    /// 矩形内の、16x16 ブロック平均からの偏差の二乗平均平方根(網点の変調の大きさの目安)
    static func modulation(_ v: [UInt8], width: Int, rect: (x0: Int, y0: Int, x1: Int, y1: Int)) -> Double {
        var sum = 0.0, n = 0
        var by = rect.y0
        while by + 16 <= rect.y1 {
            var bx = rect.x0
            while bx + 16 <= rect.x1 {
                var m = 0.0
                for y in by..<(by + 16) { for x in bx..<(bx + 16) { m += Double(v[y * width + x]) } }
                m /= 256
                for y in by..<(by + 16) {
                    for x in bx..<(bx + 16) {
                        let d = Double(v[y * width + x]) - m
                        sum += d * d
                        n += 1
                    }
                }
                bx += 16
            }
            by += 16
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    private static func noise(_ rng: inout SplitMix64) -> Double {
        Double(Int(rng.next() % 5) - 2)
    }

    private static func clampByte(_ v: Double) -> UInt8 {
        UInt8(max(0, min(255, v.rounded())))
    }

    /// 1〜3 px 幅のまっすぐな線(値 15)
    private static func drawLines(_ out: inout [UInt8], width: Int, x0: Int, y0: Int, x1: Int, y1: Int, count: Int,
                                  rng: inout SplitMix64) {
        let w = x1 - x0, h = y1 - y0
        for _ in 0..<count {
            let sx = Double(x0 + Int(rng.next() % UInt64(w))), sy = Double(y0 + Int(rng.next() % UInt64(h)))
            let length = 40 + Int(rng.next() % UInt64(max(1, min(w, h) / 2 - 40)))
            let theta = Double(rng.next() % 1000) / 1000 * Double.pi
            let thickness = 1 + Int(rng.next() % 3)
            for t in 0..<length {
                let x = Int(sx + Double(t) * cos(theta)), y = Int(sy + Double(t) * sin(theta))
                for d in 0..<thickness {
                    for (xx, yy) in [(x + d, y), (x, y + d)] where xx >= x0 && xx < x1 && yy >= y0 && yy < y1 {
                        out[yy * width + xx] = 15
                    }
                }
            }
        }
    }

    /// 文字のような 2 px の縦横の短い線を、白い枠の中に並べる
    private static func drawGlyphs(_ out: inout [UInt8], width: Int, x0: Int, y0: Int, x1: Int, y1: Int,
                                   rng: inout SplitMix64) {
        for y in y0..<y1 { for x in x0..<x1 { out[y * width + x] = 245 } }
        let g = 22
        var gy = y0 + 6
        while gy < y1 - g {
            var gx = x0 + 6
            while gx < x1 - g {
                for _ in 0..<5 {
                    if rng.next() & 1 == 0 {
                        let yy = gy + Int(rng.next() % UInt64(g))
                        for y in yy..<min(y1, yy + 2) { for x in gx..<(gx + g - 4) { out[y * width + x] = 12 } }
                    } else {
                        let xx = gx + Int(rng.next() % UInt64(g - 4))
                        for y in gy..<(gy + g) { for x in xx..<min(x1, xx + 2) { out[y * width + x] = 12 } }
                    }
                }
                gx += g + 4
            }
            gy += g + 6
        }
    }
}
