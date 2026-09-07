// XADMaster をブラックボックスのオラクルとして使い、書庫の各エントリの SHA-256 を出力する。
// KaitoKit の `kaito sha` と同じ行形式(index \t size \t sha256 \t name)で、
// 総合ダイジェストは各エントリのダイジェスト(16 進文字列)を順に連結した SHA-256。
// ディレクトリ・サイズ 0 のエントリは size 0・空データのダイジェストで出力する。
// 使い方: xadsha <archive> [password]   (KaitoKit との差分検証・文字コード判定の比較用)
import Foundation
import CryptoKit
import XADMaster

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: xadsha <archive> [password]\n".data(using: .utf8)!)
    exit(2)
}
guard let archive = XADArchive(file: args[1]) else {
    FileHandle.standardError.write("error: cannot open \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
if args.count >= 3 { archive.setPassword(args[2]) }
var total = SHA256()
let count = archive.numberOfEntries()
for i in 0..<count {
    let name = archive.name(ofEntry: i) ?? ""
    var data = Data()
    if !archive.entryIsDirectory(i) {
        data = archive.contents(ofEntry: i) ?? Data()
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    total.update(data: Data(digest.utf8))
    print("\(i)\t\(data.count)\t\(digest)\t\(name)")
}
let totalDigest = total.finalize().map { String(format: "%02x", $0) }.joined()
print("total\t\(count)\t\(totalDigest)\t")
