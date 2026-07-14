import SwiftUI

/// GitHub-style activity heatmap built from the recorded limit history —
/// account-wide values (includes every machine), fills in from install day.
/// Daily intensity = how many %-points of the session quota were consumed
/// that day (positive deltas of the session window; 100pt = one full window).
struct ActivityGridView: View {
    @Environment(AppState.self) private var state
    @State private var service: Service = .claude

    enum Service: String, CaseIterable, Identifiable {
        case claude = "Claude", codex = "Codex"
        var id: String { rawValue }
        var key: String { rawValue.lowercased() }
    }

    private struct DayStat {
        var points: Double = 0   // consumed %-points
        var hits: Int = 0        // times the window reached 100%
    }

    private var dayStats: [String: DayStat] {
        // Claude: 5h session series; Codex (no 5h window today): primary weekly.
        let samples = state.limitHistory
            .filter { $0.service == service.key }
            .filter { service == .claude ? $0.windowMinutes == 300 : $0.seriesKey == "codex:primary" }
            .sorted { $0.ts < $1.ts }

        let dayF = DateFormatter()
        dayF.dateFormat = "yyyy-MM-dd"

        var stats: [String: DayStat] = [:]
        var prevPct: Double = 0
        var prevWindow: Date?
        for s in samples {
            let sameWindow = prevWindow != nil && s.resetsAt != nil
                && abs(prevWindow!.timeIntervalSince(s.resetsAt!)) < 120
            let delta = sameWindow ? max(0, s.usedPercent - prevPct) : s.usedPercent
            let key = dayF.string(from: s.ts)
            var d = stats[key] ?? DayStat()
            d.points += delta
            if s.usedPercent >= 100, prevPct < 100 || !sameWindow { d.hits += 1 }
            stats[key] = d
            prevPct = s.usedPercent
            prevWindow = s.resetsAt
        }
        return stats
    }

    /// Weeks (Sun-start) covering the last ~6 months.
    private func weeks(stats: [String: DayStat]) -> [[(key: String, stat: DayStat?)?]] {
        let cal = Calendar.current
        let dayF = DateFormatter()
        dayF.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -182, to: today)!
        let weekday = cal.component(.weekday, from: start)
        var cursor = cal.date(byAdding: .day, value: -(weekday - 1), to: start)!

        var result: [[(String, DayStat?)?]] = []
        while cursor <= today {
            var week: [(String, DayStat?)?] = []
            for _ in 0..<7 {
                if cursor <= today {
                    let key = dayF.string(from: cursor)
                    week.append((key, stats[key]))
                } else {
                    week.append(nil)
                }
                cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
            }
            result.append(week)
        }
        return result
    }

    private var rampBase: Color { service == .claude ? .orange : .primary }

    private func cellColor(_ stat: DayStat?, maxPoints: Double) -> Color {
        guard let stat, stat.points > 1 else { return Color.gray.opacity(0.15) }
        let ratio = stat.points / max(maxPoints, 1)
        let level = ratio > 0.6 ? 1.0 : ratio > 0.3 ? 0.7 : ratio > 0.1 ? 0.45 : 0.25
        return rampBase.opacity(level)
    }

    var body: some View {
        let stats = dayStats
        let maxPoints = stats.values.map(\.points).max() ?? 1
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("アクティビティ")
                    .font(.headline)
                Picker("サービス", selection: $service) {
                    ForEach(Service.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                Spacer()
            }

            if stats.isEmpty {
                ContentUnavailableView(
                    "まだ記録がありません",
                    systemImage: "square.grid.3x3",
                    description: Text("アプリ稼働中に日ごとの消費量が蓄積されていきます"))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        weekdayLabels
                        ForEach(Array(weeks(stats: stats).enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 3) {
                                ForEach(0..<7, id: \.self) { i in
                                    let cell = week[i]
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(cellColor(cell?.stat, maxPoints: maxPoints))
                                        .frame(width: 13, height: 13)
                                        .help(cell.map { c in
                                            let s = c.stat
                                            let unit = service == .claude ? "セッション枠" : "週次枠"
                                            return """
                                            \(c.key)
                                            消費: \(Int(s?.points ?? 0))%pt(\(unit)\(String(format: "%.1f", (s?.points ?? 0) / 100))個分)
                                            上限到達: \(s?.hits ?? 0)回
                                            """
                                        } ?? "")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .defaultScrollAnchor(.trailing)

                HStack(spacing: 4) {
                    Text("少")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach([0.15, 0.25, 0.45, 0.7, 1.0], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level == 0.15 ? Color.gray.opacity(0.15) : rampBase.opacity(level))
                            .frame(width: 10, height: 10)
                    }
                    Text("多")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("アカウント全体の消費量(全マシン合算)・記録はアプリ稼働中のみ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }

    private var weekdayLabels: some View {
        VStack(spacing: 3) {
            ForEach(["日", "月", "火", "水", "木", "金", "土"], id: \.self) { d in
                Text(d)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 13)
            }
        }
    }
}
