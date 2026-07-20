import SwiftUI
import Charts
import AppKit

struct LimitHistoryChart: View {
    @Environment(AppState.self) private var state
    @State private var range: HistoryRange = .day
    @State private var service: ServiceID = .claude
    @State private var selectedDate: Date?

    enum HistoryRange: String, CaseIterable, Identifiable {
        case half = "12h", day = "24h", threeDays = "3d", week = "7d", month = "30d", quarter = "90d"
        var id: String { rawValue }
        var seconds: Double {
            switch self {
            case .half: return 12 * 3600
            case .day: return 86400
            case .threeDays: return 3 * 86400
            case .week: return 7 * 86400
            case .month: return 30 * 86400
            case .quarter: return 90 * 86400
            }
        }
    }

    /// One 5-hour session window, reconstructed from recorded samples.
    struct SessionWindow: Identifiable {
        let id: String
        let start: Date
        let end: Date
        var samples: [LimitSnapshot]

        var peak: Double { samples.map(\.usedPercent).max() ?? 0 }
        var timeToLimit: TimeInterval? {
            guard let hit = samples.first(where: { $0.usedPercent >= 100 }) else { return nil }
            let t = hit.ts.timeIntervalSince(start)
            return t > 0 ? t : nil
        }
    }

    /// Chart data is cached here: hover (chartXSelection) re-evaluates the
    /// body on every mouse move, and recomputing this — a scan + grouping
    /// over the whole 90-day history — per move froze the UI.
    private struct Derived {
        var sessionWindows: [SessionWindow] = []
        var overlaySeries: [(key: String, name: String, samples: [LimitSnapshot])] = []
        var hasData = false
    }
    @State private var derived = Derived()

    /// Bucket-max downsampling to ≤ ~1500 points per series so long ranges
    /// stay cheap to re-render while hovering. Keeping the bucket maximum
    /// preserves the peaks the chart exists to show.
    private static func downsample(_ samples: [LimitSnapshot], rangeSeconds: TimeInterval) -> [LimitSnapshot] {
        let bucket = rangeSeconds / 1500
        guard bucket > 60 else { return samples }
        var best: [String: LimitSnapshot] = [:]
        for s in samples {
            let key = "\(s.seriesKey)|\(Int(s.ts.timeIntervalSince1970 / bucket))"
            if let cur = best[key], cur.usedPercent >= s.usedPercent { continue }
            best[key] = s
        }
        return Array(best.values)
    }

    /// 5-hour windows (windowMinutes == 300) keyed by resets_at rounded to
    /// the minute (the API jitters it by ~1 s); the rest become overlay
    /// lines. Codex has no 5h window today, but this picks it up if the
    /// plan changes.
    private func recompute() {
        let since = Date().addingTimeInterval(-range.seconds)
        let samples = Self.downsample(
            state.limitHistory.filter { $0.ts >= since && $0.service == service.rawValue },
            rangeSeconds: range.seconds)

        var byWindow: [String: SessionWindow] = [:]
        var overlay: [String: [LimitSnapshot]] = [:]
        for s in samples {
            if s.windowMinutes == 300 {
                guard let resets = s.resetsAt else { continue }
                let rounded = Date(timeIntervalSince1970: (resets.timeIntervalSince1970 / 60).rounded() * 60)
                let key = "\(rounded.timeIntervalSince1970)"
                if byWindow[key] == nil {
                    byWindow[key] = SessionWindow(
                        id: key,
                        start: rounded.addingTimeInterval(-5 * 3600),
                        end: rounded,
                        samples: [])
                }
                byWindow[key]?.samples.append(s)
            } else {
                overlay[s.seriesKey, default: []].append(s)
            }
        }
        let windows = byWindow.values
            .map { w in
                var w = w
                w.samples.sort { $0.ts < $1.ts }
                return w
            }
            .sorted { $0.start < $1.start }
        let overlaySeries = overlay.keys.sorted().map { key -> (String, String, [LimitSnapshot]) in
            let sorted = overlay[key]!.sorted { $0.ts < $1.ts }
            return (key, sorted[0].displayName, sorted)
        }
        derived = Derived(sessionWindows: windows, overlaySeries: overlaySeries,
                          hasData: !samples.isEmpty)
    }

    private var selectedWindow: SessionWindow? {
        guard let selectedDate else { return nil }
        return derived.sessionWindows.first { $0.start <= selectedDate && selectedDate <= $0.end }
    }

