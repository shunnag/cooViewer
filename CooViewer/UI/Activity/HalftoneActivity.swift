import Foundation
import PrintAppearanceKit

extension ActivitySnapshot {
    /// アクティビティ窓の「網かけの表示」の節(設計書 §5)。値は PrintAppearanceService.stats() と
    /// 設定・本の先読みの実効値だけから組み、サービスが持たない値は出さない(捏造しない。設計書 §2.4)
    struct Halftone: Sendable, Equatable {
        /// 先読みの計画(本を開いているときだけ)
        struct Plan: Sendable, Equatable {
            let prefetchAhead: Int
            let prefetchBehind: Int
            let prefetchWidth: Int
        }

        let enabled: Bool
        let level: PrintAppearanceLevel
        let stats: PrintAppearanceService.Stats
        let plan: Plan?
        let displayThreads: Int
        /// 実効の先読みの並列数(省エネ中は少ない方)
        let prefetchThreads: Int
        let maxPixels: Int

        /// 節を出すか: 入れているか、このプロセスでエンジンが動いたことがあるとき
        /// (一度も使っていない利用者の窓を増やさない)
        static func isRelevant(enabled: Bool, stats: PrintAppearanceService.Stats) -> Bool {
            enabled || stats.engine != nil || stats.isWarmingUp || stats.processedPages > 0
                || !stats.passedThrough.isEmpty
        }

        /// 表示する行(計画=📐 / 実態=●)
        var rows: [Resources.Row] {
            var rows = [Resources.Row(label: String(localized: "Setting"), value: "📐 " + settingText)]
            rows.append(Resources.Row(label: String(localized: "Engine"), value: "● " + engineText))
            if let engine = stats.engine {
                rows.append(Resources.Row(
                    label: String(localized: "Working memory"),
                    value: "● " + (engine.workingBytes > 0
                        ? Self.byteText(engine.workingBytes) : String(localized: "Released"))))
            }
            rows.append(Resources.Row(
                label: String(localized: "Pages processed"),
                value: "● \(stats.processedPages) · " + String(localized: "unchanged")
                    + " \(stats.unchangedPages)"))
            rows.append(Resources.Row(label: String(localized: "Passed through"), value: "● " + passThroughText))
            rows.append(Resources.Row(label: String(localized: "Failed / refused"),
                                      value: "● \(stats.failedPages) / \(stats.refusedPages)"))
            rows.append(Resources.Row(label: String(localized: "Waiting (display / prefetch)"),
                                      value: "● \(stats.waitingDisplay) / \(stats.waitingPrefetch)"))
            rows.append(Resources.Row(label: String(localized: "Pre-emptions / shed"),
                                      value: "● \(stats.preemptions) / \(stats.shedJobs)"))
            rows.append(Resources.Row(
                label: String(localized: "Last page (prepare · wait · engine)"),
                value: "● " + Self.timesText(stats.lastPrepareMilliseconds, stats.lastWaitMilliseconds,
                                            stats.lastEngineMilliseconds)))
            rows.append(Resources.Row(
                label: String(localized: "Median of recent pages"),
                value: "● " + Self.timesText(stats.medianPrepareMilliseconds, stats.medianWaitMilliseconds,
                                            stats.medianEngineMilliseconds)))
            rows.append(Resources.Row(label: String(localized: "Last compile"),
                                      value: "● " + Self.millisecondsText(stats.engine?.compileMilliseconds)))
            if let plan {
                rows.append(Resources.Row(label: String(localized: "Prefetch depth / width"),
                                          value: "📐 \(plan.prefetchAhead) / \(plan.prefetchWidth)"))
            }
            rows.append(Resources.Row(label: String(localized: "Threads (display / prefetch)"),
                                      value: "📐 \(displayThreads) / \(prefetchThreads)"))
            return rows
        }

        var settingText: String {
            guard enabled else { return String(localized: "As scanned") }
            return String(localized: "Like the printed book") + " · " + Self.levelName(level)
        }

        var engineText: String {
            var text: String
            if stats.isWarmingUp {
                text = String(localized: "Preparing…")
            } else {
                switch stats.engine?.path {
                case nil: text = enabled ? String(localized: "Not started") : String(localized: "Off")
                case .idle: text = String(localized: "Idle")
                case .gpu: text = "GPU"
                case .cpuOnly(let reason): text = String(localized: "CPU only") + " (" + Self.reasonText(reason) + ")"
                }
            }
            if stats.isRunning { text += " · " + String(localized: "processing") }
            return text
        }

        /// 素通しの理由ごとの数(0 の理由は出さない)
        var passThroughText: String {
            let parts = PrintAppearancePassReason.allCases.compactMap { reason -> String? in
                guard let count = stats.passedThrough[reason], count > 0 else { return nil }
                return Self.reasonName(reason) + " \(count)"
            }
            return parts.isEmpty ? "0" : parts.joined(separator: " · ")
        }

        static func levelName(_ level: PrintAppearanceLevel) -> String {
            switch level {
            case .low: String(localized: "Subtle")
            case .standard: String(localized: "Standard")
            case .strong: String(localized: "Strong")
            }
        }

        static func reasonName(_ reason: PrintAppearancePassReason) -> String {
            switch reason {
            case .colour: String(localized: "Color")
            case .small: String(localized: "Small")
            case .tooLarge: String(localized: "Too large")
            case .aspect: String(localized: "Aspect ratio")
            case .orientation: String(localized: "Orientation")
            case .transparency: String(localized: "Transparency")
            case .format: String(localized: "Format")
            }
        }

