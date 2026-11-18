import Darwin
import Foundation

// ページ大の一時領域を仮想記憶から直接確保する(設計書 §2.3)。
// malloc の大きな確保は、手放した後も large-entry キャッシュに汚れたまま残り、プロセスの使用量に数えられ続ける
// (網点処理を入れた本で、最後のページ送りから 30 秒後も 140〜200 MB 多く残った。MallocLargeCache=0 で消えることで
// 確かめた)。輝度・エンジンの出力・色を戻した出力・描き直し・縮小の出力と一時領域、CPU の経路の記憶域と作業面は
// ここから確保し、手放したときにすぐ OS へ返す。vm_allocate の領域は 0 で埋まっている。

/// 仮想記憶から確保した、書き換えられるページ大の領域。手放すと vm_deallocate で OS へ返す。
/// 中身を書き終えたら読むだけにする使い方を前提に @unchecked Sendable とする(書く側は作った処理だけ)
final class PageBuffer: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let byteCount: Int

    /// 0 で埋めた byteCount バイト(0 なら 1 バイト分の頁を確保する)
    init(byteCount: Int) throws {
        guard let base = PageMemory.allocate(byteCount) else {
            throw PrintAppearanceError.allocationFailed("ページの領域 \(byteCount) バイト")
        }
        self.base = base
        self.byteCount = byteCount
    }

    deinit { PageMemory.deallocate(base, byteCount) }

    var bytes: UnsafeMutablePointer<UInt8> { base.assumingMemoryBound(to: UInt8.self) }
}

enum PageMemory {
    /// 0 で埋めた領域を確保する。確保できなければ nil
    static func allocate(_ byteCount: Int) -> UnsafeMutableRawPointer? {
        var address: vm_address_t = 0
        guard byteCount >= 0,
              vm_allocate(mach_task_self_, &address, vm_size_t(max(1, byteCount)), VM_FLAGS_ANYWHERE) == KERN_SUCCESS
        else { return nil }
        return UnsafeMutableRawPointer(bitPattern: UInt(address))
    }

    static func deallocate(_ base: UnsafeMutableRawPointer, _ byteCount: Int) {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: base)), vm_size_t(max(1, byteCount)))
    }

    /// 0 で埋めた byteCount バイトの Data。中身は仮想記憶にあり、Data を手放すと OS へ返る
    /// (CFData へ橋渡ししても複製されない)。fill で中身を書いてから返す。
    /// 確保できないときは従来どおり Data(count:) にする(どちらも確保できなければ止まるのは従来と同じ)
    static func zeroedData(byteCount: Int, fill: (UnsafeMutablePointer<UInt8>) throws -> Void) rethrows -> Data {
        guard byteCount > 0, let base = allocate(byteCount) else {
            var data = Data(count: byteCount)
            try data.withUnsafeMutableBytes { raw in
                if let pointer = raw.bindMemory(to: UInt8.self).baseAddress { try fill(pointer) }
            }
            return data
        }
        do {
            try fill(base.assumingMemoryBound(to: UInt8.self))
        } catch {
            deallocate(base, byteCount)
            throw error
        }
        return Data(bytesNoCopy: base, count: byteCount, deallocator: .virtualMemory)
    }
}
