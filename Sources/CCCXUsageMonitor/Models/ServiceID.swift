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

    /// Brand colors: Cursor #26251E (near-black), Copilot #6E40C9.
    static let cursorBrand = Color(red: 0x26 / 255, green: 0x25 / 255, blue: 0x1E / 255)
    static let copilotBrand = Color(red: 0x6E / 255, green: 0x40 / 255, blue: 0xC9 / 255)

    /// Identity dot fill (SwiftUI).
    var dotColor: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .white
        case .cursor: return Self.cursorBrand
        case .copilot: return Self.copilotBrand
        }
    }

    /// Contrasting ring around the dot.
    var dotRing: Color {
        switch self {
        case .claude: return .white.opacity(0.8)
        case .codex: return .black.opacity(0.55)
        case .cursor: return .white.opacity(0.85)
        case .copilot: return .black.opacity(0.8)
        }
    }

    /// Outline color for the menu bar mini-bars.
    var menuOutline: NSColor {
        switch self {
        case .claude: return .systemOrange
        case .codex: return .white
        // Pure brand-black is invisible on a dark menu bar — use a mid gray.
        case .cursor: return NSColor(white: 0.6, alpha: 1)
        case .copilot: return NSColor(red: 0x6E / 255, green: 0x40 / 255, blue: 0xC9 / 255, alpha: 1)
        }
    }

    /// Base color for dashboard charts (session blocks / heatmap ramp).
    var chartBase: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .primary
        case .cursor: return .gray
        case .copilot: return Self.copilotBrand
        }
    }

    /// Official usage page (opened from the dashboard footer).
    var officialUsageURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/new#settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/cloud/settings/analytics")!
        case .cursor: return URL(string: "https://cursor.com/dashboard")!
        case .copilot: return URL(string: "https://github.com/settings/copilot")!
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
