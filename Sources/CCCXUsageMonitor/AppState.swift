import Foundation
import Observation
import AppKit

@Observable
@MainActor
final class AppState {
    // Live limit state (by seriesKey), account-wide values from the servers.
    var latestLimits: [String: LimitSnapshot] = [:]
    var statuses: [ServiceID: ServiceStatus] = [:]
    var plans: [ServiceID: String] = [:]

    // False = the service isn't set up on this Mac (no credentials / no CLI).
    // Unconfigured services are hidden instead of shown as errors; re-checked
    // every poll so they appear automatically once set up.
    var configuredMap: [ServiceID: Bool] = [.claude: true, .codex: true, .cursor: true, .copilot: false]
    var codexIsFallback = false

    // Which services the user wants to see (popover toggles).
    var enabledSet: Set<ServiceID> = Set(ServiceID.allCases)

    // Copilot device-flow login state (popover UI).
    var copilotDeviceCode: CopilotClient.DeviceCode?
    var copilotLoginFailed = false

    // History for charts.
    var limitHistory: [LimitSnapshot] = []

    /// Next scheduled Claude retry while the usage API is rate-limiting us.
    /// Non-nil only during a 429 backoff; shown as a banner in the popover.
    var claudeRetryAt: Date?

    private let claudeClient = ClaudeLimitsClient()
    private let codexClient = CodexAppServerClient()
    private let codexFallback = CodexLimitsReader()
    private let cursorClient = CursorClient()
    let copilotClient = CopilotClient()
    private let snapshotStore = SnapshotStore()

    private var pollTask: Task<Void, Never>?
    private var claudeBackoffUntil: Date = .distantPast
    private var claudeBackoffSeconds: Double = 60
    private var lastAppended: [String: LimitSnapshot] = [:]
    private var notifiedWindows: Set<String> = []

    static let limitsInterval: Double = 60      // 1-minute sync

    // MARK: - Accessors

    func configured(_ s: ServiceID) -> Bool { configuredMap[s] ?? false }
    func status(_ s: ServiceID) -> ServiceStatus { statuses[s] ?? .unknown }
    func isEnabled(_ s: ServiceID) -> Bool { enabledSet.contains(s) }

    func setEnabled(_ s: ServiceID, _ on: Bool) {
        if on { enabledSet.insert(s) } else { enabledSet.remove(s) }
        UserDefaults.standard.set(enabledSet.map(\.rawValue).sorted(), forKey: "enabledServices")
        if on { Task { await refreshLimits() } }
    }

