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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self = CodexPlanType(rawValue: value) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
    var accountID: String? = nil
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

    var isWeekly: Bool {
        (windowDurationMins ?? 0) >= 10080
    }

    var isSession: Bool {
        guard let windowDurationMins else { return false }
        return windowDurationMins < 1440
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

struct TokenUsageSummary: Codable, Equatable {
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

struct TokenUsageReport: Codable, Equatable {
    var week: TokenUsageSummary
    var month: TokenUsageSummary
    var allTime: TokenUsageSummary
    var generatedAt: Date?
    var history: TokenUsageHistory? = nil
    var legacyStats: LegacyTokenUsageStats? = nil
    var historyIncludesAllRetainedSessions: Bool? = nil

    static let empty = TokenUsageReport(
        week: .empty,
        month: .empty,
        allTime: .empty,
        generatedAt: nil,
        history: nil
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

    /// ChatGPT list price used for seat-value ROI. Nil when no public seat price applies.
    var listPriceUSD: Decimal? {
        switch self {
        case .go:
            return 8
        case .plus:
            return 20
        case .prolite:
            return 100
        case .pro:
            return 200
        case .business:
            return 25
        case .free, .team, .enterprise, .edu, .unknown:
            return nil
        }
    }

    /// Seat label for value copy (distinguishes Pro 5× vs Pro 20×).
    var seatLabel: String {
        switch self {
        case .prolite:
            return "Pro 5×"
        case .pro:
            return "Pro 20×"
        default:
            return displayName
        }
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

    /// The 7-day allowance window (secondary if present, otherwise primary when weekly).
    var weeklyWindow: RateLimitWindowSnapshot? {
        if let secondary {
            return secondary
        }
        if let primary, primary.isWeekly {
            return primary
        }
        return nil
    }

    /// The short session window (e.g. 5-hour), present only if distinct from the weekly window.
    var sessionWindow: RateLimitWindowSnapshot? {
        if secondary != nil {
            return primary
        }
        if let primary, !primary.isWeekly {
            return primary
        }
        return nil
    }

    var isWeeklyExhausted: Bool {
        weeklyWindow?.isExhausted == true
    }
}

extension CodexAccountSnapshot {
    var isSignedIn: Bool {
        authMode != .unknown || email != nil
    }

    func matchesIdentity(of other: CodexAccountSnapshot) -> Bool {
        guard isSignedIn, other.isSignedIn, authMode == other.authMode else {
            return false
        }

        if let accountID, let otherAccountID = other.accountID, !accountID.isEmpty, !otherAccountID.isEmpty {
            return accountID == otherAccountID
        }

        guard authMode != .apikey,
              let email,
              let otherEmail = other.email,
              !email.isEmpty,
              !otherEmail.isEmpty else {
            return false
        }

        return email == otherEmail
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
