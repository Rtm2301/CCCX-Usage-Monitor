import SwiftUI

/// GitHub-style activity heatmaps built from the recorded limit history —
/// account-wide values (includes every machine), fills in from install day.
/// Two full grids stacked: Claude (orange ramp) on top, Codex (monochrome) below.
struct ActivityGridView: View {
    @Environment(AppState.self) private var state

    struct DayStat {
        var points: Double = 0   // consumed %-points
        var hits: Int = 0        // times the window reached 100%
    }

    /// Daily consumption per service from positive deltas of the recorded %.
    private func dayStats(service: String) -> [String: DayStat] {
        let samples = state.limitHistory
            .filter { $0.service == service }
            .filter { service == "claude" ? $0.windowMinutes == 300 : $0.seriesKey == "codex:primary" }
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

    /// Weeks (Sun-start) covering the last ~6 months; each entry is a day key.
    private var weeks: [[String?]] {
        let cal = Calendar.current
        let dayF = DateFormatter()
        dayF.dateFormat = "yyyy-MM-dd"
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -182, to: today)!
        let weekday = cal.component(.weekday, from: start)
        var cursor = cal.date(byAdding: .day, value: -(weekday - 1), to: start)!

        var result: [[String?]] = []
        while cursor <= today {
            var week: [String?] = []
            for _ in 0..<7 {
                week.append(cursor <= today ? dayF.string(from: cursor) : nil)
                cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
            }
            result.append(week)
        }
        return result
    }

    private func cellColor(_ stat: DayStat?, maxPoints: Double, base: Color) -> Color {
        guard let stat, stat.points > 1 else { return Color.gray.opacity(0.15) }
        let ratio = stat.points / max(maxPoints, 1)
        let level = ratio > 0.6 ? 1.0 : ratio > 0.3 ? 0.7 : ratio > 0.1 ? 0.45 : 0.25
        return base.opacity(level)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("アクティビティ")
                .font(.headline)

            let claudeStats = dayStats(service: "claude")
            let codexStats = dayStats(service: "codex")

            if claudeStats.isEmpty && codexStats.isEmpty {
                ContentUnavailableView(
                    "まだ記録がありません",
                    systemImage: "square.grid.3x3",
                    description: Text("アプリ稼働中に日ごとの消費量が蓄積されていきます"))
            } else {
                gridSection(title: "Claude", service: "claude", unit: "セッション枠",
                            stats: claudeStats, base: .orange)
                gridSection(title: "Codex", service: "codex", unit: "週次枠",
                            stats: codexStats, base: .primary)

                Text("色の濃さ = その日に消費した枠の量(%pt換算・全マシン合算)。記録はアプリ稼働中のみ蓄積")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top)
    }

    @ViewBuilder
    private func gridSection(title: String, service: String, unit: String,
                             stats: [String: DayStat], base: Color) -> some View {
        let maxPoints = stats.values.map(\.points).max() ?? 1
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ServiceDot(service: service)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                legend(base: base)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    weekdayLabels
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { i in
                                if let key = week[i] {
                                    let s = stats[key]
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(cellColor(s, maxPoints: maxPoints, base: base))
                                        .frame(width: 13, height: 13)
                                        .help(tooltip(key, stat: s, unit: unit))
                                } else {
                                    Color.clear.frame(width: 13, height: 13)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.trailing)
        }
    }

    private func tooltip(_ key: String, stat: DayStat?, unit: String) -> String {
        guard let stat, stat.points > 0 else { return "\(key)\n利用なし(または未記録)" }
        var t = "\(key)\n消費: \(Int(stat.points))%pt(\(unit)\(String(format: "%.1f", stat.points / 100))個分)"
        if stat.hits > 0 { t += "\n上限到達: \(stat.hits)回" }
        return t
    }

    private func legend(base: Color) -> some View {
        HStack(spacing: 3) {
            Text("少")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach([0.15, 0.25, 0.45, 0.7, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level == 0.15 ? Color.gray.opacity(0.15) : base.opacity(level))
                    .frame(width: 9, height: 9)
            }
            Text("多")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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
