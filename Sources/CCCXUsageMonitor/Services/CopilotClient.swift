import Foundation

enum CopilotError: Error, LocalizedError {
    case notLoggedIn
    case httpError(Int)
    case authPending

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Copilot 未ログイン"
        case .httpError(let c): return "Copilot API エラー (HTTP \(c))"
        case .authPending: return "認証待ち"
        }
    }
}

/// GitHub Copilot quota via the internal user endpoint. VS Code's token is not
/// extractable (encrypted secret storage), so the app does its own GitHub
/// device-flow login (same client id the Copilot plugins use) and stores the
/// OAuth token locally.
struct CopilotClient {
    static let clientID = "Iv1.b507a08c87ecfe98"

    struct DeviceCode {
        let userCode: String
        let verificationURI: String
        let deviceCode: String
        let interval: Double
    }

    private var tokenFile: URL { Paths.dataDir.appendingPathComponent("copilot-token.json") }

    var hasToken: Bool { FileManager.default.fileExists(atPath: tokenFile.path) }

    private func storedToken() -> String? {
        guard let data = try? Data(contentsOf: tokenFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["access_token"] as? String
    }

    func logout() {
        try? FileManager.default.removeItem(at: tokenFile)
    }

    // MARK: - Device flow

    func startDeviceFlow() async throws -> DeviceCode {
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID, "scope": "read:user",
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = obj["user_code"] as? String,
              let uri = obj["verification_uri"] as? String,
              let device = obj["device_code"] as? String else {
            throw CopilotError.httpError(0)
        }
        return DeviceCode(userCode: user, verificationURI: uri, deviceCode: device,
                          interval: anyToDouble(obj["interval"]) ?? 5)
    }

    /// Polls until the user authorizes in the browser; saves the token.
    func waitForToken(_ dc: DeviceCode, timeout: TimeInterval = 600) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(dc.interval + 1))
            var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": Self.clientID,
                "device_code": dc.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let token = obj["access_token"] as? String {
                let out = try JSONSerialization.data(withJSONObject: ["access_token": token])
                try out.write(to: tokenFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
                return
            }
            if (obj["error"] as? String) == "authorization_pending" { continue }
            if (obj["error"] as? String) == "slow_down" { continue }
            if obj["error"] != nil { throw CopilotError.httpError(0) }
        }
        throw CopilotError.authPending
    }

    // MARK: - Quota

    func fetch() async throws -> (snapshots: [LimitSnapshot], plan: String?) {
        guard let token = storedToken() else { throw CopilotError.notLoggedIn }
        var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!,
                             timeoutInterval: 10)
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("vscode/1.106.0", forHTTPHeaderField: "Editor-Version")
        req.setValue("GitHubCopilotChat/0.32", forHTTPHeaderField: "Editor-Plugin-Version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CopilotError.notLoggedIn }
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CopilotError.httpError(status)
        }

        var snapshots: [LimitSnapshot] = []
        var resets: Date?
        if let dateStr = obj["quota_reset_date"] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            resets = f.date(from: dateStr)
        }
        if let quotas = obj["quota_snapshots"] as? [String: Any],
           let premium = quotas["premium_interactions"] as? [String: Any] {
            let unlimited = (premium["unlimited"] as? Bool) ?? false
            if !unlimited, let remaining = anyToDouble(premium["percent_remaining"]) {
                snapshots.append(LimitSnapshot(
                    ts: Date(), seriesKey: "copilot:premium",
                    usedPercent: min(max(100 - remaining, 0), 100),
                    resetsAt: resets, windowMinutes: 43200, severity: nil))
            }
        }
        let plan = obj["copilot_plan"] as? String
        return (snapshots, plan)
    }
}
