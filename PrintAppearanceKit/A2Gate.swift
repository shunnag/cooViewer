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
//
// 節点・辺・成分の表は 1 ページの間だけ使う作業域(ScratchArena と FlatLists。EngineScratch.swift)から取り、
// ページごとに malloc しない(設計書 §2.3)。数の分かる表は先に数えてから取る。落とした成分のピークは
// 残したかの印(PeakLists.keep)を消して列から除く。

struct A2Outcome {
    var componentsKept = 0, componentsDropped = 0, peaksDroppedComponent = 0
}

final class A2Gate {
    let q: A2Params
    init(_ q: A2Params) { self.q = q }

    /// stop は位相揃いの回の間(2 回目以降の回の前)に呼ぶ。止めるときは例外を投げる(設計書 §5)。
    /// 作業域の確保に失敗したときは allocationFailed を投げる
    func run(peaks: PeakLists, nx: Int, ny: Int, lin: UnsafePointer<Float>, W: Int, H: Int, pool: WorkerPool,
             arena: ScratchArena, edges edgeLists: FlatLists<UInt64>, threads: Int,
             stop: () throws -> Void = {}) throws -> A2Outcome {
        var out = A2Outcome()
        // 成分の段は次の条件のときだけ行う
        guard q.clusterMinTiles > 1 || q.fillCore > 0 else { return out }
        let T = nx * ny
        // ---- ノード(タイルごとの CSR)。ノードは残したピークのうち r < 1 - 1e-6 のもの。
        // nodeIdx はタイルの検出の列の中の位置(残したかの印を消すのに使う)
        var M = 0
        for t in 0..<T {
            let list = peaks.found(t)
            if list.isEmpty { continue }
            let keep = peaks.keep(t)
            for j in 0..<list.count where keep[j] != 0 && list[j].r < 1 - 1e-6 { M += 1 }
        }
        let nodeStart = try arena.take(Int.self, T + 1)
        let nodeTile = try arena.take(Int32.self, M), nodeIdx = try arena.take(Int32.self, M)
        let ncu = try arena.take(Double.self, M), ncv = try arena.take(Double.self, M)
        let northo = try arena.take(Bool.self, M), namp = try arena.take(Double.self, M)
        var m = 0
        for t in 0..<T {
            nodeStart[t] = m
            let list = peaks.found(t)
            if list.isEmpty { continue }
            let keep = peaks.keep(t)
            for j in 0..<list.count where keep[j] != 0 && list[j].r < 1 - 1e-6 {
                let pk = list[j]
                nodeTile[m] = Int32(t); nodeIdx[m] = Int32(j); ncu[m] = pk.cu; ncv[m] = pk.cv; northo[m] = pk.ortho
                namp[m] = pk.amp
                m += 1
            }
        }
        nodeStart[T] = m
        // ---- つながり: 組と距離の式は固定。距離の判定はタイルごとに並列に行い(タイルごとの辺の列)、
        // 併合は逐次に行う。併合の順番によらず同じ分割(連結成分)になる
        let parent = try arena.take(Int32.self, M)
        for i in 0..<M { parent[i] = Int32(i) }
        let tol = q.clusterTolBins
        let busySlots = try arena.take(Int.self, T)
        var busyCount = 0
        for t in 0..<T where nodeStart[t] < nodeStart[t + 1] { busySlots[busyCount] = t; busyCount += 1 }
        let busy = UnsafeBufferPointer(rebasing: busySlots[0..<busyCount])
        // 辺の列は作業者の配列で作り、忙しいタイルの欄へ写す(タイルごとに配列を確保しない)
        try edgeLists.begin(slots: busy.count, expected: M * 8)
        let cu = ncu.baseAddress!, cv = ncv.baseAddress!
        pool.run(busy.count, threads: threads) { w, i in
            let t = busy[i], tx = t % nx, ty = t / nx
            let a0 = nodeStart[t], a1 = nodeStart[t + 1]
            w.edgeList.removeAll(keepingCapacity: true)
            for (dx, dy) in [(1, 0), (0, 1), (1, 1), (-1, 1)] {
                let x = tx + dx, y = ty + dy
                guard x >= 0, x < nx, y < ny else { continue }
                let u = y * nx + x
                let b0 = nodeStart[u], b1 = nodeStart[u + 1]
                if b0 == b1 { continue }
                for a in a0..<a1 {
                    for b in b0..<b1 {
                        let du = cu[a] - cu[b], dv = cv[a] - cv[b]
                        if (du * du + dv * dv).squareRoot() <= tol { w.edgeList.append(UInt64(a) << 32 | UInt64(b)) }
                    }
                }
            }
            _ = w.edgeList.withUnsafeBufferPointer { edgeLists.put(i, $0) }   // 確保の失敗は finish が投げる
        }
        let edges = try edgeLists.finish()
        do {
            let par = parent.baseAddress!
            @inline(__always) func find(_ a: Int) -> Int {
                var a = a
                while Int(par[a]) != a { par[a] = par[Int(par[a])]; a = Int(par[a]) }
                return a
            }
            for i in 0..<busy.count {
                for e in edges[i] {
                    let ra = find(Int(e >> 32)), rb = find(Int(e & 0xffff_ffff))
                    if ra != rb { par[ra] = Int32(rb) }
                }
            }
            // 経路を平らにする
            for a in 0..<M { _ = find(a) }
        }
        // ---- 成分は最初のノードの順に番号を付け、成員はノード順に並べる
        let compOf = try arena.take(Int32.self, M, repeating: -1)
        let rootComp = try arena.take(Int32.self, M, repeating: -1)
        var C = 0
        for a in 0..<M {
            var r = Int(parent[a])
            while Int(parent[r]) != r { r = Int(parent[r]) }
            if rootComp[r] < 0 { rootComp[r] = Int32(C); C += 1 }
            compOf[a] = rootComp[r]
        }
        let memberStart = try arena.take(Int.self, C + 1, repeating: 0)
        for a in 0..<M { memberStart[Int(compOf[a]) + 1] += 1 }
        for c in 0..<C { memberStart[c + 1] += memberStart[c] }
        let members = try arena.take(Int32.self, M, repeating: 0)
        let fillPos = try arena.take(Int.self, C + 1)
        _ = fillPos.initialize(fromContentsOf: memberStart)
        for a in 0..<M { let c = Int(compOf[a]); members[fillPos[c]] = Int32(a); fillPos[c] += 1 }   // ノード順の昇順
        // 異なるタイル(成員はノード順なのでタイルも昇順)、直交タイル、ノード順の重心の和
        let tileStart = try arena.take(Int.self, C + 1, repeating: 0)
        let tiles = try arena.take(Int32.self, M)
        var tileCountAll = 0
        let orthoTiles = try arena.take(Int.self, C, repeating: 0)
        let mu = try arena.take(Double.self, C, repeating: 0), mv = try arena.take(Double.self, C, repeating: 0)
        for c in 0..<C {
            tileStart[c] = tileCountAll
            var last: Int32 = -1, lastOrtho: Int32 = -1
            var su = 0.0, sv = 0.0
            for k in memberStart[c]..<memberStart[c + 1] {
                let a = Int(members[k])
                if nodeTile[a] != last { tiles[tileCountAll] = nodeTile[a]; tileCountAll += 1; last = nodeTile[a] }
                if northo[a] && nodeTile[a] != lastOrtho { orthoTiles[c] += 1; lastOrtho = nodeTile[a] }
                su += ncu[a]; sv += ncv[a]
            }
            let cnt = Double(memberStart[c + 1] - memberStart[c])
            mu[c] = su / cnt; mv[c] = sv / cnt
        }
        tileStart[C] = tileCountAll
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
        let rhoC = try arena.take(Double.self, C, repeating: 0), angC = try arena.take(Double.self, C, repeating: 0)
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
        let sizedSlots = try arena.take(Int.self, C)          // 相手になり得る成分
        var sizedCount = 0
        for c in 0..<C where tileCount(c) >= cmt { sizedSlots[sizedCount] = c; sizedCount += 1 }
        let sized = UnsafeBufferPointer(rebasing: sizedSlots[0..<sizedCount])

        // ---- 位相揃いは必要になったものだけ評価する
        // 上の規則を成分ごとの再開できる判定として走らせる: 述語 (bestFill(c) >= t) は評価済みの成員の 1 つが
        // t に届けば真、全成員を評価して届かなければ偽。答えが出ない述語は c の成員をさらに求める
        // (振幅の降順、同点はノード順。1 回に 1, 1, 2, 4, ... 個)。全成分の要求をまとめてタイル単位で並列に評価する。
        // 答えは厳密なので、どの判定も全評価と同じになる。順番が変えるのは仕事の量だけ
        let fills = try arena.take(Double.self, M, repeating: -1)      // -1 = 未評価
        // 1 回の評価のタイルの区切り(nodes の位置。仕事 gi は groupStart[gi]..<groupStart[gi + 1])
        let groupStart = try arena.take(Int.self, M + 1)
        func evaluate(_ nodes: UnsafeBufferPointer<Int32>) {
            // nodes は昇順なので同じタイルは連続する: 1 タイルを 1 つの仕事にする
            var groups = 0
            var s = 0
            while s < nodes.count {
                var e = s + 1
                while e < nodes.count && nodeTile[Int(nodes[e])] == nodeTile[Int(nodes[s])] { e += 1 }
                groupStart[groups] = s
                groups += 1
                s = e
            }
            groupStart[groups] = nodes.count
            let f = fills.baseAddress!
            pool.run(groups, threads: threads) { w, gi in
                let g = groupStart[gi]..<groupStart[gi + 1]
                let t = Int(nodeTile[Int(nodes[g.lowerBound])])
                let sc = w.fillScratch
                sc.load(lin, W: W, H: H, tile: t, x0: -96 + 32 * (t % nx), y0: -96 + 32 * (t / nx), block: q.fillBlock)
                for k in g {
                    let a = Int(nodes[k])
                    f[a] = sc.fill(cu: ncu[a], cv: ncv[a])
                }
            }
        }
        let bestHi = try arena.take(Double.self, C, repeating: 0)     // max(0, 評価済みの成員の位相揃い)
        let exact = try arena.take(Bool.self, C, repeating: false)    // 全成員を評価済み: bestHi が bestFill そのもの
        let done = try arena.take(Int.self, C, repeating: 0)          // 評価済みの成員の数(成分の並びの先頭から)
        let want = try arena.take(Double.self, C, repeating: 0)       // この回で答えの出ていない最大のしきい値
        // 成分 c の成員を振幅の降順に並べたもの(成員と同じ位置 memberStart[c]..<memberStart[c + 1] に置く。
        // 初めて要るときに並べる)
        let order = try arena.take(Int32.self, M)
        @inline(__always) func orderCount(_ c: Int) -> Int { memberStart[c + 1] - memberStart[c] }
        // 1 回に評価するノード(各ノードは 1 度だけ評価するので M 個に収まる)
        let nodeSlots = try arena.take(Int32.self, M)
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
        let decided = try arena.take(Int?.self, C, repeating: nil)
        /// 成員の並べ方: 振幅の降順、同点はノード順(全順序)
        func byAmplitude(_ a: Int32, _ b: Int32) -> Bool {
            let x = namp[Int(a)], y = namp[Int(b)]
            return x != y ? x > y : a < b
        }
        var round = 0
        while true {
            for c in 0..<C { want[c] = 0 }
            for r in 0..<C where decided[r] == nil { decided[r] = decide(r) }
            var nodeCount = 0
            for c in 0..<C where want[c] > 0 {
                let o = memberStart[c]
                if done[c] == 0 {
                    // 比較は全順序(同点はノード順)なので、並べ替えの方法によらず同じ並びになる
                    for k in o..<memberStart[c + 1] { order[k] = members[k] }
                    var span = UnsafeMutableBufferPointer(rebasing: order[o..<memberStart[c + 1]])
                    span.sort(by: byAmplitude)
                }
                let take = min(max(1, done[c]), orderCount(c) - done[c])   // 1, 1, 2, 4, ...
                for k in done[c]..<(done[c] + take) { nodeSlots[nodeCount] = order[o + k]; nodeCount += 1 }
            }
            if nodeCount == 0 { break }
            if round > 0 { try stop() }
            round += 1
            var nodes = UnsafeMutableBufferPointer(rebasing: nodeSlots[0..<nodeCount])
            nodes.sort()
            evaluate(UnsafeBufferPointer(nodes))
            for c in 0..<C where want[c] > 0 {
                let o = memberStart[c]
                let take = min(max(1, done[c]), orderCount(c) - done[c])
                for k in done[c]..<(done[c] + take) { bestHi[c] = max(bestHi[c], fills[Int(order[o + k])]) }
                done[c] += take
                exact[c] = done[c] == orderCount(c)
            }
        }

        // ---- 残すかどうか(ループを抜けた時点で全成分が決まっている)
        let keep = try arena.take(Bool.self, C, repeating: false)
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
                let cntT = try arena.take(Int.self, T + 1, repeating: 0)
                for c in 0..<C where keep[c] { for k in tileStart[c]..<tileStart[c + 1] { cntT[Int(tiles[k]) + 1] += 1 } }
                for t in 0..<T { cntT[t + 1] += cntT[t] }
                let keptAt = try arena.take(Int32.self, cntT[T], repeating: 0)
                let pos = try arena.take(Int.self, T + 1)
                _ = pos.initialize(fromContentsOf: cntT)
                for c in 0..<C where keep[c] {
                    for k in tileStart[c]..<tileStart[c + 1] { let t = Int(tiles[k]); keptAt[pos[t]] = Int32(c); pos[t] += 1 }
                }
                // 落とした成分はどれもこの回の写しだけに対して調べるので互いに独立: 並列に調べて後から反映する
                // (逐次に調べて反映するのと同じ結果)
                let candSlots = try arena.take(Int.self, C)
                var candCount = 0
                for c in 0..<C where !keep[c] { candSlots[candCount] = c; candCount += 1 }
                let cand = UnsafeBufferPointer(rebasing: candSlots[0..<candCount])
                let hits = try arena.take(Bool.self, cand.count, repeating: false)
                do {
                    let hp = hits
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

        // ---- 反映: 落とした成分のノードの印を消す(残した列はノードを除いた順のまま)
        for c in 0..<C { if keep[c] { out.componentsKept += 1 } else { out.componentsDropped += 1 } }
        for a in 0..<M where !keep[Int(compOf[a])] {
            out.peaksDroppedComponent += 1
            peaks.keep(Int(nodeTile[a]))[Int(nodeIdx[a])] = 0
        }
        return out
    }
}
