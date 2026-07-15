import SwiftUI
import AppKit

/// The monitored services. Identity colors are consistent everywhere:
/// menu bar, HUD, dashboard, and the app icon.
enum ServiceID: String, CaseIterable, Identifiable {
    case claude, codex, cursor, copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        }
    }

    /// Identity dot fill (SwiftUI).
    var dotColor: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .white
        case .cursor: return .teal
        case .copilot: return .blue
        }
    }

    /// Contrasting ring around the dot.
    var dotRing: Color {
        switch self {
        case .claude: return .white.opacity(0.8)
        case .codex: return .black.opacity(0.55)
        default: return .white.opacity(0.6)
        }
    }

    /// Outline color for the menu bar mini-bars.
    var menuOutline: NSColor {
        switch self {
        case .claude: return .systemOrange
        case .codex: return .white
        case .cursor: return .systemTeal
        case .copilot: return .systemBlue
        }
    }

    /// Base color for dashboard charts (session blocks / heatmap ramp).
    var chartBase: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .primary
        case .cursor: return .teal
        case .copilot: return .blue
        }
    }

    /// The main (non-5h) series key for this service.
    var primarySeriesKey: String {
        switch self {
        case .claude: return "claude:weekly_all"
        case .codex: return "codex:primary"
        case .cursor: return "cursor:monthly"
        case .copilot: return "copilot:premium"
        }
    }
}
