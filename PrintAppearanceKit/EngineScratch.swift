import Darwin
import Foundation

// 1 ページの処理の間だけ要る可変長の表を、エンジンが持つ仮想記憶の領域に置く(設計書 §2.3、§5)。
// 以前はタイルごとのピークの配列(11 MP のページで 1 万個近く、検出と近傍の一致で合わせて約 80 MB)、
// ノッチの項目の配列(append で伸ばし、32 MB とその倍々の列)、A2 の節点・辺・成分の配列を
// ページごとに malloc で確保して捨てていた。malloc は手放した小さな領域と大きな領域を汚れたまま持ち続け、
// 11 MP の見開きの本で、最後のページ送りから 30 秒後の使用量が網点処理なしより 56〜62 MB 多く残った。
// ここの領域はページをまたいで使い回し(伸びるだけ)、作業域と一緒に手放す(vm_deallocate ですぐ OS へ返る)。
// 確保した頁には触れない(vm_allocate の頁は使ったものだけが使用量に数えられる)。

/// 仮想記憶から確保する、伸びるだけの型付きの領域(ホストだけ。GPU は読まない)。
/// 伸ばすときは先頭の preserving 個を新しい領域へ写す(写さない分の中身は不定)
final class GrowableBuffer<Element: BitwiseCopyable> {
    private var raw: UnsafeMutableRawPointer?
    private(set) var byteCount = 0
    private(set) var capacity = 0

    init() {}

    deinit { if let raw { PageMemory.deallocate(raw, byteCount) } }

    /// count 個以上が入るようにして先頭を返す
    @discardableResult
    func ensure(_ count: Int, preserving: Int = 0) throws -> UnsafeMutablePointer<Element> {
        if raw == nil || count > capacity {
            let stride = MemoryLayout<Element>.stride
            let page = Int(getpagesize())
            let bytes = max(page, (max(1, count) * stride + page - 1) / page * page)
            guard let made = PageMemory.allocate(bytes) else {
                throw PrintAppearanceError.allocationFailed("作業域 \(bytes) バイト")
            }
            made.bindMemory(to: Element.self, capacity: bytes / stride)
            if let raw {
                if preserving > 0 { memcpy(made, raw, min(preserving, capacity) * stride) }
                PageMemory.deallocate(raw, byteCount)
            }
            raw = made
            byteCount = bytes
            capacity = bytes / stride
        }
        return pointer
    }

    /// ensure が成功した後にだけ参照する
    var pointer: UnsafeMutablePointer<Element> { raw!.assumingMemoryBound(to: Element.self) }
}

/// 項目(タイル、A2 の忙しいタイル)ごとの可変長の列を、1 つの伸びるだけの領域に平らに並べる。
/// put は並列に呼べる(ロックの下で場所を取って写す。列の置き場所は終わった順だが、読む側は項目の番号で引くので
/// 結果は並列数や順番によらない)。読むのは全部の put が終わってから、view を通して
final class FlatLists<Element: BitwiseCopyable> {
    private let items = GrowableBuffer<Element>()
    private let starts = GrowableBuffer<Int>()
    private let counts = GrowableBuffer<Int>()
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// この回に書いた要素の数
    private(set) var total = 0
    /// put が確保に失敗した
    private var failed = false

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// 確保済みのバイト数(稼働状況の表示用)
    var byteCount: Int { items.byteCount + starts.byteCount + counts.byteCount }

    /// slots 個の空の列から始める。書かれない列は空のまま(前の回の値を残さない)。
    /// expected は全体の要素数の見込みで、足りなければ put が倍に伸ばす
    func begin(slots: Int, expected: Int) throws {
        let c = try counts.ensure(max(1, slots))
        try starts.ensure(max(1, slots))
        for i in 0..<slots { c[i] = 0 }
        if items.capacity < expected { try items.ensure(expected) }
        total = 0
        failed = false
    }

    /// slot の列を書く(1 つの slot に 1 回だけ)。並列に呼べる。確保に失敗したら偽を返す(finish が投げる)
    @discardableResult
    func put(_ slot: Int, _ list: UnsafeBufferPointer<Element>) -> Bool {
        guard let source = list.baseAddress, !list.isEmpty else { return true }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let need = total + list.count
        if need > items.capacity {
            do {
                try items.ensure(max(need, 2 * items.capacity), preserving: total)
            } catch {
                failed = true
                return false
            }
        }
        (items.pointer + total).initialize(from: source, count: list.count)
        starts.pointer[slot] = total
        counts.pointer[slot] = list.count
        total = need
        return true
    }

    /// 全部の put の後に呼ぶ。put が確保に失敗していたら投げる
    func finish() throws -> FlatListsView<Element> {
        if failed { throw PrintAppearanceError.allocationFailed("作業域(列)") }
        try items.ensure(max(1, total), preserving: total)
        return FlatListsView(items: items.pointer, starts: starts.pointer, counts: counts.pointer)
    }
}

/// FlatLists の読み出し(次の begin まで有効)
struct FlatListsView<Element: BitwiseCopyable> {
    let items: UnsafeMutablePointer<Element>
    let starts: UnsafePointer<Int>
    let counts: UnsafePointer<Int>

    /// 列の最初の要素の通し番号(列が空のときは使わない)
    @inline(__always) func start(_ slot: Int) -> Int { starts[slot] }

    @inline(__always) subscript(_ slot: Int) -> UnsafeBufferPointer<Element> {
        let n = counts[slot]
        return n == 0 ? UnsafeBufferPointer(start: items, count: 0) : UnsafeBufferPointer(start: items + starts[slot], count: n)
    }
}

