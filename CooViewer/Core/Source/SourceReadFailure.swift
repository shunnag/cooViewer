import Darwin
import Foundation
import KaitoKit

/// 破損・非対応の子だけを従来どおり除外し、資源不足や I/O 失敗を合本の成功にしない。
enum SourceReadFailure {
    enum RetryClass: Sendable, Equatable {
        case transient, network, reopen, persistent, structural, cancelled
    }

    enum ReadFailureCause: Sendable, Hashable {
        case accessDenied, notFound, diskFull, connectionLost, fileChanged, repeatedFailure
    }

    static func retryClass(_ error: any Error) -> RetryClass {
        let errors = chain(error)
        if errors.contains(where: { $0 is CancellationError }) { return .cancelled }
        if let inner = assemblyFailure(in: error)?.failures.first { return inner.retryClass }
        // Cocoa の一般的な読込失敗より下層の errno を優先する(設計書 §7.4)。
        for error in errors {
            if let code = errno(error) {
                switch code {
                case EMFILE, ENFILE, EAGAIN, ENOMEM: return .transient
                case EIO, ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH,
                     EHOSTDOWN, EHOSTUNREACH, ENXIO, ECONNRESET: return .network
                case ESTALE: return .reopen
                default: break
                }
            }
            if case BookSourceError.temporarilyUnavailable = error { return .transient }
        }
        return mustPropagate(error) ? .persistent : .structural
    }

    static func cause(_ error: any Error) -> ReadFailureCause {
        if let first = assemblyFailure(in: error)?.failures.first { return first.cause }
        for error in chain(error) {
            if let code = errno(error) {
                switch code {
                case EACCES, EPERM, EROFS: return .accessDenied
                case ENOENT, ENOTDIR: return .notFound
                case ENOSPC: return .diskFull
                case ESTALE: return .fileChanged
                case EIO, ETIMEDOUT, ENOTCONN, ENETDOWN, ENETUNREACH,
                     EHOSTDOWN, EHOSTUNREACH, ENXIO, ECONNRESET: return .connectionLost
                default: break
                }
            }
        }
        for error in chain(error) {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain else { continue }
            switch failure.code {
            case 4, 260: return .notFound
            case 257: return .accessDenied
            case 640: return .diskFull
            default: break
            }
        }
        return .repeatedFailure
    }

    static func assemblyFailure(in error: any Error) -> AssemblyFailure? {
        chain(error).compactMap { $0 as? AssemblyFailure }.first
    }

    private static func chain(_ error: any Error) -> [any Error] {
        var result: [any Error] = [error]
        var current = error
        for _ in 0..<4 {
            guard let underlying = (current as NSError).userInfo[NSUnderlyingErrorKey] as? any Error else { break }
            result.append(underlying)
            current = underlying
        }
        return result
    }

    private static func errno(_ error: any Error) -> Int32? {
        if case KaitoError.io(let code) = error { return code }
        let failure = error as NSError
        guard failure.domain == NSPOSIXErrorDomain else { return nil }
        return Int32(exactly: failure.code)
    }

    static func mustPropagate(_ error: any Error) -> Bool {
        classify(error, depth: 0)
    }

    private static func classify(_ error: any Error, depth: Int) -> Bool {
        // 内側の合本失敗を破損扱いで捨てるとページ欠落が再発する(設計書 §7.4)。
        if error is AssemblyFailure { return true }
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
