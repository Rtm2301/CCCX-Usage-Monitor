import SwiftUI

/// Usage Insights computed from the recorded limit-snapshot history,
/// one section per service (Claude / Codex).
struct InsightsView: View {
    @Environment(AppState.self) private var state

    private struct ServiceInsights {
        var hits = 0
        var hitsAreSession = true          // false = counted on the weekly window
        var avgTimeToLimit: TimeInterval?
        var avgWeekly: Double?
        var highUsageDays = 0
        var hasData = false
    }

    private func compute(service: String) -> ServiceInsights {
        var r = ServiceInsights()
        let samples = state.limitHistory.filter { $0.service == service }
        guard !samples.isEmpty else { return r }
        r.hasData = true

        let session = samples.filter { $0.windowMinutes == 300 }.sorted { $0.ts < $1.ts }
        // Main weekly window only — don't mix model-scoped weekly windows
        // (claude:weekly_scoped:*) into the average.
        let weeklyKey = service == "claude" ? "claude:weekly_all" : "codex:primary"
        var weekly = samples.filter { $0.seriesKey == weeklyKey && ($0.windowMinutes ?? 0) > 300 }
            .sorted { $0.ts < $1.ts }
        if weekly.isEmpty {
            weekly = samples.filter { ($0.windowMinutes ?? 0) > 300 && !$0.seriesKey.contains("weekly_scoped") }
                .sorted { $0.ts < $1.ts }
        }

        // Count limit hits on the 5h window when the service has one,
        // otherwise on the weekly window (Codex today).
        let hitSource: [LimitSnapshot]
        let windowSeconds: TimeInterval
        if !session.isEmpty {
            hitSource = session
            windowSeconds = 5 * 3600
            r.hitsAreSession = true
        } else {
            hitSource = weekly
            windowSeconds = TimeInterval((weekly.first?.windowMinutes ?? 10080) * 60)
            r.hitsAreSession = false
        }

        var prevPct: Double = 0
        var timesToLimit: [TimeInterval] = []
        for s in hitSource {
            if s.usedPercent >= 100, prevPct < 100 {
                r.hits += 1
                if let resets = s.resetsAt {
                    let windowStart = resets.addingTimeInterval(-windowSeconds)
                    let t = s.ts.timeIntervalSince(windowStart)
                    if t > 0, t <= windowSeconds { timesToLimit.append(t) }
                }
            }
            prevPct = s.usedPercent
        }
        if !timesToLimit.isEmpty {
            r.avgTimeToLimit = timesToLimit.reduce(0, +) / Double(timesToLimit.count)
        }

        if !weekly.isEmpty {
            r.avgWeekly = weekly.map(\.usedPercent).reduce(0, +) / Double(weekly.count)
        }

        let dayF = DateFormatter()
        dayF.dateFormat = "yyyy-MM-dd"
        r.highUsageDays = Set(samples.filter { $0.usedPercent >= 90 }.map { dayF.string(from: $0.ts) }).count
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("インサイト")
                .font(.headline)

            if state.limitHistory.isEmpty {
                ContentUnavailableView(
                    "まだ履歴がありません",
                    systemImage: "lightbulb",
                    description: Text("アプリ稼働中に記録が蓄積されると自動で分析されます"))
            } else {
                let claude = compute(service: "claude")
                let codex = compute(service: "codex")
                if state.claudeConfigured || claude.hasData {
                    section(title: "Claude", service: "claude", ins: claude)
                }
                if (state.claudeConfigured || claude.hasData) && (state.codexConfigured || codex.hasData) {
                    Divider()
                }
                if state.codexConfigured || codex.hasData {
                    section(title: "Codex", service: "codex", ins: codex)
                }

                if let since = state.limitHistory.map(\.ts).min() {
                    Text("計測期間: \(since.formatted(date: .abbreviated, time: .shortened)) 〜 現在(アプリ稼働中のみ記録・アカウント全体の値)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func section(title: String, service: String, ins: ServiceInsights) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ServiceDot(service: service)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }

            if !ins.hasData {
                Text("データがありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 12) {
                    InsightCard(
                        icon: "bolt.fill", tint: .red,
                        title: ins.hitsAreSession ? "セッション上限到達" : "週次上限到達",
                        value: "\(ins.hits)回",
                        detail: ins.avgTimeToLimit.map { "平均 \(formatDuration($0)) で到達" }
                            ?? (ins.hits == 0 ? "上限到達なし" : ""))
                    InsightCard(
                        icon: "calendar", tint: .blue,
                        title: "平均週次使用率",
                        value: ins.avgWeekly.map { "\(Int($0))%" } ?? "—",
                        detail: weeklyComment(ins.avgWeekly))
                    InsightCard(
                        icon: "exclamationmark.triangle", tint: .orange,
                        title: "高負荷(90%+)",
                        value: "\(ins.highUsageDays)日",
                        detail: "いずれかの枠が90%を超えた日数")
                }
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let d = Int(t) / 86400, h = (Int(t) % 86400) / 3600, m = (Int(t) % 3600) / 60
        if d > 0 { return "\(d)日\(h)時間" }
        return h > 0 ? "\(h)時間\(m)分" : "\(m)分"
    }

    private func weeklyComment(_ avgWeekly: Double?) -> String {
        guard let w = avgWeekly else { return "" }
        switch w {
        case ..<40: return "余裕あり — 週次枠を十分使い切れていません"
        case ..<75: return "ほどよい使用量です"
        default: return "週次枠を使い切りがち — プラン上限に注意"
        }
    }
}

struct InsightCard: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.monospacedDigit())
                .fontWeight(.bold)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
