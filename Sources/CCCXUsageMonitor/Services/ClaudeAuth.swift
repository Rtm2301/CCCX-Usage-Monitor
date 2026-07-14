import Foundation

enum ClaudeAuthError: Error, LocalizedError {
    case notFound
    case parseFailed
    case securityCLIFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Keychain に Claude Code の認証情報が見つかりません"
        case .parseFailed: return "認証情報の JSON を解析できません"
        case .securityCLIFailed(let code): return "security CLI がエラー終了しました (\(code))"
        }
    }
}

/// Reads the Claude Code OAuth access token from the login Keychain.
/// Uses /usr/bin/security (Apple-signed) so the user's one-time
/// "Always Allow" persists across rebuilds of this unsigned binary.
enum ClaudeAuth {
    struct Credentials {
        let accessToken: String
        let plan: String?      // e.g. "max 5x" from subscriptionType + rateLimitTier
    }

    static func accessToken() throws -> String {
        try credentials().accessToken
    }

    static func credentials() throws -> Credentials {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", Paths.keychainService, "-w"]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            if proc.terminationStatus == 44 { throw ClaudeAuthError.notFound } // errSecItemNotFound
            throw ClaudeAuthError.securityCLIFailed(proc.terminationStatus)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ClaudeAuthError.notFound
        }
        // Blob is JSON: {"claudeAiOauth": {"accessToken": ...}} or flat {"accessToken": ...}
        guard let jsonData = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ClaudeAuthError.parseFailed
        }
        let container = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let token = container["accessToken"] as? String, !token.isEmpty else {
            throw ClaudeAuthError.parseFailed
        }

        var plan: String?
        if let sub = container["subscriptionType"] as? String {
            plan = sub
            // "default_claude_max_5x" → append "5x"
            if let tier = container["rateLimitTier"] as? String,
               let multiplier = tier.split(separator: "_").last,
               multiplier.hasSuffix("x") {
                plan = "\(sub) \(multiplier)"
            }
        }
        return Credentials(accessToken: token, plan: plan)
    }
}