    /// Session-block color per service identity: Claude = blue blocks,
    /// Codex = monochrome (matching its white/black identity elsewhere).
    private var blockColor: Color { service == .claude ? .blue : service.chartBase }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("制限消費率の推移")
                .font(.headline)
            HStack {
                Picker("サービス", selection: $service) {
                    ForEach(enabledServices) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: CGFloat(enabledServices.count) * 75)
                Spacer()
                Button {
                    exportCSV()
                } label: {
                    Label("CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(!derived.hasData)
                Picker("期間", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }

            if !derived.hasData {
                ContentUnavailableView(
                    "まだ履歴がありません",
                    systemImage: "clock",
                    description: Text("アプリ稼働中に値が蓄積されます。"))
            } else {
                sessionInfoBar
                combinedChart
                resetsFooter
                footnote
            }

            officialLink
        }
        .padding()
        .onAppear { ensureValidSelection(); recompute() }
        .onChange(of: state.enabledSet) { _, _ in ensureValidSelection() }
        .onChange(of: range) { _, _ in recompute() }
        .onChange(of: service) { _, _ in recompute() }
        .onChange(of: state.limitHistory.count) { _, _ in recompute() }
    }

    private var enabledServices: [ServiceID] {
        ServiceID.allCases.filter { state.isEnabled($0) }
    }

    /// Keep the selection on an enabled service when toggles change.
    private func ensureValidSelection() {
        if !state.isEnabled(service), let first = enabledServices.first {
            service = first
        }
    }

    /// Link to the selected service's official usage page.
    private var officialLink: some View {
        HStack(spacing: 6) {
            Text("公式ページ:")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Link(destination: service.officialUsageURL) {
                HStack(spacing: 3) {
                    ServiceDot(service: service.rawValue)
                    Text("\(service.displayName) の使用量を開く")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8))
                }
                .font(.caption2)
            }
            Spacer()
        }
    }

    /// Upcoming reset times for the selected service's current windows,
    /// straight from the latest server values (handles ad-hoc resets too).
    @ViewBuilder
    private var resetsFooter: some View {
        let limits = state.sortedCurrentLimits.filter { $0.service == service.rawValue && $0.resetsAt != nil }
        if !limits.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("リセット予定 — " + limits.map { l in
                    let name = l.displayName
                        .replacingOccurrences(of: "Claude ", with: "")
                        .replacingOccurrences(of: "Codex ", with: "")
                    return "\(name): \(LimitGaugeRow.resetDetail(l.resetsAt!))"
                }.joined(separator: " ・ "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footnote: some View {
        Text(footnoteText)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private var footnoteText: String {
        let common = "サーバー側の値(複数マシン合算)、履歴はアプリ稼働中のみ蓄積。"
        if !derived.sessionWindows.isEmpty {
            return "点線の箱 = 5時間セッション枠、折れ線 = 週次などの他ウィンドウ。" + common
        }
        switch service {
        case .codex:
            return "Codex は現在このプランでは週次制限のみ(5時間枠が復活すれば自動で点線枠が表示されます)。" + common
        case .cursor, .copilot:
            return "折れ線 = 月間ウィンドウの使用率。" + common
        case .claude:
            return common
        }
    }

    @ViewBuilder
    private var sessionInfoBar: some View {
        let df = DateFormatter()
        let _ = df.dateFormat = "M/d H:mm"
        let _ = df.locale = Locale(identifier: "ja_JP")
        HStack(spacing: 12) {
            if let w = selectedWindow {
                Image(systemName: "clock")
                    .foregroundStyle(blockColor)
                Text("\(df.string(from: w.start)) → \(df.string(from: w.end))")
                    .font(.callout.monospacedDigit())
                Text("ピーク \(Int(w.peak))%")
                    .font(.callout.monospacedDigit())
                    .fontWeight(.semibold)
                    .foregroundStyle(w.peak >= 100 ? .red : .primary)
                if let t = w.timeToLimit {
                    Label("開始から \(formatDuration(t)) で上限到達", systemImage: "bolt.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } else if !derived.sessionWindows.isEmpty {
                Text("5時間枠のブロックにカーソルを合わせると詳細が表示されます。")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(height: 22)
    }

    private var combinedChart: some View {
        Chart {
            // 5h session windows: dashed box + filled step area.
            ForEach(derived.sessionWindows) { w in
                RuleMark(x: .value("枠開始", w.start))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(blockColor.opacity(selectedWindow?.id == w.id ? 0.7 : 0.35))
                RuleMark(x: .value("枠終了", w.end))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(blockColor.opacity(selectedWindow?.id == w.id ? 0.7 : 0.35))
                ForEach(w.samples, id: \.self) { s in
                    AreaMark(
                        x: .value("時刻", s.ts),
                        y: .value("使用率 %", s.usedPercent),
                        series: .value("枠", "w\(w.id)"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(blockColor.opacity(selectedWindow?.id == w.id ? 0.45 : 0.25))
                    LineMark(
                        x: .value("時刻", s.ts),
                        y: .value("使用率 %", s.usedPercent),
                        series: .value("枠", "w\(w.id)"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(blockColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // Other windows (weekly etc.) as overlay lines, colored per series.
            ForEach(derived.overlaySeries, id: \.key) { series in
                ForEach(series.samples, id: \.self) { s in
                    LineMark(
                        x: .value("時刻", s.ts),
                        y: .value("使用率 %", s.usedPercent),
                        series: .value("枠", series.key))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("系列", s.displayName))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }

            RuleMark(y: .value("上限", 100))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.red.opacity(0.6))
        }
        .chartForegroundStyleScale(
            domain: derived.overlaySeries.map(\.name),
            range: derived.overlaySeries.map { ChartPalette.limitSeriesColor($0.key) })
        .chartYScale(domain: 0...105)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text("\(Int(d))%") }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartLegend(position: .bottom)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
        return h > 0 ? "\(h)時間\(m)分" : "\(m)分"
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "usagebar-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let iso = ISO8601DateFormatter()
        var csv = "timestamp,series,used_percent,resets_at,window_minutes\n"
        let since = Date().addingTimeInterval(-range.seconds)
        for s in state.limitHistory where s.ts >= since {   // full resolution, all services
            let resets = s.resetsAt.map { iso.string(from: $0) } ?? ""
            csv += "\(iso.string(from: s.ts)),\(s.seriesKey),\(s.usedPercent),\(resets),\(s.windowMinutes.map(String.init) ?? "")\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}
