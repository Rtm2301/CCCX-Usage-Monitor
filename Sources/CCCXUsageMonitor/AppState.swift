import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    // Live limit state (by seriesKey), account-wide values from the servers.
    var latestLimits: [String: LimitSnapshot] = [:]
    var claudeStatus: ServiceStatus = .unknown
    var codexStatus: ServiceStatus = .unknown
    var codexPlanType: String?
    var claudePlan: String?

    // False = the service isn't set up on this Mac (no credentials / no CLI).
    // Unconfigured services are hidden entirely instead of shown as errors;
    // re-checked every poll so they appear automatically once set up.
    var claudeConfigured = true
    var codexConfigured = true
    var codexIsFallback = false

    // History for charts.
    var limitHistory: [LimitSnapshot] = []

    private let claudeClient = ClaudeLimitsClient()
    private let codexClient = CodexAppServerClient()
    private let codexFallback = CodexLimitsReader()
    private let snapshotStore = SnapshotStore()

    private var pollTask: Task<Void, Never>?
    private var claudeBackoffUntil: Date = .distantPast
    private var claudeBackoffSeconds: Double = 60
    private var lastAppended: [String: LimitSnapshot] = [:]

    static let limitsInterval: Double = 60      // 1-minute sync for both services

    func start() {
        guard pollTask == nil else { return }
        migrateLegacyDefaults()
        limitHistory = snapshotStore.load(since: Date().addingTimeInterval(-90 * 86400))
        snapshotStore.prune()

        // Seed current values from the last recorded snapshots so a restart
        // (or a 429 right after launch) doesn't show "—" until the first fetch.
        for s in limitHistory where s.ts > Date().addingTimeInterval(-3600) {
            if let existing = latestLimits[s.seriesKey], existing.ts >= s.ts { continue }
            latestLimits[s.seriesKey] = s
            lastAppended[s.seriesKey] = s
        }

        // Lockout guard: never start with both the menu bar item and the HUD
        // hidden — there would be no way to reach the app.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "menuBarVisible") != nil,
           !defaults.bool(forKey: "menuBarVisible"),
           !defaults.bool(forKey: "showFloatingHUD") {
            defaults.set(true, forKey: "menuBarVisible")
        }

        Task { [weak self] in
            // NSApp isn't ready during App.init; apply the HUD setting shortly after.
            try? await Task.sleep(for: .seconds(1))
            if let self { FloatingHUDController.applyStartupSetting(state: self) }
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLimits()
                let configured = UserDefaults.standard.double(forKey: "pollIntervalSec")
                let interval = configured >= 30 ? configured : Self.limitsInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// One-time copy of settings and window positions from the old bundle id
    /// (com.tomoaki.usagebar) after the rename to CCCX Usage Monitor.
    private func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "didMigrateFromUsageBar") == nil,
              let legacy = UserDefaults(suiteName: "com.tomoaki.usagebar") else { return }
        let keep = ["menuBarStyle", "pollIntervalSec", "showFloatingHUD",
                    "menuBarVisible", "hudExpanded"]
        for (key, value) in legacy.dictionaryRepresentation()
        where keep.contains(key) || key.hasPrefix("NSWindow Frame") {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "didMigrateFromUsageBar")
    }

    // MARK: - Limits (60 s)

    func refreshLimits() async {
        async let claude: Void = refreshClaudeLimits()
        async let codex: Void = refreshCodexLimits()
        _ = await (claude, codex)
    }

    private func refreshClaudeLimits() async {
        guard Date() >= claudeBackoffUntil else { return }
        do {
            let (snapshots, plan) = try await claudeClient.fetch()
            apply(snapshots: snapshots)
            claudePlan = plan
            claudeConfigured = true
            claudeStatus = .ok(Date())
            claudeBackoffSeconds = Self.limitsInterval
        } catch let e as ClaudeAuthError {
            if case .notFound = e {
                claudeConfigured = false
                claudeStatus = .unknown
            } else {
                claudeStatus = .authError(e.localizedDescription)
            }
        } catch let e as ClaudeLimitsError {
            switch e {
            case .tokenExpired:
                claudeStatus = .authError(e.localizedDescription)
            case .rateLimited(let retryAfter):
                backoffClaude(retryAfter: retryAfter)
                claudeStatus = .stale(lastClaudeDataDate(), e.localizedDescription)
            default:
                backoffClaude(retryAfter: nil)
                claudeStatus = .fetchError(e.localizedDescription)
            }
        } catch {
            backoffClaude(retryAfter: nil)
            claudeStatus = .fetchError(error.localizedDescription)
        }
    }

    private func backoffClaude(retryAfter: TimeInterval?) {
        if let retryAfter {
            // Server told us exactly when to come back; add a little jitter so
            // we don't sync up with other pollers (e.g. Usage for Claude).
            claudeBackoffSeconds = retryAfter + Double.random(in: 2...10)
        } else {
            claudeBackoffSeconds = min(claudeBackoffSeconds * 2, 300)
        }
        claudeBackoffUntil = Date().addingTimeInterval(claudeBackoffSeconds)
    }

    /// Warn in the UI only when data is actually old — a brief 429 while we
    /// still have minutes-fresh values isn't worth an alert icon.
    var claudeShowWarning: Bool {
        switch claudeStatus {
        case .authError: return true
        case .ok, .unknown: return false
        case .stale, .fetchError:
            return Date().timeIntervalSince(lastClaudeDataDate()) > 600
        }
    }

    private func lastClaudeDataDate() -> Date {
        latestLimits.values.filter { $0.service == "claude" }.map(\.ts).max() ?? .distantPast
    }

    private func refreshCodexLimits() async {
        do {
            let (snapshots, plan) = try await codexClient.fetchRateLimits()
            apply(snapshots: snapshots)
            codexPlanType = plan
            codexIsFallback = false
            codexConfigured = true
            codexStatus = .ok(Date())
        } catch {
            // Fall back to the newest local rollout file.
            if let (snapshots, asOf) = codexFallback.latest() {
                apply(snapshots: snapshots)
                codexIsFallback = true
                codexConfigured = true
                codexStatus = .stale(asOf, "app-server不可 — 最終ローカル実行時点の値")
            } else if case CodexAppServerError.binaryNotFound = error {
                // No codex CLI and no session history: not set up on this Mac.
                codexConfigured = false
                codexStatus = .unknown
            } else {
                codexStatus = .fetchError(error.localizedDescription)
            }
        }
    }

    private func apply(snapshots: [LimitSnapshot]) {
        var toAppend: [LimitSnapshot] = []
        for s in snapshots {
            latestLimits[s.seriesKey] = s
            // Skip persisting when nothing changed (keeps files small).
            let prev = lastAppended[s.seriesKey]
            if prev?.usedPercent != s.usedPercent || prev?.resetsAt != s.resetsAt {
                toAppend.append(s)
                lastAppended[s.seriesKey] = s
            }
        }
        guard !toAppend.isEmpty else { return }
        snapshotStore.append(toAppend)
        limitHistory.append(contentsOf: toAppend)
    }

    // MARK: - Menu bar label

    /// The 5-hour window if the service has one; otherwise its highest window
    /// (e.g. Codex on a weekly-only plan). Expired windows count as 0.
    func displayPercent(service: String) -> Double? {
        let values = latestLimits.values.filter { $0.service == service }
        return values.first { $0.windowMinutes == 300 }?.effectivePercent
            ?? values.map(\.effectivePercent).max()
    }

    var menuBarTitle: String {
        func part(_ prefix: String, service: String, problem: Bool) -> String {
            guard let pct = displayPercent(service: service) else {
                return "\(prefix) —\(problem ? "⚠" : "")"
            }
            return "\(prefix) \(Int(pct))%\(problem ? "⚠" : "")"
        }
        var parts: [String] = []
        if claudeConfigured { parts.append(part("C", service: "claude", problem: claudeShowWarning)) }
        if codexConfigured { parts.append(part("X", service: "codex", problem: codexStatus.isProblem && !codexIsFallback)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var sortedCurrentLimits: [LimitSnapshot] {
        latestLimits.values.sorted { a, b in
            if a.service != b.service { return a.service < b.service }
            return a.seriesKey < b.seriesKey
        }
    }
}
