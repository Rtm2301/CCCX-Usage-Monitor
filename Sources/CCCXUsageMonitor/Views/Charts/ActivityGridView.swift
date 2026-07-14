import SwiftUI

/// GitHub-style activity heatmap built from the recorded limit history —
/// account-wide values (includes every machine), fills in from install day.
/// Each day cell is split: top half = Claude (orange ramp),
/// bottom half = Codex (monochrome ramp). No toggle — both at a glance.
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

    private func halfColor(_ stat: DayStat?, maxPoints: Double, base: Color) -> Color {
        guard let stat, stat.points > 1 else { return Color.gray.opacity(0.15) }
        let ratio = stat.points / max(maxPoints, 1)
        let level = ratio > 0.6 ? 1.0 : ratio > 0.3 ? 0.7 : ratio > 0.1 ? 0.45 : 0.25
        return base.opacity(level)
    }

    private func tooltip(_ key: String, claude: DayStat?, codex: DayStat?) -> String {
        func line(_ name: String, _ s: DayStat?, _ unit: String) -> String {
            guard let s, s.points > 0 else { return "\(name): —" }
            var t = "\(name): \(Int(s.points))%pt(\(unit)\(String(format: "%.1f", s.points / 100))個分)"
            if s.hits > 0 { t += "・上限\(s.hits)回" }
            return t
        }
        return "\(key)\n\(line("Claude", claude, "セッション枠"))\n\(line("Codex", codex, "週次枠"))"
    }

    var body: some View {
        let claudeStats = dayStats(service: "claude")
        let codexStats = dayStats(service: "codex")
        let maxClaude = claudeStats.values.map(\.points).max() ?? 1
        let maxCodex = codexStats.values.map(\.points).max() ?? 1

        VStack(alignment: .leading, spacing: 10) {
            Text("アクティビティ")
                .font(.headline)

            if claudeStats.isEmpty && codexStats.isEmpty {
                ContentUnavailableView(
                    "まだ記録がありません",
                    systemImage: "square.grid.3x3",
                    description: Text("アプリ稼働中に日ごとの消費量が蓄積されていきます"))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        weekdayLabels
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 3) {
                                ForEach(0..<7, id: \.self) { i in
                                    if let key = week[i] {
                                        VStack(spacing: 1) {
                                            UnevenRoundedRectangle(topLeadingRadius: 2.5, topTrailingRadius: 2.5)
                                                .fill(halfColor(claudeStats[key], maxPoints: maxClaude, base: .orange))
                                                .frame(width: 13, height: 6)
                                            UnevenRoundedRectangle(bottomLeadingRadius: 2.5, bottomTrailingRadius: 2.5)
                                                .fill(halfColor(codexStats[key], maxPoints: maxCodex, base: .primary))
                                                .frame(width: 13, height: 6)
                                        }
                                        .help(tooltip(key, claude: claudeStats[key], codex: codexStats[key]))
                                    } else {
                                        Color.clear.frame(width: 13, height: 13)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .defaultScrollAnchor(.trailing)

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        ServiceDot(service: "claude")
                        Text("上段 Claude")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        ServiceDot(service: "codex")
                        Text("下段 Codex")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("色の濃さ = その日の消費量(全マシン合算)・記録はアプリ稼働中のみ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top)
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
