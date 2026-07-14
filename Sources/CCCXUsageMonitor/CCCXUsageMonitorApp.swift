import SwiftUI
import AppKit

@main
struct CCCXUsageMonitorApp: App {
    @State private var state: AppState
    @AppStorage("menuBarVisible") private var menuBarVisible = true

    init() {
        NSApp?.setActivationPolicy(.accessory)
        let s = AppState()
        _state = State(initialValue: s)
        Task { @MainActor in s.start() }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $menuBarVisible) {
            PopoverView()
                .environment(state)
        } label: {
            MenuBarIconLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}
