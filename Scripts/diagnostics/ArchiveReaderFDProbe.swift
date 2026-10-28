import Foundation
import Darwin
import KaitoKit

func fdCount() -> Int {
    (0..<4096).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
}
@main struct Probe {
    static func main() throws {
        setbuf(stdout, nil)
        let mode = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let data = try Data(contentsOf: url)
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        let original = limit.rlim_cur
        limit.rlim_cur = 256
        precondition(setrlimit(RLIMIT_NOFILE, &limit) == 0)
        defer { limit.rlim_cur = original; setrlimit(RLIMIT_NOFILE, &limit) }
        var readers: [ArchiveReader] = []
        let options = ReaderOptions(appleDoublePolicy: .expose)
        print("before",fdCount())
        for i in 0..<500 {
            do {
                let reader: ArchiveReader
                if mode == "memory" { reader = try ArchiveReader.open(data: data, options: options) }
                else { reader = try ArchiveReader.open(url: url, options: options) }
                readers.append(reader)
                if (i+1)%50 == 0 { print("retained",i+1,"fds",fdCount()) }
            } catch {
                print("FAILED",i,"fds",fdCount(),"error",error)
                break
            }
        }
        let extra = Darwin.open("/dev/null",O_RDONLY)
        print("spare-open",extra,"errno",extra < 0 ? errno : 0)
        if extra >= 0 { Darwin.close(extra) }
        withExtendedLifetime(readers) { print("retained-final",readers.count,"fds",fdCount()) }
        readers.removeAll()
        print("released",fdCount())
    }
}
