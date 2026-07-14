import Foundation

enum CodexAppServerError: Error, LocalizedError {
    case binaryNotFound
    case notRunning
    case timeout
    case rpcError(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "codex CLI が見つかりません"
        case .notRunning: return "codex app-server が起動していません"
        case .timeout: return "codex app-server が応答しません"
        case .rpcError(let m): return "codex RPC エラー: \(m)"
        case .decodeFailed: return "codex のレスポンスを解析できません"
        }
    }
}

/// Keeps a long-lived `codex app-server` child process and speaks
/// line-delimited JSON-RPC to it. `account/rateLimits/read` returns the
/// account-wide ChatGPT rate-limit snapshot (verified on codex-cli 0.144.3).
actor CodexAppServerClient {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var initialized = false

    private static func findCodexBinary() -> String? {
        if let p = ProcessInfo.processInfo.environment["USAGEBAR_CODEX_BIN"],
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            NSHomeDirectory() + "/bin/codex",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Last resort: ask a login shell (GUI apps have a minimal PATH).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        if (try? proc.run()) != nil {
            proc.waitUntilExit()
            if proc.terminationStatus == 0,
               let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return s }
        }
        return nil
    }

    private func ensureRunning() async throws {
        if let p = process, p.isRunning, initialized { return }
        try await start()
    }

    private func start() async throws {
        stop()
        guard let bin = Self.findCodexBinary() else { throw CodexAppServerError.binaryNotFound }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["app-server"]
        // codex is often a Node script (#!/usr/bin/env node); GUI apps get a
        // minimal PATH without Homebrew, so env can't find node without this.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        proc.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.ingest(data) }
        }
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleTermination() }
        }

        try proc.run()
        process = proc
        stdinPipe = inPipe
        initialized = false

        let initResult = try await request(method: "initialize", params: [
            "clientInfo": ["name": "usagebar", "title": "UsageBar", "version": "0.1.0"],
        ])
        _ = initResult
        try send(obj: ["jsonrpc": "2.0", "method": "initialized"])
        initialized = true
    }

    func stop() {
        stdinPipe = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        initialized = false
        buffer.removeAll()
        for (_, cont) in pending { cont.resume(throwing: CodexAppServerError.notRunning) }
        pending.removeAll()
    }

    private func handleTermination() {
        for (_, cont) in pending { cont.resume(throwing: CodexAppServerError.notRunning) }
        pending.removeAll()
        initialized = false
        process = nil
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int,
                  let cont = pending.removeValue(forKey: id) else { continue } // notifications ignored
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: CodexAppServerError.rpcError("\(err["message"] ?? err)"))
            } else {
                cont.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
            }
        }
    }

    private func send(obj: [String: Any]) throws {
        guard let pipe = stdinPipe else { throw CodexAppServerError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try pipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func request(method: String, params: [String: Any], timeoutSeconds: Double = 15) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        try send(obj: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])

        // Race the response against a timeout.
        let result: [String: Any] = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self.timeoutRequest(id: id)
            }
        }
        return result
    }

    private func timeoutRequest(id: Int) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: CodexAppServerError.timeout)
        }
    }

    /// Fetch current account-wide rate limits. Returns snapshots + plan type.
    func fetchRateLimits() async throws -> (snapshots: [LimitSnapshot], planType: String?) {
        try await ensureRunning()
        let result = try await request(method: "account/rateLimits/read", params: [:])
        guard let rl = result["rateLimits"] as? [String: Any] else {
            throw CodexAppServerError.decodeFailed
        }
        let now = Date()
        var snapshots: [LimitSnapshot] = []
        for (field, key) in [("primary", "codex:primary"), ("secondary", "codex:secondary")] {
            guard let w = rl[field] as? [String: Any],
                  let pct = anyToDouble(w["usedPercent"]) else { continue }
            var resetsAt: Date?
            if let epoch = anyToDouble(w["resetsAt"]) { resetsAt = Date(timeIntervalSince1970: epoch) }
            snapshots.append(LimitSnapshot(
                ts: now, seriesKey: key, usedPercent: pct,
                resetsAt: resetsAt,
                windowMinutes: anyToDouble(w["windowDurationMins"]).map(Int.init),
                severity: nil))
        }
        guard !snapshots.isEmpty else { throw CodexAppServerError.decodeFailed }
        return (snapshots, rl["planType"] as? String)
    }
}
