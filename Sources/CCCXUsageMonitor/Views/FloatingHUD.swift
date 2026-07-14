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
            if state.claudeConfigured {
                row(label: "Claude", dot: .orange,
                    pct: state.displayPercent(service: "claude"),
                    problem: state.claudeShowWarning)
            }
            if state.codexConfigured {
                row(label: "Codex", dot: .white,
                    pct: state.displayPercent(service: "codex"),
                    problem: state.codexStatus.isProblem && !state.codexIsFallback)
            }
            if !state.claudeConfigured && !state.codexConfigured {
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
                            Text("リセット済み — 次の取得で更新")
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

    private func row(label: String, dot: Color, pct: Double?, problem: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(dot)
                    .overlay(Circle().strokeBorder(dot == .white ? Color.black.opacity(0.5) : Color.white.opacity(0.8), lineWidth: 0.8))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
