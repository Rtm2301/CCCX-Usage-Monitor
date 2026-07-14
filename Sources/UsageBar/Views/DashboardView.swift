import SwiftUI

/// Fixed color assignment per series/category — colors follow the entity,
/// never the current filter or rank (dataviz rule).
enum ChartPalette {
    static func limitSeriesColor(_ seriesKey: String) -> Color {
        switch seriesKey {
        case "claude:session": return .orange
        case "claude:weekly_all": return .red
        case "codex:primary": return .blue
        case "codex:secondary": return .teal
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

struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            LimitHistoryChart()
                .tabItem { Label("制限消費率", systemImage: "gauge.with.needle") }
            InsightsView()
                .tabItem { Label("インサイト", systemImage: "lightbulb") }
        }
        .padding()
    }
}