/// パス 1 の検出の列(タイルごと、絞り込み前)と、近傍の一致・A2 が残したかの印(ピークごとに 1 バイト)。
/// 残した列は検出の列から印の付いたものを順に読んだもので、近傍の一致と A2 の結果の配列を作らない
final class PeakTable {
    private let lists = FlatLists<Peak>()
    private let flags = GrowableBuffer<UInt8>()

    var byteCount: Int { lists.byteCount + flags.byteCount }

    /// tiles 個の空の列から始める(仮想の大きさだけ取る。1 タイルあたり 48 個を見込み、足りなければ伸ばす)
    func begin(tiles: Int) throws {
        try lists.begin(slots: tiles, expected: tiles * 48)
    }

    /// タイルの検出の列を書く。並列に呼べる
    func put(tile: Int, _ peaks: [Peak]) {
        _ = peaks.withUnsafeBufferPointer { lists.put(tile, $0) }   // 確保の失敗は finishPass1 が投げる
    }

    /// パス 1 を書き終えたら呼ぶ。印の領域を用意する(印は近傍の一致が全部のピークに書く)
    func finishPass1() throws -> PeakLists {
        let view = try lists.finish()
        let keep = try flags.ensure(max(1, lists.total))
        return PeakLists(found: view, keepFlags: keep)
    }
}

/// PeakTable の読み書き(次の begin まで有効)。印の書き込みはタイルごとに分かれる(並列に書いてよい)
struct PeakLists {
    let found: FlatListsView<Peak>
    let keepFlags: UnsafeMutablePointer<UInt8>

    /// パス 1 の列(絞り込み前)
    @inline(__always) func found(_ t: Int) -> UnsafeBufferPointer<Peak> { found[t] }

    /// found(t) と同じ並びの、残したかの印(1 = 残した)。列が空のタイルでは使わない
    @inline(__always) func keep(_ t: Int) -> UnsafeMutablePointer<UInt8> { keepFlags + found.start(t) }

    /// 残したピークの列(列の順。配列を作らない)
    @inline(__always) func kept(_ t: Int) -> KeptPeaks {
        let list = found[t]
        return KeptPeaks(peaks: list, keep: list.isEmpty ? UnsafePointer(keepFlags) : UnsafePointer(keep(t)))
    }
}

/// 1 タイルの残したピークを列の順に返す
struct KeptPeaks: Sequence, IteratorProtocol {
    let peaks: UnsafeBufferPointer<Peak>
    let keep: UnsafePointer<UInt8>
    private var j = 0

    init(peaks: UnsafeBufferPointer<Peak>, keep: UnsafePointer<UInt8>) {
        self.peaks = peaks
        self.keep = keep
    }

    mutating func next() -> Peak? {
        while j < peaks.count {
            let i = j
            j += 1
            if keep[i] != 0 { return peaks[i] }
        }
        return nil
    }
}

/// 1 ページの処理の間だけ使う配列(A2 の節点・成分の表、パス 2 のタイルの並び)を切り出す領域。
/// 仮想記憶の塊から順に切り出し、ページの初めに巻き戻す。足りなければ塊を足し(切り出した領域は動かさない)、
/// 次のページの初めに、それまでに要った大きさの 1 つの塊へまとめ直す
final class ScratchArena {
    private struct Chunk {
        let base: UnsafeMutableRawPointer
        let size: Int
    }

    private var chunks: [Chunk] = []
    private var index = 0
    private var offset = 0
    /// このページで切り出したバイト数(揃えの分を含む)
    private var used = 0
    /// それまでのページで切り出した最大のバイト数
    private var need = 0

    init() {}

    deinit { for c in chunks { PageMemory.deallocate(c.base, c.size) } }

    var byteCount: Int { chunks.reduce(0) { $0 + $1.size } }

    /// ページの初めに呼ぶ。それまでに切り出した領域はもう使わない
    func rewind() {
        need = max(need, used)
        if chunks.count > 1 {
            for c in chunks { PageMemory.deallocate(c.base, c.size) }
            chunks.removeAll(keepingCapacity: true)
        }
        index = 0
        offset = 0
        used = 0
    }

    /// count 個の領域。中身は不定なので、読む前に全部を書くこと
    func take<T: BitwiseCopyable>(_: T.Type, _ count: Int) throws -> UnsafeMutableBufferPointer<T> {
        let align = 64
        let bytes = max(1, count) * MemoryLayout<T>.stride
        while index < chunks.count {
            let at = (offset + align - 1) / align * align
            if at + bytes <= chunks[index].size {
                // まとめ直した 1 つの塊に必ず収まるよう、揃えの最大の分を足して数える
                used += bytes + align
                offset = at + bytes
                let p = (chunks[index].base + at).bindMemory(to: T.self, capacity: max(1, count))
                return UnsafeMutableBufferPointer(start: p, count: count)
            }
            index += 1
            offset = 0
        }
        let page = Int(getpagesize())
        let size = (max(bytes + align, need, used, 1 << 20) + page - 1) / page * page
        guard let base = PageMemory.allocate(size) else {
            throw PrintAppearanceError.allocationFailed("作業域 \(size) バイト")
        }
        chunks.append(Chunk(base: base, size: size))
        index = chunks.count - 1
        offset = 0
        return try take(T.self, count)
    }

    /// count 個を value で埋めた領域
    func take<T: BitwiseCopyable>(_: T.Type, _ count: Int, repeating value: T) throws -> UnsafeMutableBufferPointer<T> {
        let b = try take(T.self, count)
        b.initialize(repeating: value)
        return b
    }
}
