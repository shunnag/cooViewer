import Darwin
import Foundation
import KaitoKit

// 引数は生成済みの合成入力だけ。実書庫の内容・パスを出力しない。
@main struct FileAccessPerformanceProbe {
    static func main() throws {
        let mode = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        if mode.hasPrefix("archive") {
            var options = ReaderOptions()
            #if CURRENT
            if mode.hasSuffix("bounded") { options.fileAccessPolicy = .bounded }
            #endif
            let urls = (0..<300).map { url.appendingPathComponent("book-\($0).zip") }
            for round in 0..<7 {
                let start = ProcessInfo.processInfo.systemUptime
                let readers = try urls.map { try ArchiveReader.open(url: $0, options: options) }
                let opened = ProcessInfo.processInfo.systemUptime
                var bytes = 0
                for _ in 0..<5 {
                    for reader in readers { bytes += try reader.read(reader.entries[0]).count }
                }
                let end = ProcessInfo.processInfo.systemUptime
                print("ARCHIVE", mode, "round", round, "books", readers.count, "bytes", bytes,
                    "open_ms", (opened - start) * 1000, "revisit_ms", (end - opened) * 1000)
                withExtendedLifetime(readers) {}
            }
            return
        }
        let chunk = 256 * 1024
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 64)
        defer { buffer.deallocate() }
        let source: FileByteSource
        #if CURRENT
        source = try FileByteSource(url: url, accessPolicy: mode == "bounded" ? .bounded : .persistent)
        #else
        source = try FileByteSource(url: url)
        #endif
        var checksum: UInt64 = 0
        for round in 0..<7 {
            let start = ProcessInfo.processInfo.systemUptime
            var bytes = 0
            for _ in 0..<32 {
                var offset: UInt64 = 0
                while offset < source.length {
                    let count = try source.read(into: buffer, at: offset)
                    precondition(count > 0)
                    checksum &+= UInt64(buffer[0])
                    bytes += count
                    offset += UInt64(count)
                }
            }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            print("IO", mode, "round", round, "MiB", bytes / 1048576,
                  "milliseconds", seconds * 1000, "checksum", checksum)
        }
    }
}
