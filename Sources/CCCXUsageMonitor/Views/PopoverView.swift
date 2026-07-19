import SwiftUI
import ServiceManagement

struct PopoverView: View {
    @Environment(AppState.self) private var state
    @AppStorage("menuBarStyle") private var menuBarStyle = "bars"
    @AppStorage("showFloatingHUD") private var showFloatingHUD = false
    @AppStorage("menuBarVisible") private var menuBarVisible = true
    @AppStorage("pollIntervalSec") private var pollInterval = 60.0
    @AppStorage("notifyThreshold") private var notifyThreshold = 0.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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

            HStack(spacing: 6) {
                Text("サービス")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(ServiceID.allCases) { s in
                    Toggle(isOn: Binding(
                        get: { state.isEnabled(s) },
                        set: { state.setEnabled(s, $0) })) {
                        Text(s.displayName)
                            .font(.caption2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }

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

            HStack(spacing: 8) {
                Text("通知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("通知しきい値", selection: $notifyThreshold) {
                    Text("オフ").tag(0.0)
                    Text("80%").tag(80.0)
                    Text("90%").tag(90.0)
                    Text("100%").tag(100.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: notifyThreshold) { _, v in
                    if v > 0 { Notifier.requestAuthorization() }
                }
            }

            Toggle("ログイン時に起動", isOn: $launchAtLogin)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle("フローティング表示(常に最前面)", isOn: $showFloatingHUD)
                .font(.caption)
                .onChange(of: showFloatingHUD) { _, on in
                    FloatingHUDController.setEnabled(on, state: state)
                    // Lockout guard: HUD off + menu bar hidden would strand the user.
                    if !on && !menuBarVisible { menuBarVisible = true }
                }

            Toggle("メニューバーに表示", isOn: $menuBarVisible)
                .font(.caption)
                .onChange(of: menuBarVisible) { _, on in
                    // Hiding the menu bar item requires the HUD as the remaining handle.
                    if !on && !showFloatingHUD {
                        showFloatingHUD = true
                        FloatingHUDController.setEnabled(true, state: state)
                    }
                }

            Divider()

            HStack {
                Button {
                    DashboardWindowController.show(state: state)
                } label: {
                    Label("ダッシュボードを開く", systemImage: "chart.xyaxis.line")
                }
                Spacer()
                Button {
                    state.manualRefresh()
                } label: {
                    Label("再読み込み", systemImage: "arrow.clockwise")
                }
                .help("待機を無視して今すぐ再取得します。")
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder
    private var statusBanners: some View {
        if state.visibleServices.isEmpty {
            BannerView(text: "監視できるサービスが見つかりません。ログインまたはインストールすると自動で表示されます。", color: .gray)
        }

        ForEach(state.visibleServices) { s in
            serviceBanner(s)
        }

        copilotLoginRow

        let planText = ServiceID.allCases.compactMap { s -> String? in
            guard state.isEnabled(s), let plan = state.plans[s] else { return nil }
            return "\(s.displayName): \(plan)"
        }
        if !planText.isEmpty {
            Text(planText.joined(separator: " ・ "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func serviceBanner(_ s: ServiceID) -> some View {
        switch state.status(s) {
        case .authError(let msg):
            BannerView(text: "\(s.displayName): \(msg)", color: .orange)
        case .stale(let asOf, let reason):
            if s == .claude, let retry = state.claudeRetryAt {
                BannerView(text: "\(s.displayName): \(reason) — \(retry.formatted(date: .omitted, time: .shortened))頃に再取得します。(最終 \(asOf.formatted(date: .omitted, time: .shortened)))", color: .yellow)
            } else if state.showWarning(s) || s == .codex {
                BannerView(text: "\(s.displayName): \(reason) (\(asOf.formatted(date: .omitted, time: .shortened)))", color: .yellow)
            }
        case .fetchError(let msg):
            if state.showWarning(s) {
                BannerView(text: "\(s.displayName): \(msg)", color: .red)
            }
        case .ok, .unknown:
            EmptyView()
        }
    }

    /// Copilot needs its own GitHub device-flow login (no local token source).
    @ViewBuilder
    private var copilotLoginRow: some View {
        if state.isEnabled(.copilot) && !state.configured(.copilot) {
            if let dc = state.copilotDeviceCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ブラウザでコードを入力してください:")
                        .font(.caption)
                    HStack {
                        Text(dc.userCode)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                        Button("コピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(dc.userCode, forType: .string)
                        }
                        .font(.caption)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            } else {
                HStack {
                    ServiceDot(service: "copilot")
                    Button("GitHub Copilot にログイン") { state.startCopilotLogin() }
                        .font(.caption)
                    if state.copilotLoginFailed {
                        Text("失敗 — 再試行してください")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

struct BannerView: View {
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)   // wrap, never truncate
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct LimitGaugeRow: View {
    let limit: LimitSnapshot

    private var barColor: Color {
        switch limit.effectivePercent {
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
                Text("\(Int(limit.effectivePercent))%")
                    .font(.callout.monospacedDigit())
                    .fontWeight(.semibold)
            }
            // Hand-drawn bar (same as the HUD): ProgressView's .tint is
            // ignored in some window contexts and falls back to the system
            // accent color.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.3))
                    if limit.effectivePercent > 0 {
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(6, geo.size.width * CGFloat(min(limit.effectivePercent, 100)) / 100))
                    }
                }
            }
            .frame(height: 6)
            if limit.isExpired {
                Text("リセット済み — 次の取得で更新されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let resets = limit.resetsAt {
                Text("リセット: \(Self.resetDetail(resets))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "あと1日19時間" — just the remaining-time part.
    static func remainingText(_ date: Date) -> String {
        let remain = date.timeIntervalSinceNow
        if remain <= 60 { return "まもなく" }
        let days = Int(remain) / 86400
        let hours = (Int(remain) % 86400) / 3600
        let minutes = (Int(remain) % 3600) / 60
        if days > 0 { return "あと\(days)日\(hours)時間" }
        return hours > 0 ? "あと\(hours)時間\(minutes)分" : "あと\(minutes)分"
    }

    /// "7/16(木) 0:00(あと1日19時間)" — vague relative wording is useless
    /// for planning, so show the absolute time plus exact remaining time.
    static func resetDetail(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d(E) H:mm"
        return "\(df.string(from: date))(\(remainingText(date)))"
    }
}
