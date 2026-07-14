import SwiftUI
import AppKit

@main
struct UsageBarApp: App {
    @State private var state: AppState

    init() {
        NSApp?.setActivationPolicy(.accessory)
        let s = AppState()
        _state = State(initialValue: s)
        Task { @MainActor in s.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(state)
        } label: {
            MenuBarIconLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Window("CCCX Usage Monitor", id: "dashboard") {
            DashboardView()
                .environment(state)
        }
        .defaultSize(width: 940, height: 660)
    }
}
