import AppKit
import SwiftUI

/// Small always-on-top translucent panel showing usage bars.
/// Visible on every Space (and over full-screen apps), draggable anywhere,
/// position remembered across launches.
@MainActor
enum FloatingHUDController {
    private static var panel: NSPanel?

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
        p.contentView = NSHostingView(rootView: FloatingHUDView(state: state))

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
