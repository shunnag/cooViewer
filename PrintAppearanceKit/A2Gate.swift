import Foundation

// A2 判定: 連結成分の一貫性による絞り込み(設計書 §5)。CPU、Double。
//
// 近傍の一致の後、残った列に対して次の順に行う:
//   ノード = 残ったピークのうち r < 1 - 1e-6 のもの(タイルの走査順、次に列の順)
//   -> clusterTolBins 以内の 8 近傍のつながり(前向きの 4 方向)-> 連結成分
//   -> 成分ごとに: 異なるタイルの数、直交タイルの数、ノード順の重心の和、最良の位相揃い
//   -> 残す規則(大きさ + 位相揃いの芯、十分な大きさ、直交の証拠、相手の軸)-> 格子の補完(最大 2 回)
//   -> 落とした成分のノードを列から除く。
//
// 成分は最初のノードの番号順に数え、配列で持つ。どの判定も成分を調べる順番に依存しない
// (相手の判定は残す/落とすの結果を読まず、補完は回ごとの残した集合の写しに対して調べ、
// その組 {a f1 + b f2} は (f1, f2) について対称で IEEE の加算は可換)ため、この順で結果は決まる。
//
// 位相揃いは成分ごとに 2 つの述語(bestFill >= fillCore と bestFill >= partnerMinFill、
// bestFill = max(0, 成員の位相揃い))を通してしか使わない。そこで、述語に届き得る成分について、
// 必要なしきい値に 1 つの成員が届いた時点で評価を止め、届かなければ全成員を評価する。
// 述語の答え、したがってすべての判定は、全ノードを評価したときと同じになる。

struct A2Outcome {
    var componentsKept = 0, componentsDropped = 0, peaksDroppedComponent = 0
}

final class A2Gate {
    let q: A2Params
    init(_ q: A2Params) { self.q = q }