        static func reasonText(_ reason: PrintAppearanceCPUOnlyReason) -> String {
            switch reason {
            case .requested: String(localized: "requested")
            case .gpuUnavailable: String(localized: "GPU unavailable")
            case .repeatedGPUFailures: String(localized: "repeated GPU failures")
            }
        }

        /// 「準備 · 待ち · エンジン」の 3 つの時間。未計測は —
        static func timesText(_ prepare: Double?, _ wait: Double?, _ engine: Double?) -> String {
            [prepare, wait, engine].map { $0.map { String(format: "%.0f", $0) } ?? "—" }
                .joined(separator: " · ") + " ms"
        }

        static func millisecondsText(_ value: Double?) -> String {
            value.map { String(format: "%.0f ms", $0) } ?? "—"
        }

        private static func byteText(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        }
    }
}

extension ActivitySnapshot.Halftone {
    /// いまの設定・本・サービスから組む(アクティビティ窓と --dump-print-appearance-stats で共通)。
    /// サービスの状態を読むだけで、エンジンは作らない
    @MainActor
    static func current(book: Book?, settings: SettingsStore = .shared,
                        service: PrintAppearanceService = .shared,
                        conserving: Bool = PowerStateMonitor.shared.shouldConserveEnergy) -> Self {
        let plan = book.map { book in
            Plan(prefetchAhead: book.prefetchAhead, prefetchBehind: book.prefetchBehind,
                 prefetchWidth: PreresamplePolicy.decodeWidth(
                     mediaConcurrency: book.mediaProfile.bookPrefetchConcurrency,
                     printAppearance: book.printAppearanceLevel != nil))
        }
        let configuration = service.configuration
        return Self(enabled: settings.halftoneDisplayEnabled, level: settings.halftoneDisplayStrength,
                    stats: service.stats(), plan: plan, displayThreads: configuration.displayThreads,
                    prefetchThreads: conserving ? configuration.conservingPrefetchThreads
                        : configuration.prefetchThreads,
                    maxPixels: service.maxPixels)
    }
}

/// --dump-print-appearance-stats の JSON(設計書 §5)。性能の測定で読むので、キーは英語の固定名にし、
/// 並びも固定する(sortedKeys)。未計測の値は null
enum PrintAppearanceStatsReport {
    static func json(_ halftone: ActivitySnapshot.Halftone) -> Data {
        let stats = halftone.stats
        func number(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
        var engine: [String: Any] = [
            "warmingUp": stats.isWarmingUp,
            "running": stats.isRunning,
        ]
        if let status = stats.engine {
            switch status.path {
            case .idle: engine["path"] = "idle"
            case .gpu: engine["path"] = "gpu"
            case .cpuOnly(let reason):
                engine["path"] = "cpuOnly"
                switch reason {
                case .requested: engine["cpuOnlyReason"] = "requested"
                case .gpuUnavailable(let detail): engine["cpuOnlyReason"] = "gpuUnavailable: \(detail)"
                case .repeatedGPUFailures: engine["cpuOnlyReason"] = "repeatedGPUFailures"
                }
            }
            engine["workingBytes"] = status.workingBytes
            engine["gpuFallbackPages"] = status.gpuFallbackPages
            engine["compileMilliseconds"] = number(status.compileMilliseconds)
        } else {
            engine["path"] = "notCreated"
        }
        var passedThrough: [String: Any] = [:]
        for reason in PrintAppearancePassReason.allCases {
            passedThrough[String(describing: reason)] = stats.passedThrough[reason] ?? 0
        }
        var plan: [String: Any] = [
            "displayThreads": halftone.displayThreads,
            "prefetchThreads": halftone.prefetchThreads,
            "maxPixels": halftone.maxPixels,
        ]
        if let bookPlan = halftone.plan {
            plan["prefetchAhead"] = bookPlan.prefetchAhead
            plan["prefetchBehind"] = bookPlan.prefetchBehind
            plan["prefetchWidth"] = bookPlan.prefetchWidth
        }
        let level: String = switch halftone.level {
        case .low: "low"
        case .standard: "standard"
        case .strong: "strong"
        }
        let root: [String: Any] = [
            "setting": ["enabled": halftone.enabled, "level": level],
            "engine": engine,
            "pages": [
                "processed": stats.processedPages,
                "unchanged": stats.unchangedPages,
                "refused": stats.refusedPages,
                "failed": stats.failedPages,
                "passedThrough": passedThrough,
            ],
            "queue": [
                "waitingDisplay": stats.waitingDisplay,
                "waitingPrefetch": stats.waitingPrefetch,
                "shed": stats.shedJobs,
                "preemptions": stats.preemptions,
                "promotions": stats.promotions,
                "declined": stats.declinedJobs,
                "cancelled": stats.cancelledJobs,
                "storeReleases": stats.storeReleases,
                "reservations": stats.reservations,
            ],
            "milliseconds": [
                "lastPrepare": number(stats.lastPrepareMilliseconds),
                "medianPrepare": number(stats.medianPrepareMilliseconds),
                "lastWait": number(stats.lastWaitMilliseconds),
                "medianWait": number(stats.medianWaitMilliseconds),
                "lastEngine": number(stats.lastEngineMilliseconds),
                "medianEngine": number(stats.medianEngineMilliseconds),
                "lastPage": number(stats.lastPageMilliseconds),
                "medianPage": number(stats.medianPageMilliseconds),
                "lastWarmUp": number(stats.lastWarmUpMilliseconds),
            ],
            "medianWindow": PrintAppearanceService.timingWindow,
            "plan": plan,
        ]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
