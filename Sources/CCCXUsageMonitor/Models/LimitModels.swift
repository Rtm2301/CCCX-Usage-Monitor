import Foundation

/// One observed value of one rate-limit window at one point in time.
/// `seriesKey` examples:
///   "claude:session", "claude:weekly_all", "claude:weekly_scoped:Fable",
///   "codex:primary", "codex:secondary"
struct LimitSnapshot: Codable, Hashable {
    let ts: Date
    let seriesKey: String
    let usedPercent: Double
    let resetsAt: Date?
    let windowMinutes: Int?
    let severity: String?
}

extension LimitSnapshot {
    var service: String { seriesKey.hasPrefix("claude") ? "claude" : "codex" }

    /// The window has reset since this value was fetched — the recorded
    /// percent no longer reflects reality (a fresh window starts at 0).
    var isExpired: Bool {
        guard let resetsAt else { return false }
        return resetsAt.addingTimeInterval(30) < Date()
    }

    /// Percent to display right now: expired windows show 0, not the stale value.
    var effectivePercent: Double { isExpired ? 0 : usedPercent }

    var displayName: String {
        switch seriesKey {
        case "claude:session": return "Claude セッション (5h)"
        case "claude:weekly_all": return "Claude 週次 (全体)"
        case "codex:primary": return "Codex 週次"
        case "codex:secondary": return "Codex セカンダリ"
        default:
            if seriesKey.hasPrefix("claude:weekly_scoped:") {
                let model = seriesKey.components(separatedBy: ":").last ?? "?"
                return "Claude 週次 (\(model))"
            }
            return seriesKey
        }
    }
}

enum ServiceStatus: Equatable {
    case ok(Date)                 // last successful fetch
    case stale(Date, String)      // last data timestamp + reason
    case authError(String)
    case fetchError(String)
    case unknown

    var isProblem: Bool {
        switch self {
        case .ok: return false
        default: return true
        }
    }
}
