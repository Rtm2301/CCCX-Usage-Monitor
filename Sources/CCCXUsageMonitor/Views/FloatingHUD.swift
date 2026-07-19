import AppKit
import SwiftUI

/// Small always-on-top translucent panel showing usage bars.
/// Visible on every Space (and over full-screen apps), draggable anywhere,
/// position remembered across launches.
@MainActor
enum FloatingHUDController {
    private static var panel: NSPanel?
    private static var hosting: NSHostingView<FloatingHUDView>?

    /// Re-fit the panel to its content (e.g. after expanding the detail
    /// section), keeping the TOP edge anchored so it grows downward.
    static func refreshSize() {
        DispatchQueue.main.async {
            guard let panel, let hosting else { return }
            let newSize = hosting.fittingSize
            var frame = panel.frame
            let delta = newSize.height - frame.size.height
            frame.origin.y -= delta
            frame.size = newSize
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    static func applyStartupSetting(state: AppState) {
        if UserDefaults.standard.bool(forKey: "showFloatingHUD") {
            setEnabled(true, state: state)
        }
    }

    static func setEnabled(_ on: Bool, state: AppState) {
        if on {
            show(state: state)
        } else {
            panel?.orderOut(nil)
            panel = nil
            hosting = nil
        }
    }

    private static func show(state: AppState) {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        let hostingView = NSHostingView(rootView: FloatingHUDView(state: state))
        p.contentView = hostingView
        p.setContentSize(hostingView.fittingSize)
        hosting = hostingView

        let autosave = "FloatingHUD"
        if !p.setFrameUsingName(autosave), let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 220, y: f.maxY - 100))
        }
        p.setFrameAutosaveName(autosave)
        p.orderFrontRegardless()
        panel = p
    }
}

struct FloatingHUDView: View {
    let state: AppState
    @AppStorage("menuBarVisible") private var menuBarVisible = true
    @AppStorage("showFloatingHUD") private var showFloatingHUD = false
    @AppStorage("hudExpanded") private var expanded = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(state.visibleServices) { s in
                row(service: s,
                    limit: state.displayLimit(service: s.rawValue),
                    problem: state.showWarning(s))
            }
            if state.visibleServices.isEmpty {
                Text("未検出")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if expanded {
                Divider()
                ForEach(state.sortedCurrentLimits, id: \.seriesKey) { l in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(l.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(l.effectivePercent))%")
                                .font(.caption2.monospacedDigit())
                                .fontWeight(.semibold)
                        }
                        if l.isExpired {
                            Text("リセット済み — 次の取得で更新。")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        } else if let resets = l.resetsAt {
                            Text("リセット: \(LimitGaugeRow.resetDetail(resets))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    expanded.toggle()
                    FloatingHUDController.refreshSize()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .help(expanded ? "詳細を閉じる" : "リセット日時など詳細を表示")

                Button {
                    DashboardWindowController.show(state: state)
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .help("ダッシュボードを開く")

                Button {
                    state.manualRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("今すぐ再取得")

                Button {
                    menuBarVisible.toggle()
                } label: {
                    Image(systemName: menuBarVisible ? "menubar.rectangle" : "menubar.dock.rectangle.badge.record")
                }
                .help(menuBarVisible ? "メニューバーの表示を隠す" : "メニューバーに表示する")

                Spacer()

                Button {
                    guard menuBarVisible else { return }   // lockout guard
                    showFloatingHUD = false
                    FloatingHUDController.setEnabled(false, state: state)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help(menuBarVisible ? "フローティング表示を閉じる" : "メニューバー非表示中は閉じられません")
                .opacity(menuBarVisible ? 1 : 0.3)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(service: ServiceID, limit: LimitSnapshot?, problem: Bool) -> some View {
        let pct = limit?.effectivePercent
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(service.dotColor)
                    .overlay(Circle().strokeBorder(service.dotRing, lineWidth: 0.8))
                    .frame(width: 7, height: 7)
                Text(service.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Time until this window resets (weekly when there is no 5h window).
                if let limit {
                    if limit.isExpired {
                        Text("リセット済み")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    } else if let resets = limit.resetsAt {
                        Text(LimitGaugeRow.remainingText(resets))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(pct.map { "\(Int($0))%" } ?? "—")
                    .font(.callout.monospacedDigit())
                    .fontWeight(.bold)
            }
            // Hand-drawn bar: the standard ProgressView renders gray in a
            // nonactivating panel (inactive-window appearance), so draw shapes.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.3))
                    Capsule()
                        .fill(color(for: pct))
                        .frame(width: max(6, geo.size.width * CGFloat(min(pct ?? 0, 100)) / 100))
                }
            }
            .frame(height: 6)
        }
    }

    private func color(for pct: Double?) -> Color {
        guard let pct else { return .gray }
        return pct < 60 ? .green : pct < 85 ? .yellow : .red
    }
}
