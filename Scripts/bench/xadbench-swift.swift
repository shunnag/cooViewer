// Swift ブリッジ計測ハーネス: contentsOfEntry: の NSData→Data ブリッジコストを測る。
// 使い方: xadbench-swift <archive> <reps>
// ObjC 版 extract と同じ順序・同じ検証で、Swift の Data として受け取る(cooViewer 実態)。
import Foundation
import CryptoKit
import XADMaster

func nowMS() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }

let args = CommandLine.arguments
guard args.count >= 3, let reps = Int(args[2]) else {
    FileHandle.standardError.write(Data("usage: xadbench-swift <archive> <reps>\n".utf8))
    exit(2)
}
let path = args[1]
guard let a = XADArchive(file: path) else { exit(1) }
let n = a.numberOfEntries()
var files: [Int32] = []
for i in 0..<n where !a.entryIsDirectory(i) { files.append(i) }

var repMs: [Double] = []
var totalBytes: UInt64 = 0
var overall = SHA256()
var hashed = false
for r in 0..<reps {
    let t0 = nowMS()
    for i in files {
        autoreleasepool {
            guard let d: Data = a.contents(ofEntry: i) else { exit(1) }
            totalBytes += UInt64(d.count)
            if r == 0 {
                overall.update(data: Data(SHA256.hash(data: d)))
                hashed = true
            }
        }
    }
    repMs.append(nowMS() - t0)
}
var json = "{\"mode\":\"swift-extract\",\"archive\":\"\((path as NSString).lastPathComponent)\","
json += "\"entries\":\(n),\"bytes\":\(totalBytes),\"rep_ms\":["
json += repMs.map { String(format: "%.2f", $0) }.joined(separator: ",")
json += "]"
if hashed {
    json += ",\"sha256\":\"" + overall.finalize().map { String(format: "%02x", $0) }.joined() + "\""
}
json += "}"
print(json)
