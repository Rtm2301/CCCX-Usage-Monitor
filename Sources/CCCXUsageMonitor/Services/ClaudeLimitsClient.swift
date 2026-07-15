import Foundation

enum ClaudeLimitsError: Error, LocalizedError {
    case tokenExpired
    case rateLimited(retryAfter: TimeInterval?)
    case httpError(Int)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .tokenExpired: return "トークン期限切れ — Claude Code を一度開くと更新されます"
        case .rateLimited: return "usage API がレート制限中 (429)"
        case .httpError(let code): return "usage API エラー (HTTP \(code))"
        case .decodeFailed: return "usage API のレスポンスを解析できません"
        }
    }
}

/// Fetches account-wide rate-limit utilization from Anthropic's
/// (undocumented) OAuth usage endpoint — the same source Claude Code's
/// own /usage display and existing menu bar apps use.
struct ClaudeLimitsClient {
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoParserNoFrac = ISO8601DateFormatter()

    static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoParser.date(from: s) ?? isoParserNoFrac.date(from: s)
    }

    func fetch() async throws -> (snapshots: [LimitSnapshot], plan: String?) {
        let creds = try ClaudeAuth.credentials()
        var req = URLRequest(url: Self.url, timeoutInterval: 10)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        // Ephemeral session per fetch: a long-lived shared session once got
        // stuck receiving 429s for hours while fresh connections were fine.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if ProcessInfo.processInfo.environment["USAGEBAR_FAKE_401"] == "1" {
            throw ClaudeLimitsError.tokenExpired
        }
        switch status {
        case 200: break
        case 401, 403:
            Paths.diag("claude HTTP \(status)")
            throw ClaudeLimitsError.tokenExpired
        case 429:
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            Paths.diag("claude HTTP 429 retry-after=\(retryAfter.map { String($0) } ?? "none")")
            throw ClaudeLimitsError.rateLimited(retryAfter: retryAfter)
        default:
            Paths.diag("claude HTTP \(status)")
            throw ClaudeLimitsError.httpError(status)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeLimitsError.decodeFailed
        }
        let now = Date()
        var snapshots: [LimitSnapshot] = []

        // Primary source: `limits` array (verified live 2026-07-14).
        if let limits = obj["limits"] as? [[String: Any]] {
            for l in limits {
                guard let kind = l["kind"] as? String,
                      let percent = anyToDouble(l["percent"]) else { continue }
                var key = "claude:\(kind)"
                if kind == "weekly_scoped",
                   let scope = l["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String {
                    key = "claude:weekly_scoped:\(name)"
                }
                snapshots.append(LimitSnapshot(
                    ts: now,
                    seriesKey: key,
                    usedPercent: percent,
                    resetsAt: Self.parseISO(l["resets_at"] as? String),
                    windowMinutes: kind == "session" ? 300 : 10080,
                    severity: l["severity"] as? String
                ))
            }
        }

        // Fallback: five_hour / seven_day objects.
        if snapshots.isEmpty {
            let windows: [(String, String, Int)] = [
                ("five_hour", "claude:session", 300),
                ("seven_day", "claude:weekly_all", 10080),
            ]
            for (field, key, mins) in windows {
                if let w = obj[field] as? [String: Any],
                   let pct = anyToDouble(w["utilization"]) {
                    snapshots.append(LimitSnapshot(
                        ts: now, seriesKey: key, usedPercent: pct,
                        resetsAt: Self.parseISO(w["resets_at"] as? String),
                        windowMinutes: mins, severity: nil))
                }
            }
        }

        guard !snapshots.isEmpty else { throw ClaudeLimitsError.decodeFailed }
        return (snapshots, creds.plan)
    }
}

func anyToDouble(_ v: Any?) -> Double? {
    switch v {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    default: return nil
    }
}
