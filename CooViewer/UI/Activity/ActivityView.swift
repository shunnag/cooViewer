import SwiftUI

/// アクティビティ窓の本体。読み込み・リサンプル・先読み・スプール・ML・
/// メモリの「計画(予算・予定)と実態(進行中・完了・使用量)」を live 表示。
/// 各行は計画=📐 / 実態=● のラベルで区別する
struct ActivityView: View {
    @ObservedObject var monitor: ActivityMonitor
    /// 検証時(ImageRenderer)は ScrollView を外す(headless で内容が消えるため)
    var embedInScroll = true
    /// 「常に最前面に表示」の切替を窓へ伝えるコールバック(AppDelegate が配線)
    var setAlwaysOnTop: (Bool) -> Void = { _ in }

    /// チェック状態は defaults に永続化(次回起動でも維持)
    @AppStorage("ActivityAlwaysOnTop") private var alwaysOnTop = false

    private var s: ActivitySnapshot { monitor.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            if embedInScroll {
                ScrollView { sections.padding(20) }
                    .frame(minWidth: 380, minHeight: 380)
            } else {
                sections.padding(20)
            }
            Divider()
            footer
        }
        .onAppear { setAlwaysOnTop(alwaysOnTop) }
        .onChange(of: alwaysOnTop) { setAlwaysOnTop(alwaysOnTop) }
    }

    private var footer: some View {
        HStack {
            Toggle(String(localized: "Keep window on top"), isOn: $alwaysOnTop)
                .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let book = s.book {
                bookSection(book)
                if let loading = s.loading { loadingSection(loading) }
                if let resample = s.resample { resampleSection(resample) }
                if let lru = s.lru { lruSection(lru) }
                if let plan = s.prefetchPlan { prefetchPlanSection(plan) }
                if let spool = s.spool { spoolSection(spool) }
                mlSection(s.ml)
                if let memory = s.memory { memorySection(memory) }
            } else {
                Text(String(localized: "No book is open."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
                mlSection(s.ml)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - セクション

    private func bookSection(_ b: ActivitySnapshot.BookInfo) -> some View {
        section(String(localized: "Book")) {
            row(String(localized: "Name"), b.name)
            row(String(localized: "Type"), b.kind)
            row(String(localized: "Storage"), b.media)
            row(String(localized: "Position"), "\(b.currentPage) / \(b.pageCount)")
            if b.encrypted {
                row(String(localized: "Encrypted"), String(localized: "Yes"))
            }
        }
    }

    private func loadingSection(_ l: ActivitySnapshot.Loading) -> some View {
        section(String(localized: "Loading (decode & prefetch)")) {
            planRow(String(localized: "Prefetch ahead"),
                    plan: "\(l.planAhead)", actual: "\(l.actualAhead)")
            planRow(String(localized: "Prefetch behind"),
                    plan: "\(l.planBehind)", actual: "\(l.actualBehind)")
            planOnly(String(localized: "Prefetch concurrency"), "\(l.concurrency)")
            actualOnly(String(localized: "Decodes in flight"), "\(l.inFlightDecodes)")
            actualOnly(String(localized: "Displayed pages"), "\(l.displayCount)")
        }
    }

    private func resampleSection(_ r: ActivitySnapshot.Resample) -> some View {
        section(String(localized: "Resampling (interpolation)")) {
            planOnly(String(localized: "Interpolation"), r.interpolation)
            planOnly(String(localized: "ML level"), r.noiseLevel)
            actualOnly(String(localized: "Displayed spread"),
                       r.displayActive ? String(localized: "Resampling…")
                                       : String(localized: "Idle"))
            actualOnly(String(localized: "Requests in flight / done"),
                       "\(r.inFlightRequests) / \(r.completed)")
            if r.prefetchPlanned > 0 {
                // 先読みリサンプルの残り(残 N / 計画 M ページ)
                actualOnly(String(localized: "Prefetch resample remaining"),
                           String(localized: "\(r.prefetchRemaining) / \(r.prefetchPlanned) pages"))
            } else {
                actualOnly(String(localized: "Prefetch resample remaining"),
                           String(localized: "Idle"))
            }
            if let id = r.processingEntryID {
                actualOnly(String(localized: "Prefetching page id"), "\(id)")
            }
        }
    }

    private func lruSection(_ l: ActivitySnapshot.LRU) -> some View {
        section(String(localized: "Resample cache")) {
            actualOnly(String(localized: "Entries"), "\(l.count)")
            usageRow(String(localized: "Memory used"),
                     used: Int64(l.usedBytes), limit: Int64(l.limitBytes))
        }
    }

    private func prefetchPlanSection(_ p: ActivitySnapshot.PrefetchPlan) -> some View {
        section(String(localized: "Prefetch budget")) {
            planOnly(String(localized: "Max pages"), "\(p.pageBudget)")
            planOnly(String(localized: "Memory budget"), byteText(Int64(p.byteBudget)))
        }
    }

    private func spoolSection(_ s: ActivitySnapshot.Spool) -> some View {
        section(String(localized: "Archive spool")) {
            actualOnly(String(localized: "Spooled"),
                       "\(s.spooled) / \(s.total)"
                       + (s.active ? " " + String(localized: "(active)") : ""))
            usageRow(String(localized: "Disk used"), used: s.bytes, limit: s.limitBytes)
        }
    }

    private func mlSection(_ m: ActivitySnapshot.ML) -> some View {
        section(String(localized: "ML models")) {
            row(String(localized: "Denoise (Very High)"), m.noiseState)
            row(String(localized: "Super-resolution (Maximum)"), m.superResState)
            usageRowCount(String(localized: "Disk cache"),
                          count: m.diskCount, bytes: m.diskBytes)
            if m.encrypted {
                row(String(localized: "Cache"), String(localized: "Encrypted"))
            }
        }
    }

    private func memorySection(_ m: ActivitySnapshot.Memory) -> some View {
        section(String(localized: "Memory")) {
            row(String(localized: "Physical RAM"), byteText(m.physical))
            if let resident = m.resident {
                row(String(localized: "App footprint"), byteText(resident))
            }
            usageRowCount(String(localized: "Decode cache"),
                          count: m.pageCacheCount, bytes: Int64(m.pageCacheBytes),
                          limit: Int64(m.pageCacheLimit))
            if let cap = m.displayCap {
                planOnly(String(localized: "Display pixel cap"), "\(cap) px")
            }
            if m.zoomScale > 1.001 {
                actualOnly(String(localized: "Zoom"),
                           String(format: "%.1f×", m.zoomScale))
            }
        }
    }

    // MARK: - 行・整形ヘルパ

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    /// 計画=📐 と実態=● を左に添える
    private func planRow(_ label: String, plan: String, actual: String) -> some View {
        row(label, "📐 " + plan + "   ● " + actual)
    }
    private func planOnly(_ label: String, _ value: String) -> some View {
        row(label, "📐 " + value)
    }
    private func actualOnly(_ label: String, _ value: String) -> some View {
        row(label, "● " + value)
    }

    /// 使用量/上限のバー付き行(実態)
    private func usageRow(_ label: String, used: Int64, limit: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("● " + byteText(used) + " / 📐 " + byteText(limit))
            }
            .font(.callout)
            usageBar(fraction: limit > 0 ? Double(used) / Double(limit) : 0)
        }
    }

    private func usageRowCount(_ label: String, count: Int, bytes: Int64,
                               limit: Int64? = nil) -> some View {
        if let limit {
            return AnyView(VStack(alignment: .leading, spacing: 3) {
                row(label, "● \(count) " + String(localized: "items") + " · "
                    + byteText(bytes) + " / 📐 " + byteText(limit))
                usageBar(fraction: limit > 0 ? Double(bytes) / Double(limit) : 0)
            })
        }
        return AnyView(row(label, "\(count) " + String(localized: "items")
                           + " · " + byteText(bytes)))
    }

    /// 使用率バー(自前描画。ProgressView は ImageRenderer で描けないため)
    private func usageBar(fraction: Double) -> some View {
        let clamped = min(1, max(0, fraction))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(clamped > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: max(2, geo.size.width * clamped))
            }
        }
        .frame(height: 6)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
