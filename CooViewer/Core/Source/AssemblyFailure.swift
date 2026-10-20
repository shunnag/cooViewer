import Foundation

typealias RetryClass = SourceReadFailure.RetryClass
typealias ReadFailureCause = SourceReadFailure.ReadFailureCause

struct ChildReadFailure: Sendable, Equatable {
    let relativePath: String
    let url: URL
    let cause: ReadFailureCause
    let retryClass: RetryClass

    init(relativePath: String, url: URL, cause: ReadFailureCause, retryClass: RetryClass) {
        self.relativePath = relativePath
        self.url = url
        self.cause = cause
        self.retryClass = retryClass
    }

    init(relativePath: String, url: URL, error: any Error) {
        self.init(relativePath: relativePath, url: url,
                  cause: SourceReadFailure.cause(error), retryClass: SourceReadFailure.retryClass(error))
    }
}

/// 環境要因の子をまとめ、破損の黙殺とは区別して外側へ渡す(仕様書 §4.17、設計書 §7.4)。
struct AssemblyFailure: Error, CustomNSError, Sendable {
    let failures: [ChildReadFailure]
    let total: Int
    let unchecked: Int
    let volumeUnavailable: Bool
    let sourceURL: URL
    /// 期限切れはマウント通知で回復を検知できるとは限らず、手動再読込の案内へ切り替える(設計書 §7.4)。
    let reachabilityTimedOut: Bool
    private let underlyingError: (any Error)?

    init(failures: [ChildReadFailure], total: Int, unchecked: Int = 0,
         volumeUnavailable: Bool = false, sourceURL: URL, reachabilityTimedOut: Bool = false,
         underlyingError: (any Error)? = nil) {
        self.failures = failures
        self.total = total
        self.unchecked = unchecked
        self.volumeUnavailable = volumeUnavailable
        self.sourceURL = sourceURL
        self.reachabilityTimedOut = reachabilityTimedOut
        self.underlyingError = underlyingError
    }

    static var errorDomain: String { "jp.coo.cooViewer.AssemblyFailure" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] {
        // 元エラーを残すと既存の分類・診断でも環境要因を辿れる(設計書 §7.4)。
        guard let underlyingError else { return [:] }
        return [NSUnderlyingErrorKey: underlyingError]
    }
}
