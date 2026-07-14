import Foundation

/// Fallback source for Codex limits: the newest rollout session file.
/// Keys here are snake_case (unlike the app-server RPC, which is camelCase).
/// The value reflects the last time codex actually ran on this machine.
struct CodexLimitsReader {
    func latest() -> (snapshots: [LimitSnapshot], asOf: Date)? {
        guard let file = newestRolloutFile() else { return nil }
        guard let line = lastTokenCountLine(in: file) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }

        let asOf = ClaudeLimitsClient.parseISO(obj["timestamp"] as? String) ?? Date()
        var snapshots: [LimitSnapshot] = []
        for (field, key) in [("primary", "codex:primary"), ("secondary", "codex:secondary")] {
            guard let w = rateLimits[field] as? [String: Any],
                  let pct = anyToDouble(w["used_percent"]) else { continue }
            var resetsAt: Date?
            if let epoch = anyToDouble(w["resets_at"]) { resetsAt = Date(timeIntervalSince1970: epoch) }
            snapshots.append(LimitSnapshot(
                ts: asOf, seriesKey: key, usedPercent: pct,
                resetsAt: resetsAt,
                windowMinutes: anyToDouble(w["window_minutes"]).map(Int.init),
                severity: nil))
        }
        return snapshots.isEmpty ? nil : (snapshots, asOf)
    }

    private func newestRolloutFile() -> URL? {
        let sessionsDir = Paths.codexDir.appendingPathComponent("sessions")
        let fm = FileManager.default
        // Layout: sessions/YYYY/MM/DD/rollout-*.jsonl — descend the largest path components.
        var dir = sessionsDir
        for _ in 0..<3 {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                  let newest = entries.filter({ $0.hasDirectoryPath }).map(\.lastPathComponent).sorted().last
            else { break }
            dir = dir.appendingPathComponent(newest)
        }
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
            .max { a, b in
                let ma = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let mb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return ma < mb
            }
    }

    /// Read the tail of the file and return the last line containing a token_count event.
    private func lastTokenCountLine(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 256 * 1024
        let start = size > chunk ? size - chunk : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .last { $0.contains("\"token_count\"") && $0.contains("\"rate_limits\"") }
            .map(String.init)
    }
}
