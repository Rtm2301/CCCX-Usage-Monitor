import SwiftUI
import Charts
import AppKit

struct LimitHistoryChart: View {
    @Environment(AppState.self) private var state
    @State private var range: HistoryRange = .day
    @State private var service: Service = .claude
    @State private var selectedDate: Date?

    enum Service: String, CaseIterable, Identifiable {
        case claude = "Claude", codex = "Codex"
        var id: String { rawValue }
        var key: String { rawValue.lowercased() }
    }

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

    private var filtered: [LimitSnapshot] {
        let since = Date().addingTimeInterval(-range.seconds)
        return state.limitHistory.filter { $0.ts >= since }
    }

    private var serviceSamples: [LimitSnapshot] {
        filtered.filter { $0.service == service.key }
    }

    /// 5-hour windows of the selected service (windowMinutes == 300),
    /// keyed by resets_at rounded to the minute (the API jitters it by ~1 s).
    /// Codex has no 5h window today, but this picks it up if the plan changes.
    private var sessionWindows: [SessionWindow] {
        var byWindow: [String: SessionWindow] = [:]
        for s in serviceSamples where s.windowMinutes == 300 {
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
        }
        return byWindow.values
            .map { w in
                var w = w
                w.samples.sort { $0.ts < $1.ts }
                return w
            }
            .sorted { $0.start < $1.start }
    }

    /// Non-5h series of the selected service, drawn as overlay lines.
    private var overlaySamples: [LimitSnapshot] {
        serviceSamples.filter { $0.windowMinutes != 300 }
    }

    private var overlayKeys: [String] {
        Array(Set(overlaySamples.map(\.seriesKey))).sorted()
    }

    private var selectedWindow: SessionWindow? {
        guard let selectedDate else { return nil }
        return sessionWindows.first { $0.start <= selectedDate && selectedDate <= $0.end }
    }

    /// Session-block color per service identity: Claude = blue blocks,
    /// Codex = monochrome (matching its white/black identity elsewhere).
    private var blockColor: Color { service == .claude ? .blue : .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("制限消費率の推移")
                    .font(.headline)
                Picker("サービス", selection: $service) {
                    ForEach(Service.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Spacer()
                Button {
                    exportCSV()
                } label: {
                    Label("CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
                Picker("期間", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }

            if serviceSamples.isEmpty {
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
        }
        .padding()
    }

    /// Upcoming reset times for the selected service's current windows,
    /// straight from the latest server values (handles ad-hoc resets too).
    @ViewBuilder
    private var resetsFooter: some View {
        let limits = state.sortedCurrentLimits.filter { $0.service == service.key && $0.resetsAt != nil }
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
        if service == .codex && sessionWindows.isEmpty {
            Text("Codex は現在このプランでは週次制限のみ(5時間枠が復活すれば自動で点線枠が表示されます)。サーバー側の値・複数マシン合算。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("点線の箱 = 5時間セッション枠、折れ線 = 週次などの他ウィンドウ。サーバー側の値(複数マシン合算)、履歴はアプリ稼働中のみ蓄積。")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
            } else if !sessionWindows.isEmpty {
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
            ForEach(sessionWindows) { w in
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
            ForEach(overlayKeys, id: \.self) { key in
                let samples = overlaySamples.filter { $0.seriesKey == key }
                ForEach(samples, id: \.self) { s in
                    LineMark(
                        x: .value("時刻", s.ts),
                        y: .value("使用率 %", s.usedPercent),
                        series: .value("枠", key))
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
            domain: overlayKeys.map { key in
                LimitSnapshot(ts: .now, seriesKey: key, usedPercent: 0,
                              resetsAt: nil, windowMinutes: nil, severity: nil).displayName
            },
            range: overlayKeys.map { ChartPalette.limitSeriesColor($0) })
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
        for s in filtered {
            let resets = s.resetsAt.map { iso.string(from: $0) } ?? ""
            csv += "\(iso.string(from: s.ts)),\(s.seriesKey),\(s.usedPercent),\(resets),\(s.windowMinutes.map(String.init) ?? "")\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}
