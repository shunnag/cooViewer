import Foundation
import KaitoKit

/// 破損・非対応の子だけを従来どおり除外し、資源不足や I/O 失敗を合本の成功にしない。
enum SourceReadFailure {
    static func mustPropagate(_ error: any Error) -> Bool {
        classify(error, depth: 0)
    }

    private static func classify(_ error: any Error, depth: Int) -> Bool {
        if error is CancellationError { return true }
        if case KaitoError.io = error { return true }
        if case BookSourceError.temporarilyUnavailable = error { return true }
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return true }
        if depth < 4, let underlying = failure.userInfo[NSUnderlyingErrorKey] as? any Error,
           classify(underlying, depth: depth + 1) { return true }
        guard failure.domain == NSCocoaErrorDomain else { return false }
        switch CocoaError.Code(rawValue: failure.code) {
        case .fileReadCorruptFile, .fileReadUnsupportedScheme,
             .fileReadInapplicableStringEncoding, .fileReadUnknownStringEncoding:
            return false
        default:
            return (0..<1024).contains(failure.code)
        }
    }
}
