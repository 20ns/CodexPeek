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
    private static let usageUpdated: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let accountRenewal: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    nonisolated static func usageResetCountdownString(from date: Date, now: Date = Date()) -> String {
        let secondsRemaining = max(0, Int(date.timeIntervalSince(now)))
        let minutesRemaining = max(0, secondsRemaining / 60)
        let days = minutesRemaining / (24 * 60)
        let hours = (minutesRemaining % (24 * 60)) / 60
        let minutes = minutesRemaining % 60

        if days > 0 {
            return "resets in \(days) \(days == 1 ? "day" : "days") \(hours) \(hours == 1 ? "hr" : "hrs")"
        }

        if hours > 0 {
            return "resets in \(hours) \(hours == 1 ? "hr" : "hrs") \(minutes) \(minutes == 1 ? "min" : "mins")"
        }

        if minutes > 0 {
            return "resets in \(minutes) \(minutes == 1 ? "min" : "mins")"
        }

        return "resets soon"
    }

    static func usageUpdatedString(from date: Date) -> String {
        usageUpdated.string(from: date)
    }

    static func accountRenewalString(from date: Date) -> String {
        accountRenewal.string(from: date)
    }

    nonisolated static func compactTokenString(_ value: Int) -> String {
        let absolute = Double(value)
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", absolute / 1_000_000)
        }

        if absolute >= 1_000 {
            return String(format: "%.1fk", absolute / 1_000)
        }

        return "\(value)"
    }

    nonisolated static func costString(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        if number.doubleValue >= 100 {
            return String(format: "$%.0f", number.doubleValue)
        }

        if number.doubleValue >= 10 {
            return String(format: "$%.1f", number.doubleValue)
        }

        return String(format: "$%.2f", number.doubleValue)
    }
}
