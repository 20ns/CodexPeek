import Foundation

final class CodexSessionLogUsageSource: SessionLogUsageSource, @unchecked Sendable {
    private static let maxFallbackCandidates = 30

    private let sessionsRootURL: URL
    private let fileManager: FileManager

    init(
        sessionsRootURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex/sessions").expandingTildeInPath),
        fileManager: FileManager = .default
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.fileManager = fileManager
    }

    func latestSnapshot() throws -> CodexUsageSnapshot? {
        let files = try sessionLogFiles()

        for fileURL in files {
            guard let snapshot = try snapshot(from: fileURL) else {
                continue
            }
            return snapshot
        }

        return nil
    }

    private func sessionLogFiles() throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            files.append((fileURL, modifiedAt))
            if files.count > Self.maxFallbackCandidates {
                files.sort { lhs, rhs in lhs.modifiedAt > rhs.modifiedAt }
                files.removeLast(files.count - Self.maxFallbackCandidates)
            }
        }

        return files
            .sorted { lhs, rhs in lhs.modifiedAt > rhs.modifiedAt }
            .map(\.url)
    }

    private func snapshot(from fileURL: URL) throws -> CodexUsageSnapshot? {
        let tail = try readTail(of: fileURL, maxBytes: 200_000)
        let text = String(decoding: tail.data, as: UTF8.self)
        var lines = text.split(whereSeparator: \.isNewline)
        if tail.startedMidFile, !lines.isEmpty {
            lines.removeFirst()
        }

        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard line.contains("\"token_count\""), line.contains("\"rate_limits\"") else {
                continue
            }

            guard let entry = try? decoder.decode(SessionLogEntry.self, from: Data(line.utf8)) else {
                continue
            }

            guard
                entry.type == "event_msg",
                entry.payload?.type == "token_count",
                let rateLimits = entry.payload?.rateLimits
            else {
                continue
            }

            return CodexUsageSnapshot(
                account: .empty,
                primary: rateLimits.primary.map(mapWindow),
                secondary: rateLimits.secondary.map(mapWindow),
                source: .sessionLog,
                lastUpdatedAt: timestamp(from: entry.timestamp) ?? modificationDate(for: fileURL) ?? Date(),
                isStale: true
            )
        }

        return nil
    }

    private func readTail(of fileURL: URL, maxBytes: Int) throws -> (data: Data, startedMidFile: Bool) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let offset = max(0, Int64(fileSize) - Int64(maxBytes))
        try handle.seek(toOffset: UInt64(offset))
        return (try handle.readToEnd() ?? Data(), offset > 0)
    }

    private func timestamp(from value: String?) -> Date? {
        guard let value else {
            return nil
        }

        return Formatters.parseISO8601(value)
    }

    private func modificationDate(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    private func mapWindow(_ payload: SessionRateLimitWindow) -> RateLimitWindowSnapshot {
        RateLimitWindowSnapshot(
            usedPercent: max(0, min(100, Int(payload.usedPercent.rounded()))),
            windowDurationMins: payload.windowMinutes,
            resetsAt: payload.resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private struct SessionLogEntry: Decodable {
    let timestamp: String?
    let type: String
    let payload: SessionLogPayload?
}

private struct SessionLogPayload: Decodable {
    let type: String?
    let rateLimits: SessionRateLimitsPayload?

    private enum CodingKeys: String, CodingKey {
        case type
        case rateLimits = "rate_limits"
    }
}

private struct SessionRateLimitsPayload: Decodable {
    let primary: SessionRateLimitWindow?
    let secondary: SessionRateLimitWindow?
}

private struct SessionRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}
