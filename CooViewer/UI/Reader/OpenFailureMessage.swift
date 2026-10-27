import Foundation

/// 原因の詳細や絶対パスを漏らさず、再読込の判断に必要な名前だけを示す(設計書 §7.4)。
enum OpenFailureMessage {
    static func text(for failure: AssemblyFailure, bookName: String, automaticRetryArmed: Bool = true,
                     bundle: Bundle = .main, locale: Locale = .current) -> String {
        var lines = [String(localized: "Could not open “\(bookName)”.", bundle: bundle)]
        if failure.volumeUnavailable {
            lines.append(unavailable(automaticRetryArmed: automaticRetryArmed, bundle: bundle))
        } else {
            let failures = failure.failures
            if !failures.isEmpty {
                let count = failures.count
                lines.append(String(localized: "Could not read the following \(count) books:", bundle: bundle, locale: locale))
                for child in failures.prefix(3) {
                    let name = EntryNameFormatter.forDisplay((child.relativePath as NSString).lastPathComponent, limit: 120)
                    let reason = causeText(child.cause, bundle: bundle)
                    lines.append(String(localized: "• \(name) — \(reason)", bundle: bundle))
                }
                if failures.count > 3 {
                    let remainder = failures.count - 3
                    lines.append(String(localized: "• \(remainder) more books", bundle: bundle, locale: locale))
                }
            }
        }
        if failure.unchecked > 0 {
            let count = failure.unchecked
            if failure.volumeUnavailable || failure.failures.isEmpty {
                lines.append(String(localized: "Could not check \(count) books.", bundle: bundle, locale: locale))
            } else {
                lines.append(String(localized: "Could not check \(count) additional books.", bundle: bundle, locale: locale))
            }
        }
        lines.append(incomplete(bundle: bundle))
        return lines.joined(separator: "\n")
    }

    static func textForNotFound(bookName: String, volumeUnavailable: Bool = false,
                                automaticRetryArmed: Bool = true, bundle: Bundle = .main) -> String {
        if volumeUnavailable {
            return [String(localized: "Could not open “\(bookName)”.", bundle: bundle),
                    unavailable(automaticRetryArmed: automaticRetryArmed, bundle: bundle)]
                .joined(separator: "\n")
        }
        return String(localized: "“\(bookName)” could not be found (it may have been moved or deleted).",
                      bundle: bundle)
    }

    private static func unavailable(automaticRetryArmed: Bool, bundle: Bundle) -> String {
        if automaticRetryArmed {
            return String(localized: "The storage location is unavailable. It will reload automatically when the volume is reconnected or the Mac wakes.", bundle: bundle)
        }
        return String(localized: "The storage location is unavailable. Choose Reload when the connection returns.", bundle: bundle)
    }

    private static func incomplete(bundle: Bundle) -> String {
        String(localized: "The book will not be displayed with missing pages.", bundle: bundle)
    }

    static func causeText(_ cause: ReadFailureCause, bundle: Bundle = .main) -> String {
        switch cause {
        case .accessDenied: String(localized: "Access denied", bundle: bundle)
        case .notFound: String(localized: "File not found (it may have been moved or deleted)", bundle: bundle)
        case .diskFull: String(localized: "Not enough disk space", bundle: bundle)
        case .connectionLost: String(localized: "Connection lost", bundle: bundle)
        case .fileChanged: String(localized: "The file changed while reading", bundle: bundle)
        case .repeatedFailure: String(localized: "Reading failed repeatedly", bundle: bundle)
        }
    }
}
