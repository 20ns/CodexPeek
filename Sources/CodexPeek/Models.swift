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
    case prolite
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
    var renewsAt: Date? = nil

    static let empty = CodexAccountSnapshot(
        email: nil,
        authMode: .unknown,
        planType: .unknown,
        renewsAt: nil
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

struct SupplementalRateLimitSnapshot: Codable, Equatable {
    var limitID: String
    var title: String
    var primary: RateLimitWindowSnapshot?
    var secondary: RateLimitWindowSnapshot?

    var isWeeklyExhausted: Bool {
        secondary?.isExhausted == true
    }
}

struct CodexUsageSnapshot: Codable, Equatable {
    var account: CodexAccountSnapshot
    var primary: RateLimitWindowSnapshot?
    var secondary: RateLimitWindowSnapshot?
    var spark: SupplementalRateLimitSnapshot? = nil
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

struct TokenUsageSummary: Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int
    var estimatedCostUSD: Decimal
    var uncachedInputCostUSD: Decimal
    var cachedInputCostUSD: Decimal
    var outputCostUSD: Decimal
    var sessionCount: Int
    var pricedSessionCount: Int
    var topModel: String?

    static let empty = TokenUsageSummary(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0,
        estimatedCostUSD: 0,
        uncachedInputCostUSD: 0,
        cachedInputCostUSD: 0,
        outputCostUSD: 0,
        sessionCount: 0,
        pricedSessionCount: 0,
        topModel: nil
    )

    var hasUsage: Bool {
        totalTokens > 0
    }
}

struct TokenUsageReport: Equatable {
    var week: TokenUsageSummary
    var month: TokenUsageSummary
    var allTime: TokenUsageSummary

    static let empty = TokenUsageReport(
        week: .empty,
        month: .empty,
        allTime: .empty
    )

    var hasUsage: Bool {
        week.hasUsage || month.hasUsage || allTime.hasUsage
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
        if self == .prolite {
            return "Pro"
        }

        return rawValue.capitalized
    }
}

extension SnapshotSource {
    var displayName: String {
        switch self {
        case .live:
            return "Live data"
        case .sessionLog:
            return "Session log estimate"
        case .cache:
            return "Cached estimate"
        }
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
    var isSignedIn: Bool {
        authMode != .unknown || email != nil
    }

    func matchesIdentity(of other: CodexAccountSnapshot) -> Bool {
        isSignedIn
            && other.isSignedIn
            && authMode == other.authMode
            && email == other.email
            && planType == other.planType
    }

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