    func run(kept: inout [[Peak]], nx: Int, ny: Int, lin: UnsafePointer<Float>, W: Int, H: Int, pool: WorkerPool,
             threads: Int) -> A2Outcome {
        var out = A2Outcome()
        // 成分の段は次の条件のときだけ行う
        guard q.clusterMinTiles > 1 || q.fillCore > 0 else { return out }
        let T = nx * ny
        // ---- ノード(タイルごとの CSR)
        var nodeStart = [Int](repeating: 0, count: T + 1)
        var nodeTile: [Int32] = [], nodeIdx: [Int32] = [], ncu: [Double] = [], ncv: [Double] = [], northo: [Bool] = []
        var namp: [Double] = []
        for t in 0..<T {
            nodeStart[t] = nodeTile.count
            for (j, pk) in kept[t].enumerated() where pk.r < 1 - 1e-6 {
                nodeTile.append(Int32(t)); nodeIdx.append(Int32(j)); ncu.append(pk.cu); ncv.append(pk.cv); northo.append(pk.ortho)
                namp.append(pk.amp)
            }
        }
        nodeStart[T] = nodeTile.count
        let M = nodeTile.count
        // ---- つながり: 組と距離の式は固定。距離の判定はタイルごとに並列に行い(タイルごとの辺の列)、
        // 併合は逐次に行う。併合の順番によらず同じ分割(連結成分)になる
        var parent = [Int32](repeating: 0, count: M)
        for i in 0..<M { parent[i] = Int32(i) }
        let tol = q.clusterTolBins
        let busy = (0..<T).filter { nodeStart[$0] < nodeStart[$0 + 1] }
        var edges = [[UInt64]](repeating: [], count: busy.count)
        ncu.withUnsafeBufferPointer { cup in
            ncv.withUnsafeBufferPointer { cvp in
                edges.withUnsafeMutableBufferPointer { ep in
                    let cu = cup.baseAddress!, cv = cvp.baseAddress!
                    parallelFor(busy.count, grain: 32, threads: threads) { i in
                        let t = busy[i], tx = t % nx, ty = t / nx
                        let a0 = nodeStart[t], a1 = nodeStart[t + 1]
                        var local: [UInt64] = []
                        for (dx, dy) in [(1, 0), (0, 1), (1, 1), (-1, 1)] {
                            let x = tx + dx, y = ty + dy
                            guard x >= 0, x < nx, y < ny else { continue }
                            let u = y * nx + x
                            let b0 = nodeStart[u], b1 = nodeStart[u + 1]
                            if b0 == b1 { continue }
                            for a in a0..<a1 {
                                for b in b0..<b1 {
                                    let du = cu[a] - cu[b], dv = cv[a] - cv[b]
                                    if (du * du + dv * dv).squareRoot() <= tol { local.append(UInt64(a) << 32 | UInt64(b)) }
                                }
                            }
                        }
                        ep[i] = local
                    }
                }
            }
        }
        parent.withUnsafeMutableBufferPointer { pp in
            let par = pp.baseAddress!
            @inline(__always) func find(_ a: Int) -> Int {
                var a = a
                while Int(par[a]) != a { par[a] = par[Int(par[a])]; a = Int(par[a]) }
                return a
            }
            for list in edges {
                for e in list {
                    let ra = find(Int(e >> 32)), rb = find(Int(e & 0xffff_ffff))
                    if ra != rb { par[ra] = Int32(rb) }
                }
            }
            // 経路を平らにする
            for a in 0..<M { _ = find(a) }
        }
        // ---- 成分は最初のノードの順に番号を付け、成員はノード順に並べる
        var compOf = [Int32](repeating: -1, count: M)
        var rootComp = [Int32](repeating: -1, count: M)
        var C = 0
        for a in 0..<M {
            var r = Int(parent[a])
            while Int(parent[r]) != r { r = Int(parent[r]) }
            if rootComp[r] < 0 { rootComp[r] = Int32(C); C += 1 }
            compOf[a] = rootComp[r]
        }
        var memberStart = [Int](repeating: 0, count: C + 1)
        for a in 0..<M { memberStart[Int(compOf[a]) + 1] += 1 }
        for c in 0..<C { memberStart[c + 1] += memberStart[c] }
        var members = [Int32](repeating: 0, count: M)
        var fillPos = memberStart
        for a in 0..<M { let c = Int(compOf[a]); members[fillPos[c]] = Int32(a); fillPos[c] += 1 }   // ノード順の昇順
        // 異なるタイル(成員はノード順なのでタイルも昇順)、直交タイル、ノード順の重心の和
        var tileStart = [Int](repeating: 0, count: C + 1)
        var tiles: [Int32] = []
        tiles.reserveCapacity(M)
        var orthoTiles = [Int](repeating: 0, count: C)
        var mu = [Double](repeating: 0, count: C), mv = [Double](repeating: 0, count: C)
        for c in 0..<C {
            tileStart[c] = tiles.count
            var last: Int32 = -1, lastOrtho: Int32 = -1
            var su = 0.0, sv = 0.0
            for k in memberStart[c]..<memberStart[c + 1] {
                let a = Int(members[k])
                if nodeTile[a] != last { tiles.append(nodeTile[a]); last = nodeTile[a] }
                if northo[a] && nodeTile[a] != lastOrtho { orthoTiles[c] += 1; lastOrtho = nodeTile[a] }
                su += ncu[a]; sv += ncv[a]
            }
            let cnt = Double(memberStart[c + 1] - memberStart[c])
            mu[c] = su / cnt; mv[c] = sv / cnt
        }
        tileStart[C] = tiles.count
        @inline(__always) func tileCount(_ c: Int) -> Int { tileStart[c + 1] - tileStart[c] }

        // ---- 残す規則。条件(n >= clusterMinTiles || orthoOK)を満たす成分は
        // coreOK || big || orthoOK || partnerOK のとき残す。OR の各項はどの順に調べてもよいので、次と同値:
        //   n < clusterMinTiles          -> orthoOK なら残す
        //   big (n >= clusterBigTiles)   -> 残す
        //   それ以外                     -> orthoOK || coreOK || partnerOK
        // orthoOK = (直交タイル >= orthoMinTiles) && bestFill >= partnerMinFill、coreOK = bestFill >= fillCore、
        // partnerOK = partnerEnabled && bestFill >= partnerMinFill && 相手 p(n(p) >= clusterMinTiles、半径、角度、
        // 共有タイル)のどれかが bestFill(p) >= partnerMinFill。bestFill = max(0, 成員の位相揃い)
        let cmt = q.clusterMinTiles, pm = q.partnerMinFill, core = q.fillCore
        @inline(__always) func isBig(_ c: Int) -> Bool { q.clusterBigTiles > 0 && tileCount(c) >= q.clusterBigTiles }
        @inline(__always) func orthoTilesOK(_ c: Int) -> Bool { q.orthoMinTiles > 0 && orthoTiles[c] >= q.orthoMinTiles }
        // 成分の平均重心の半径と角度
        var rhoC = [Double](repeating: 0, count: C), angC = [Double](repeating: 0, count: C)
        for c in 0..<C {
            let u = mu[c], v = mv[c]
            rhoC[c] = (u * u + v * v).squareRoot(); angC[c] = atan2(v, u) * 180 / Double.pi
        }
        func disjoint(_ a: Int, _ b: Int) -> Bool {
            var i = tileStart[a], j = tileStart[b]
            let ie = tileStart[a + 1], je = tileStart[b + 1]
            while i < ie && j < je {
                if tiles[i] == tiles[j] { return false }
                if tiles[i] < tiles[j] { i += 1 } else { j += 1 }
            }
            return true
        }
        /// r に対する相手 p の位相揃いを使わない判定(半径が partnerRadiusTol × rho(r) 以内、
        /// 角度差 mod 180 が [partnerAngleMin, partnerAngleMax]、タイルを 1 つ以上共有)
        func partnerGeometry(_ r: Int, _ p: Int) -> Bool {
            guard abs(rhoC[p] - rhoC[r]) <= q.partnerRadiusTol * rhoC[r] else { return false }
            var d = abs(angC[p] - angC[r]).truncatingRemainder(dividingBy: 180)
            if d < 0 { d += 180 }
            guard d >= q.partnerAngleMin && d <= q.partnerAngleMax else { return false }
            return !disjoint(r, p)
        }
        let sized = (0..<C).filter { tileCount($0) >= cmt }     // 相手になり得る成分

        // ---- 位相揃いは必要になったものだけ評価する
        // 上の規則を成分ごとの再開できる判定として走らせる: 述語 (bestFill(c) >= t) は評価済みの成員の 1 つが
        // t に届けば真、全成員を評価して届かなければ偽。答えが出ない述語は c の成員をさらに求める
        // (振幅の降順、同点はノード順。1 回に 1, 1, 2, 4, ... 個)。全成分の要求をまとめてタイル単位で並列に評価する。
        // 答えは厳密なので、どの判定も全評価と同じになる。順番が変えるのは仕事の量だけ
        var fills = [Double](repeating: -1, count: M)      // -1 = 未評価
        func evaluate(_ nodes: [Int32]) {
            // nodes は昇順なので同じタイルは連続する: 1 タイルを 1 つの仕事にする
            var groups: [Range<Int>] = []
            var s = 0
            while s < nodes.count {
                var e = s + 1
                while e < nodes.count && nodeTile[Int(nodes[e])] == nodeTile[Int(nodes[s])] { e += 1 }
                groups.append(s..<e)
                s = e
            }
            fills.withUnsafeMutableBufferPointer { fp in
                let f = fp.baseAddress!
                pool.run(groups.count, threads: threads) { w, gi in
                    let g = groups[gi]
                    let t = Int(nodeTile[Int(nodes[g.lowerBound])])
                    let sc = w.fillScratch
                    sc.load(lin, W: W, H: H, tile: t, x0: -96 + 32 * (t % nx), y0: -96 + 32 * (t / nx), block: q.fillBlock)
                    for k in g {
                        let a = Int(nodes[k])
                        f[a] = sc.fill(cu: ncu[a], cv: ncv[a])
                    }
                }
            }
        }
        var bestHi = [Double](repeating: 0, count: C)      // max(0, 評価済みの成員の位相揃い)
        var exact = [Bool](repeating: false, count: C)     // 全成員を評価済み: bestHi が bestFill そのもの
        var done = [Int](repeating: 0, count: C)           // 評価済みの成員の数(成分の並びの先頭から)
        var want = [Double](repeating: 0, count: C)        // この回で答えの出ていない最大のしきい値
        var order: [[Int32]] = Array(repeating: [], count: C)
        /// bestFill(c) >= t: 真、偽、または nil(未決: c の成員をさらに求める)
        func ask(_ c: Int, _ t: Double) -> Bool? {
            if t <= 0 || bestHi[c] >= t { return true }
            if exact[c] { return false }
            if t > want[c] { want[c] = t }
            return nil
        }
        /// 0 落とす、1 残す、2 相手の規則で残す、nil = 位相揃い待ち
        func decide(_ r: Int) -> Int? {
            let n = tileCount(r)
            if n < cmt {
                if !orthoTilesOK(r) { return 0 }
                guard let a = ask(r, pm) else { return nil }
                return a ? 1 : 0
            }
            if isBig(r) { return 1 }
            if orthoTilesOK(r) {
                guard let a = ask(r, pm) else { return nil }
                if a { return 1 }
            }
            guard let c = ask(r, core) else { return nil }
            if c { return 1 }
            guard q.partnerEnabled else { return 0 }
            guard let a = ask(r, pm) else { return nil }
            if !a { return 0 }
            var waiting = false
            for p in sized where p != r && partnerGeometry(r, p) {
                guard let b = ask(p, pm) else { waiting = true; continue }
                if b { return 2 }
            }
            return waiting ? nil : 0
        }
        var decided = [Int?](repeating: nil, count: C)
        while true {
            for c in 0..<C { want[c] = 0 }
            for r in 0..<C where decided[r] == nil { decided[r] = decide(r) }
            var nodes: [Int32] = []
            for c in 0..<C where want[c] > 0 {
                if done[c] == 0 {
                    order[c] = Array(members[memberStart[c]..<memberStart[c + 1]]).sorted { a, b in
                        namp[Int(a)] != namp[Int(b)] ? namp[Int(a)] > namp[Int(b)] : a < b
                    }
                }
                let take = min(max(1, done[c]), order[c].count - done[c])   // 1, 1, 2, 4, ...
                nodes.append(contentsOf: order[c][done[c]..<(done[c] + take)])
            }
            if nodes.isEmpty { break }
            nodes.sort()
            evaluate(nodes)
            for c in 0..<C where want[c] > 0 {
                let take = min(max(1, done[c]), order[c].count - done[c])
                for k in done[c]..<(done[c] + take) { bestHi[c] = max(bestHi[c], fills[Int(order[c][k])]) }
                done[c] += take
                exact[c] = done[c] == order[c].count
            }
        }
        order.removeAll()

        // ---- 残すかどうか(ループを抜けた時点で全成分が決まっている)
        var keep = [Bool](repeating: false, count: C)
        for r in 0..<C {
            let d = decided[r]!
            keep[r] = d != 0
        }

        // ---- 格子の補完
        if q.closureOrder > 0 {
            let A = q.closureOrder, nn = Double(N)
            @inline(__always) func wrap(_ x: Double) -> Double {
                var y = x.truncatingRemainder(dividingBy: nn); if y > nn / 2 { y -= nn }; if y < -nn / 2 { y += nn }; return y
            }
            for _ in 0..<2 {
                // 残した集合の写し: タイル -> 残した成分(CSR)
                var cntT = [Int](repeating: 0, count: T + 1)
                for c in 0..<C where keep[c] { for k in tileStart[c]..<tileStart[c + 1] { cntT[Int(tiles[k]) + 1] += 1 } }
                for t in 0..<T { cntT[t + 1] += cntT[t] }
                var keptAt = [Int32](repeating: 0, count: cntT[T])
                var pos = cntT
                for c in 0..<C where keep[c] {
                    for k in tileStart[c]..<tileStart[c + 1] { let t = Int(tiles[k]); keptAt[pos[t]] = Int32(c); pos[t] += 1 }
                }
                // 落とした成分はどれもこの回の写しだけに対して調べるので互いに独立: 並列に調べて後から反映する
                // (逐次に調べて反映するのと同じ結果)
                let cand = (0..<C).filter { !keep[$0] }
                var hits = [Bool](repeating: false, count: cand.count)
                hits.withUnsafeMutableBufferPointer { hp in
                    parallelFor(cand.count, grain: 16, threads: threads) { ci in
                        let r = cand[ci]
                        var parents: [Int] = []
                        for k in tileStart[r]..<tileStart[r + 1] {
                            let t = Int(tiles[k])
                            for m in cntT[t]..<cntT[t + 1] { parents.append(Int(keptAt[m])) }
                        }
                        if parents.isEmpty { return }
                        parents.sort()   // 順番は結果に効かないが、重複を除いて昇順にしておく
                        var w = 1
                        for k in 1..<parents.count where parents[k] != parents[w - 1] { parents[w] = parents[k]; w += 1 }
                        parents.removeLast(parents.count - w)
                        let u = mu[r], v = mv[r]
                        var hit = false
                        outer: for i in 0..<parents.count {
                            let p1 = parents[i]
                            let u1 = mu[p1], v1 = mv[p1]
                            for j in i..<parents.count {
                                let p2 = parents[j]
                                let u2 = mu[p2], v2 = mv[p2]
                                for a in -A...A {
                                    for b in (i == j ? 0...0 : -A...A) {
                                        if (a == 0 && b == 0) || (i == j && abs(a) < 2) { continue }
                                        let gu = Double(a) * u1 + Double(b) * u2, gv = Double(a) * v1 + Double(b) * v2
                                        for si in 0..<2 {
                                            let sg = si == 0 ? 1.0 : -1.0
                                            let du = wrap(gu - sg * u), dv = wrap(gv - sg * v)
                                            if (du * du + dv * dv).squareRoot() <= q.closureTolBins { hit = true; break outer }
                                        }
                                    }
                                }
                            }
                        }
                        hp[ci] = hit
                    }
                }
                var added = false
                for i in 0..<cand.count where hits[i] { keep[cand[i]] = true; added = true }
                if !added { break }
            }
        }

        // ---- 反映
        for c in 0..<C { if keep[c] { out.componentsKept += 1 } else { out.componentsDropped += 1 } }
        var drop = [Bool](repeating: false, count: M)
        for a in 0..<M where !keep[Int(compOf[a])] { drop[a] = true; out.peaksDroppedComponent += 1 }
        for t in 0..<T {
            let a0 = nodeStart[t], a1 = nodeStart[t + 1]
            if a0 == a1 { continue }
            var anyDrop = false
            for a in a0..<a1 where drop[a] { anyDrop = true; break }
            if !anyDrop { continue }
            var dropIdx = Set<Int>()
            for a in a0..<a1 where drop[a] { dropIdx.insert(Int(nodeIdx[a])) }
            kept[t] = kept[t].enumerated().filter { !dropIdx.contains($0.offset) }.map { $0.element }
        }
        return out
    }
}
