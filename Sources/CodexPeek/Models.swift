import Foundation

enum CodexAuthMode: String, Codable, Equatable {
    case apikey
    case chatgpt
    case chatgptAuthTokens
    case unknown
}

enum CodexPlanType: String, Codable, Equatable {
    case free
    case go
    case plus
    case pro
    case team
    case business
    case enterprise
    case edu
    case unknown
}

enum SnapshotSource: String, Codable, Equatable {
    case live
    case sessionLog
    case cache
}

enum RefreshState: Equatable {
    case idle
    case refreshing
    case failed(String)
}

struct CodexAccountSnapshot: Codable, Equatable {
    var email: String?
    var authMode: CodexAuthMode
    var planType: CodexPlanType

    static let empty = CodexAccountSnapshot(
        email: nil,
        authMode: .unknown,
        planType: .unknown
    )
}

struct RateLimitWindowSnapshot: Codable, Equatable {
    var usedPercent: Int
    var windowDurationMins: Int?
    var resetsAt: Date?

    var isExhausted: Bool {
        usedPercent >= 100
    }
}

struct CodexUsageSnapshot: Codable, Equatable {
    var account: CodexAccountSnapshot
    var primary: RateLimitWindowSnapshot?
    var secondary: RateLimitWindowSnapshot?
    var source: SnapshotSource
    var lastUpdatedAt: Date
    var isStale: Bool

    func withSource(_ source: SnapshotSource, stale: Bool) -> CodexUsageSnapshot {
        var copy = self
        copy.source = source
        copy.isStale = stale
        return copy
    }
}

enum UsageLevel: Equatable {
    case normal
    case warning
    case critical
    case unavailable
}

enum UsageLevelResolver {
    static func resolve(for usedPercent: Int?) -> UsageLevel {
        guard let usedPercent else {
            return .unavailable
        }

        switch usedPercent {
        case ..<70:
            return .normal
        case 70..<90:
            return .warning
        default:
            return .critical
        }
    }
}

extension CodexPlanType {
    var displayName: String {
        rawValue.capitalized
    }
}

extension CodexUsageSnapshot {
    var displayAccountName: String {
        account.displayName
    }

    var isWeeklyExhausted: Bool {
        secondary?.isExhausted == true
    }
}

extension CodexAccountSnapshot {
    var displayName: String {
        if let email, !email.isEmpty {
            return email
        }

        switch authMode {
        case .apikey:
            return "API key account"
        case .chatgpt, .chatgptAuthTokens:
            return "Signed in"
        case .unknown:
            return "Not signed in"
        }
    }
}
