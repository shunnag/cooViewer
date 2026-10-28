import CryptoKit
import Foundation
import KaitoKit

// pl7x 計測: 1 process で open → 先頭 → 50% 位置 → 末尾まで を測り、JSON 1 行を出す。
let args = CommandLine.arguments
guard args.count >= 4 else { fatalError("usage: pl7x <archive> <revision> <state>") }
let url = URL(fileURLWithPath: args[1])
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1e6 }
var hasher = SHA256()
let t0 = now()
let reader = try ArchiveReader.open(url: url)
let t1 = now()
let files = reader.entries.filter { $0.kind != .directory }
let first = files[0]
let mid = files.count / 2
let d0 = try reader.read(first); hasher.update(data: d0)
let t2 = now()
let dj = try reader.read(files[mid]); hasher.update(data: dj)
let t3 = now()
var steadyBytes = 0
for e in files[(mid + 1)...] { let d = try reader.read(e); steadyBytes += d.count; hasher.update(data: d) }
let t4 = now()
let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
let steadyMs = ms(t3, t4)
let line: [String: Any] = [
    "rev": args[2], "state": args[3], "archive": url.lastPathComponent, "entries": files.count,
    "open_ms": ms(t0, t1), "first_ms": ms(t1, t2), "jump_ms": ms(t2, t3), "steady_ms": steadyMs,
    "steady_mbps": Double(steadyBytes) / 1e6 / (steadyMs / 1e3),
    "cum_first_ms": ms(t0, t2), "cum_jump_ms": ms(t0, t3), "sha": String(sha.prefix(16)),
]
let json = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
