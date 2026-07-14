import SwiftUI

/// Fixed color assignment per series/category — colors follow the entity,
/// never the current filter or rank (dataviz rule).
enum ChartPalette {
    // Identity colors follow the rest of the app: Claude = warm colors,
    // Codex = monochrome (white/black dot elsewhere → primary/gray here).
    static func limitSeriesColor(_ seriesKey: String) -> Color {
        switch seriesKey {
        case "claude:session": return .orange
        case "claude:weekly_all": return .red
        case "codex:primary": return .primary
        case "codex:secondary": return .gray
        default: return .purple   // claude:weekly_scoped:*
        }
    }

    static let tokenKindOrder = ["input", "output", "cache read", "cache write"]
    static func tokenKindColor(_ kind: String) -> Color {
        switch kind {
        case "input": return .blue
        case "output": return .green
        case "cache read": return .gray
        case "cache write": return .purple
        default: return .gray
        }
    }
}

/// Identity dot matching the menu bar / HUD: orange = Claude,
/// white with black edge = Codex.
struct ServiceDot: View {
    let service: String   // "claude" | "codex"

    var body: some View {
        Circle()
            .fill(service == "claude" ? Color.orange : Color.white)
            .overlay(Circle().strokeBorder(
                service == "claude" ? Color.white.opacity(0.8) : Color.black.opacity(0.55),
                lineWidth: 0.8))
            .frame(width: 9, height: 9)
    }
}

struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            LimitHistoryChart()
                .tabItem { Label("制限消費率", systemImage: "gauge.with.needle") }
            ActivityGridView()
                .tabItem { Label("アクティビティ", systemImage: "square.grid.3x3.fill") }
            InsightsView()
                .tabItem { Label("インサイト", systemImage: "lightbulb") }
        }
        .padding()
    }
}
