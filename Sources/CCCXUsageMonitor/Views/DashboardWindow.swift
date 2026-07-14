import AppKit
import SwiftUI

/// Dashboard as a manually-managed window (not a SwiftUI Window scene) so it
/// can be opened from anywhere — popover or floating HUD — even while the
/// menu bar item is hidden.
@MainActor
enum DashboardWindowController {
    private static var window: NSWindow?

    static func show(state: AppState) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "CCCX Usage Monitor"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DashboardView().environment(state))
        w.center()
        w.setFrameAutosaveName("DashboardWindow")
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