    /// Plans are persisted so a fetch failure after restart doesn't blank them.
    private func setPlan(_ s: ServiceID, _ plan: String?) {
        guard let plan, !plan.isEmpty else { return }
        plans[s] = plan
        let dict = Dictionary(uniqueKeysWithValues: plans.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(dict, forKey: "plans")
    }

    /// Services that should appear in the menu bar / HUD.
    var visibleServices: [ServiceID] {
        ServiceID.allCases.filter { isEnabled($0) && configured($0) }
    }

    /// Warn only when data is actually old — a brief failure while we still
    /// have minutes-fresh values isn't worth an alert icon.
    func showWarning(_ s: ServiceID) -> Bool {
        switch status(s) {
        case .authError: return true
        case .ok, .unknown: return false
        case .stale, .fetchError:
            return Date().timeIntervalSince(lastDataDate(s)) > 600
        }
    }

    private func lastDataDate(_ s: ServiceID) -> Date {
        latestLimits.values.filter { $0.service == s.rawValue }.map(\.ts).max() ?? .distantPast
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        migrateLegacyDefaults()
        if let saved = UserDefaults.standard.stringArray(forKey: "enabledServices") {
            enabledSet = Set(saved.compactMap(ServiceID.init(rawValue:)))
        }
        if let savedPlans = UserDefaults.standard.dictionary(forKey: "plans") as? [String: String] {
            for (k, v) in savedPlans {
                if let s = ServiceID(rawValue: k) { plans[s] = v }
            }
        }
        limitHistory = snapshotStore.load(since: Date().addingTimeInterval(-90 * 86400))
        snapshotStore.prune()

        // Seed current values from the last recorded snapshots so a restart
        // doesn't show "—" until the first fetch.
        for s in limitHistory where s.ts > Date().addingTimeInterval(-3600) {
            if let existing = latestLimits[s.seriesKey], existing.ts >= s.ts { continue }
            latestLimits[s.seriesKey] = s
            lastAppended[s.seriesKey] = s
        }

        // Lockout guard: never start with both the menu bar item and the HUD hidden.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "menuBarVisible") != nil,
           !defaults.bool(forKey: "menuBarVisible"),
           !defaults.bool(forKey: "showFloatingHUD") {
            defaults.set(true, forKey: "menuBarVisible")
        }

        Task { [weak self] in
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

    /// One-time copy of settings from the old bundle id after the rename.
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

    // MARK: - Polling

    func refreshLimits() async {
        async let claude: Void = isEnabled(.claude) ? refreshClaude() : ()
        async let codex: Void = isEnabled(.codex) ? refreshCodex() : ()
        async let cursor: Void = isEnabled(.cursor) ? refreshCursor() : ()
        async let copilot: Void = isEnabled(.copilot) ? refreshCopilot() : ()
        _ = await (claude, codex, cursor, copilot)
    }

    private func refreshClaude() async {
        guard Date() >= claudeBackoffUntil else { return }
        do {
            let (snapshots, plan) = try await claudeClient.fetch()
            apply(snapshots: snapshots)
            setPlan(.claude, plan)
            configuredMap[.claude] = true
            statuses[.claude] = .ok(Date())
            claudeBackoffSeconds = Self.limitsInterval
            claudeRetryAt = nil
        } catch let e as ClaudeAuthError {
            if case .notFound = e {
                configuredMap[.claude] = false
                statuses[.claude] = .unknown
            } else {
                statuses[.claude] = .authError(e.localizedDescription)
            }
        } catch let e as ClaudeLimitsError {
            switch e {
            case .tokenExpired:
                claudeRetryAt = nil
                statuses[.claude] = .authError(e.localizedDescription)
            case .rateLimited(let retryAfter):
                backoffClaude(retryAfter: retryAfter)
                claudeRetryAt = claudeBackoffUntil
                statuses[.claude] = .stale(lastDataDate(.claude), e.localizedDescription)
            default:
                backoffClaude(retryAfter: nil)
                claudeRetryAt = nil
                statuses[.claude] = .fetchError(e.localizedDescription)
            }
        } catch {
            backoffClaude(retryAfter: nil)
            claudeRetryAt = nil
            statuses[.claude] = .fetchError(error.localizedDescription)
        }
    }

    private func backoffClaude(retryAfter: TimeInterval?) {
        if let retryAfter {
            // Honor the server's Retry-After verbatim (60s floor + jitter).
            // Clamping it to 10 min once caused an endless 429 loop: each
            // early retry kept the server-side window from ever clearing.
            claudeBackoffSeconds = max(retryAfter, 60) + Double.random(in: 5...30)
        } else {
            claudeBackoffSeconds = min(claudeBackoffSeconds * 2, 300)
        }
        claudeBackoffUntil = Date().addingTimeInterval(claudeBackoffSeconds)
    }

    private func refreshCodex() async {
        do {
            let (snapshots, plan) = try await codexClient.fetchRateLimits()
            apply(snapshots: snapshots)
            setPlan(.codex, plan)
            codexIsFallback = false
            configuredMap[.codex] = true
            statuses[.codex] = .ok(Date())
        } catch {
            if let (snapshots, asOf) = codexFallback.latest() {
                apply(snapshots: snapshots)
                codexIsFallback = true
                configuredMap[.codex] = true
                statuses[.codex] = .stale(asOf, "app-server不可 — 最終ローカル実行時点の値")
            } else if case CodexAppServerError.binaryNotFound = error {
                configuredMap[.codex] = false
                statuses[.codex] = .unknown
            } else {
                statuses[.codex] = .fetchError(error.localizedDescription)
            }
        }
    }

    private func refreshCursor() async {
        do {
            let (snapshots, plan) = try await cursorClient.fetch()
            apply(snapshots: snapshots)
            setPlan(.cursor, plan)
            configuredMap[.cursor] = true
            statuses[.cursor] = .ok(Date())
        } catch is CursorError where !FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb") {
            configuredMap[.cursor] = false
            statuses[.cursor] = .unknown
        } catch CursorError.notInstalled {
            configuredMap[.cursor] = false
            statuses[.cursor] = .unknown
        } catch {
            statuses[.cursor] = .fetchError(error.localizedDescription)
        }
    }

    private func refreshCopilot() async {
        guard copilotClient.hasToken else {
            configuredMap[.copilot] = false
            statuses[.copilot] = .unknown
            return
        }
        do {
            let (snapshots, plan) = try await copilotClient.fetch()
            apply(snapshots: snapshots)
            setPlan(.copilot, plan)
            configuredMap[.copilot] = true
            statuses[.copilot] = .ok(Date())
        } catch CopilotError.notLoggedIn {
            statuses[.copilot] = .authError("Copilot のログインが無効です — 再ログインしてください")
        } catch {
            statuses[.copilot] = .fetchError(error.localizedDescription)
        }
    }

    // MARK: - Copilot device-flow login (driven from the popover)

    func startCopilotLogin() {
        copilotLoginFailed = false
        Task {
            do {
                let dc = try await copilotClient.startDeviceFlow()
                copilotDeviceCode = dc
                NSWorkspace.shared.open(URL(string: dc.verificationURI)!)
                try await copilotClient.waitForToken(dc)
                copilotDeviceCode = nil
                await refreshCopilot()
            } catch {
                copilotDeviceCode = nil
                copilotLoginFailed = true
            }
        }
    }

    // MARK: - Apply

    private func apply(snapshots: [LimitSnapshot]) {
        var toAppend: [LimitSnapshot] = []
        for s in snapshots {
            // Never let an older snapshot (e.g. the Codex rollout-file fallback)
            // overwrite a newer live value.
            if let existing = latestLimits[s.seriesKey], existing.ts > s.ts { continue }
            latestLimits[s.seriesKey] = s
            checkNotifyThreshold(s)
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

    /// One notification per window when it crosses the configured threshold
    /// (0 = off). The window key includes resets_at, so each new window can
    /// notify again.
    private func checkNotifyThreshold(_ s: LimitSnapshot) {
        let threshold = UserDefaults.standard.double(forKey: "notifyThreshold")
        guard threshold > 0, s.usedPercent >= threshold, !s.isExpired else { return }
        let windowKey = "\(s.seriesKey)|\(s.resetsAt?.timeIntervalSince1970 ?? 0)"
        guard !notifiedWindows.contains(windowKey) else { return }
        notifiedWindows.insert(windowKey)
        var body = "現在 \(Int(s.usedPercent))%"
        if let r = s.resetsAt { body += " — リセット: \(LimitGaugeRow.resetDetail(r))" }
        Notifier.send(title: "\(s.displayName) が \(Int(threshold))% に到達", body: body)
    }

    // MARK: - Display helpers

    /// The headline window per service: 5-hour if it has one, otherwise its
    /// highest window.
    func displayLimit(service: String) -> LimitSnapshot? {
        let values = latestLimits.values.filter { $0.service == service }
        return values.first { $0.windowMinutes == 300 }
            ?? values.max { $0.effectivePercent < $1.effectivePercent }
    }

    func displayPercent(service: String) -> Double? {
        displayLimit(service: service)?.effectivePercent
    }

    var menuBarTitle: String {
        let parts = visibleServices.map { s in
            let warn = showWarning(s) ? "⚠" : ""
            guard let pct = displayPercent(service: s.rawValue) else {
                return "\(s.displayName) —\(warn)"
            }
            return "\(s.displayName) \(Int(pct))%\(warn)"
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var sortedCurrentLimits: [LimitSnapshot] {
        latestLimits.values
            .filter { s in ServiceID(rawValue: s.service).map(isEnabled) ?? true }
            .sorted { a, b in
                if a.service != b.service { return a.service < b.service }
                return a.seriesKey < b.seriesKey
            }
    }
}
