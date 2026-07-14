import Foundation

/// Appends limit snapshots to monthly JSONL files and loads them back for charts.
/// The usage APIs only return the *current* value, so history exists only
/// while this app is running and recording.
struct SnapshotStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func fileURL(for date: Date) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return Paths.snapshotsDir.appendingPathComponent("\(f.string(from: date)).jsonl")
    }

    func append(_ snapshots: [LimitSnapshot]) {
        guard !snapshots.isEmpty else { return }
        var data = Data()
        for s in snapshots {
            guard let line = try? Self.encoder.encode(s) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        let url = fileURL(for: Date())
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func load(since: Date) -> [LimitSnapshot] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.snapshotsDir, includingPropertiesForKeys: nil) else { return [] }
        var result: [LimitSnapshot] = []
        for file in files.filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let s = try? Self.decoder.decode(LimitSnapshot.self, from: Data(line.utf8)) else { continue }
                if s.ts >= since { result.append(s) }
            }
        }
        return result.sorted { $0.ts < $1.ts }
    }

    /// Keep the 3 most recent monthly files (~90 days).
    func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Paths.snapshotsDir, includingPropertiesForKeys: nil) else { return }
        let sorted = files.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sorted.dropFirst(3) { try? fm.removeItem(at: old) }
    }
}
