import Foundation

/// Central place for filesystem locations, all overridable via env for testing.
enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var codexDir: URL {
        if let p = ProcessInfo.processInfo.environment["USAGEBAR_CODEX_DIR"] {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
    }

    static var keychainService: String {
        ProcessInfo.processInfo.environment["USAGEBAR_KEYCHAIN_SERVICE"] ?? "Claude Code-credentials"
    }

    static let dataDir: URL = {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["USAGEBAR_DATA_DIR"] {
            let base = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = appSupport.appendingPathComponent("CCCX Usage Monitor")
        // One-time migration from the app's former name.
        let legacy = appSupport.appendingPathComponent("UsageBar")
        if !fm.fileExists(atPath: base.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: base)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var snapshotsDir: URL {
        let d = dataDir.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
