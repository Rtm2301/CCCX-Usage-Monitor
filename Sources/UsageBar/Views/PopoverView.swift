import SwiftUI

struct PopoverView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarStyle") private var menuBarStyle = "bars"
    @AppStorage("showFloatingHUD") private var showFloatingHUD = false
    @AppStorage("pollIntervalSec") private var pollInterval = 60.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.latestLimits.isEmpty {
                Text("取得中…")
                    .foregroundStyle(.secondary)
            }

            ForEach(state.sortedCurrentLimits, id: \.seriesKey) { limit in
                LimitGaugeRow(limit: limit)
            }

            statusBanners

            Divider()

            HStack(spacing: 8) {
                Text("メニューバー")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("表示形式", selection: $menuBarStyle) {
                    Text("バー").tag("bars")
                    Text("テキスト").tag("text")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("更新間隔")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("更新間隔", selection: $pollInterval) {
                    Text("1分").tag(60.0)
                    Text("2分").tag(120.0)
                    Text("5分").tag(300.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle("フローティング表示(常に最前面)", isOn: $showFloatingHUD)
                .font(.caption)
                .onChange(of: showFloatingHUD) { _, on in
                    FloatingHUDController.setEnabled(on, state: state)
                }

            Divider()

            HStack {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("ダッシュボードを開く", systemImage: "chart.xyaxis.line")
                }
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private var statusBanners: some View {
        if !state.claudeConfigured && !state.codexConfigured {
            BannerView(text: "Claude Code / Codex が見つかりません。ログインまたはインストールすると自動で表示されます。", color: .gray)
        }

        if state.claudeConfigured {
            if case .authError(let msg) = state.claudeStatus {
                BannerView(text: "Claude: \(msg)", color: .orange)
            } else if state.claudeShowWarning {
                if case .fetchError(let msg) = state.claudeStatus {
                    BannerView(text: "Claude: \(msg)", color: .red)
                } else if case .stale(_, let reason) = state.claudeStatus {
                    BannerView(text: "Claude: \(reason)", color: .yellow)
                }
            }
        }

        if state.codexConfigured {
            if case .stale(let asOf, let reason) = state.codexStatus {
                BannerView(text: "Codex: \(reason) (\(asOf.formatted(date: .omitted, time: .shortened)))", color: .yellow)
            } else if case .fetchError(let msg) = state.codexStatus {
                BannerView(text: "Codex: \(msg)", color: .red)
            }
        }

        if state.claudePlan != nil || state.codexPlanType != nil {
            Text([
                state.claudePlan.map { "Claude plan: \($0)" },
                state.codexPlanType.map { "Codex plan: \($0)" },
            ].compactMap { $0 }.joined(separator: " ・ "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct BannerView: View {
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct LimitGaugeRow: View {
    let limit: LimitSnapshot

    private var barColor: Color {
        switch limit.usedPercent {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(limit.displayName)
                    .font(.callout)
                Spacer()
                Text("\(Int(limit.usedPercent))%")
                    .font(.callout.monospacedDigit())
                    .fontWeight(.semibold)
            }
            ProgressView(value: min(limit.usedPercent, 100), total: 100)
                .tint(barColor)
            if let resets = limit.resetsAt {
                Text("リセット: \(Self.resetDetail(resets))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "7/16(木) 0:00(あと1日19時間)" — vague relative wording is useless
    /// for planning, so show the absolute time plus exact remaining time.
    static func resetDetail(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d(E) H:mm"

        let remain = date.timeIntervalSinceNow
        let remainText: String
        if remain <= 60 {
            remainText = "まもなく"
        } else {
            let days = Int(remain) / 86400
            let hours = (Int(remain) % 86400) / 3600
            let minutes = (Int(remain) % 3600) / 60
            if days > 0 {
                remainText = "あと\(days)日\(hours)時間"
            } else if hours > 0 {
                remainText = "あと\(hours)時間\(minutes)分"
            } else {
                remainText = "あと\(minutes)分"
            }
        }
        return "\(df.string(from: date))(\(remainText))"
    }
}
