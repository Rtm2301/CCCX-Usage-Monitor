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

    static var dataDir: URL {
        let base: URL
        if let p = ProcessInfo.processInfo.environment["USAGEBAR_DATA_DIR"] {
            base = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UsageBar")
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var snapshotsDir: URL {
        let d = dataDir.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}
