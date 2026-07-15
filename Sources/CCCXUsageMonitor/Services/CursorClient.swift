import Foundation

enum CursorError: Error, LocalizedError {
    case notInstalled
    case tokenUnreadable
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Cursor が見つかりません"
        case .tokenUnreadable: return "Cursor の認証情報を読めません"
        case .httpError(let c): return "Cursor usage API エラー (HTTP \(c))"
        }
    }
}

/// Reads the Cursor session token from its settings DB (plain SQLite) and
/// queries the usage API — verified live on cursor.com 2026-07-15.
struct CursorClient {
    private var dbPath: String {
        NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }

    private func sqliteValue(key: String) throws -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [dbPath, "SELECT value FROM ItemTable WHERE key='\(key)'"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    func fetch() async throws -> (snapshots: [LimitSnapshot], plan: String?) {
        guard FileManager.default.fileExists(atPath: dbPath) else { throw CursorError.notInstalled }
        guard let token = try? sqliteValue(key: "cursorAuth/accessToken"), !token.isEmpty else {
            throw CursorError.notInstalled   // installed but never logged in → treat as unconfigured
        }
        let plan = (try? sqliteValue(key: "cursorAuth/stripeMembershipType")) ?? nil

        // user id = JWT `sub` (e.g. "github|user_xxx"); cookie wants the part after "|".
        guard let sub = jwtSub(token) else { throw CursorError.tokenUnreadable }
        let userId = sub.components(separatedBy: "|").last ?? sub

        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage?user=\(sub)")!,
                             timeoutInterval: 10)
        req.setValue("WorkosCursorSessionToken=\(userId)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CursorError.httpError(status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorError.httpError(0)
        }

        // {"gpt-4": {numRequests, maxRequestUsage, ...}, "startOfMonth": ISO}
        var snapshots: [LimitSnapshot] = []
        if let bucket = obj["gpt-4"] as? [String: Any],
           let used = anyToDouble(bucket["numRequests"]) {
            var resets: Date?
            if let som = ClaudeLimitsClient.parseISO(obj["startOfMonth"] as? String) {
                resets = Calendar.current.date(byAdding: .month, value: 1, to: som)
            }
            if let maxReq = anyToDouble(bucket["maxRequestUsage"]), maxReq > 0 {
                snapshots.append(LimitSnapshot(
                    ts: Date(), seriesKey: "cursor:monthly",
                    usedPercent: min(used / maxReq * 100, 100),
                    resetsAt: resets, windowMinutes: 43200, severity: nil))
            }
            // Plans without a request cap (free / usage-based) have max == null:
            // nothing meaningful to chart, so no snapshot — the service still
            // shows as configured with its plan name.
        }
        return (snapshots, plan)
    }

    private func jwtSub(_ jwt: String) -> String? {
        let parts = jwt.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sub"] as? String
    }
}
