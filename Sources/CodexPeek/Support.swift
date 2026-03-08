import Foundation

protocol CodexUsageLiveSource: Sendable {
    func fetchUsageSnapshot() async throws -> CodexUsageSnapshot
}

protocol SessionLogUsageSource: Sendable {
    func latestSnapshot() throws -> CodexUsageSnapshot?
}

protocol UsageSnapshotStoring: Sendable {
    func load() throws -> CodexUsageSnapshot?
    func save(_ snapshot: CodexUsageSnapshot) throws
}

protocol CodexExecutableLocating: Sendable {
    func findExecutableURL() throws -> URL
}

enum CodexUsageError: LocalizedError, Equatable {
    case codexExecutableNotFound
    case timedOut
    case invalidResponse(String)
    case processFailed(String)
    case cacheUnavailable

    var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            return "Codex CLI was not found."
        case .timedOut:
            return "Codex refresh timed out."
        case .invalidResponse(let message):
            return "Codex returned an invalid response: \(message)"
        case .processFailed(let message):
            return "Codex refresh failed: \(message)"
        case .cacheUnavailable:
            return "No cached snapshot is available."
        }
    }
}

enum Formatters {
    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }
}

@MainActor
enum UIFormatters {
    private static let usageReset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let usageUpdated: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    static func usageResetString(from date: Date) -> String {
        usageReset.string(from: date)
    }

    static func usageUpdatedString(from date: Date) -> String {
        usageUpdated.string(from: date)
    }
}
