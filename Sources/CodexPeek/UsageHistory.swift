import Foundation

struct TokenUsageHistory: Codable, Equatable {
    var buckets: [TokenUsageBucket]
}

struct TokenUsageBucket: Codable, Equatable {
    var startedAt: Date
    var model: String
    var serviceTier: String? = nil
    var usesChatGPTCredits: Bool? = nil
    var usage: TokenUsagePayload
}

struct PlanUsageSample: Codable, Equatable {
    var recordedAt: Date
    var primaryPercent: Int?
    var secondaryPercent: Int?
    var primaryResetsAt: Date?
    var secondaryResetsAt: Date?
}

struct PlanUsageHistory: Codable, Equatable {
    var samples: [PlanUsageSample] = []
}

final class PlanUsageHistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> PlanUsageHistory {
        guard let data = try? Data(contentsOf: fileURL),
              let history = try? decoder.decode(PlanUsageHistory.self, from: data) else {
            return PlanUsageHistory()
        }
        return history
    }

    @discardableResult
    func record(_ snapshot: CodexUsageSnapshot, at date: Date = Date()) -> PlanUsageHistory {
        var history = load()
        let sample = PlanUsageSample(
            recordedAt: date,
            primaryPercent: snapshot.primary?.usedPercent,
            secondaryPercent: snapshot.secondary?.usedPercent,
            primaryResetsAt: snapshot.primary?.resetsAt,
            secondaryResetsAt: snapshot.secondary?.resetsAt
        )

        if let last = history.samples.last,
           last.primaryPercent == sample.primaryPercent,
           last.secondaryPercent == sample.secondaryPercent,
           last.primaryResetsAt == sample.primaryResetsAt,
           last.secondaryResetsAt == sample.secondaryResetsAt,
           date.timeIntervalSince(last.recordedAt) < 60 * 60 {
            return history
        }

        let cutoff = date.addingTimeInterval(-180 * 24 * 60 * 60)
        history.samples = history.samples.filter { $0.recordedAt >= cutoff }
        history.samples.append(sample)
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(history) {
            try? data.write(to: fileURL, options: .atomic)
        }
        return history
    }

    static func defaultURL(profileID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexPeek", isDirectory: true)
            .appendingPathComponent("UsageHistory", isDirectory: true)
            .appendingPathComponent("\(profileID).json")
    }
}

struct DailyTokenUsage {
    let day: Date
    var byModel: [String: TokenUsagePayload]
    var costByModel: [String: Decimal]
    var unpricedModels: Set<String>
    var cacheSavings: Decimal
    var priorityTokensByModel: [String: Int]
    var fastTokensByModel: [String: Int]

    var totalTokens: Int {
        byModel.values.reduce(0) { $0 + $1.totalTokens }
    }
}

struct UsagePeriodStats {
    var usage = TokenUsagePayload.zero
    var activeDays = 0
    var modelTokens: [String: Int] = [:]

    var activeDayAverage: Double? {
        activeDays > 0 ? Double(usage.totalTokens) / Double(activeDays) : nil
    }

    var contextLeverage: Double? {
        guard usage.inputTokens > 0 else { return nil }
        let uncached = usage.inputTokens - usage.cachedInputTokens
        return uncached > 0 ? Double(usage.inputTokens) / Double(uncached) : .infinity
    }
}

struct UsagePeriodComparison {
    let current: UsagePeriodStats
    let previous: UsagePeriodStats
    let hasCompleteBaseline: Bool

    var tokenChangePercent: Int? {
        guard hasCompleteBaseline else { return nil }
        return Self.percentChange(current.usage.totalTokens, from: previous.usage.totalTokens)
    }

    var activeDayChangePercent: Int? {
        guard hasCompleteBaseline else { return nil }
        guard let current = current.activeDayAverage, let previous = previous.activeDayAverage else { return nil }
        return Self.percentChange(current, from: previous)
    }

    private static func percentChange<T: BinaryInteger>(_ current: T, from previous: T) -> Int? {
        percentChange(Double(current), from: Double(previous))
    }

    private static func percentChange(_ current: Double, from previous: Double) -> Int? {
        guard previous > 0 else { return nil }
        return Int((((current / previous) - 1) * 100).rounded())
    }
}

struct AllowanceYieldSample {
    let resetAt: Date
    let tokensPerPoint: Double
    let observedPoints: Int
}

struct AllowanceYieldComparison {
    let current: AllowanceYieldSample?
    let previous: AllowanceYieldSample?

    var changePercent: Int? {
        guard let current, let previous, previous.tokensPerPoint > 0 else { return nil }
        return Int((((current.tokensPerPoint / previous.tokensPerPoint) - 1) * 100).rounded())
    }
}

struct PlanPace {
    let multiplier: Double
    let projectedPercent: Int
}

enum UsageHistoryAnalytics {
    static func usage(
        from buckets: [TokenUsageBucket],
        since start: Date,
        before end: Date
    ) -> TokenUsagePayload {
        var usage = TokenUsagePayload.zero
        for bucket in buckets where bucket.startedAt >= start && bucket.startedAt < end {
            usage.add(bucket.usage)
        }
        return usage
    }

    static func dailyUsage(
        from buckets: [TokenUsageBucket],
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DailyTokenUsage] {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
        var totals: [Date: [String: TokenUsagePayload]] = [:]
        var costs: [Date: [String: Decimal]] = [:]
        var unpriced: [Date: Set<String>] = [:]
        var savings: [Date: Decimal] = [:]
        var priorityTokens: [Date: [String: Int]] = [:]
        var fastTokens: [Date: [String: Int]] = [:]

        for bucket in buckets where bucket.startedAt >= firstDay && bucket.startedAt <= now {
            let day = calendar.startOfDay(for: bucket.startedAt)
            totals[day, default: [:]][bucket.model, default: .zero].add(bucket.usage)
            if let cost = TokenPricingCatalog.standard.estimateCost(
                for: bucket.model,
                usage: bucket.usage,
                serviceTier: bucket.serviceTier
            ) {
                costs[day, default: [:]][bucket.model, default: 0] += cost.total
            } else {
                unpriced[day, default: []].insert(bucket.model)
            }
            savings[day, default: 0] += TokenPricingCatalog.standard.estimateCacheSavings(
                for: bucket.model,
                usage: bucket.usage,
                serviceTier: bucket.serviceTier
            ) ?? 0
            if bucket.serviceTier?.lowercased() == "priority" {
                priorityTokens[day, default: [:]][bucket.model, default: 0] += bucket.usage.totalTokens
                if bucket.usesChatGPTCredits == true {
                    fastTokens[day, default: [:]][bucket.model, default: 0] += bucket.usage.totalTokens
                }
            }
        }

        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(
                day: day,
                byModel: totals[day] ?? [:],
                costByModel: costs[day] ?? [:],
                unpricedModels: unpriced[day] ?? [],
                cacheSavings: savings[day] ?? 0,
                priorityTokensByModel: priorityTokens[day] ?? [:],
                fastTokensByModel: fastTokens[day] ?? [:]
            )
        }
    }

    static func todayComparison(
        from buckets: [TokenUsageBucket],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (today: Int, yesterday: Int) {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let yesterdayCutoff = calendar.date(byAdding: .day, value: -1, to: now) else {
            return (0, 0)
        }

        var result = (today: 0, yesterday: 0)
        for bucket in buckets {
            if bucket.startedAt >= today && bucket.startedAt <= now {
                result.today += bucket.usage.totalTokens
            } else if bucket.startedAt >= yesterday && bucket.startedAt <= yesterdayCutoff {
                result.yesterday += bucket.usage.totalTokens
            }
        }
        return result
    }

    static func calendarComparison(
        from buckets: [TokenUsageBucket],
        component: Calendar.Component,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsagePeriodComparison? {
        guard let currentInterval = calendar.dateInterval(of: component, for: now),
              let previousProbe = calendar.date(byAdding: .second, value: -1, to: currentInterval.start),
              let previousInterval = calendar.dateInterval(of: component, for: previousProbe) else {
            return nil
        }
        let elapsed = now.timeIntervalSince(currentInterval.start)
        let previousEnd = min(previousInterval.end, previousInterval.start.addingTimeInterval(elapsed))
        return UsagePeriodComparison(
            current: periodStats(from: buckets, since: currentInterval.start, before: now, calendar: calendar),
            previous: periodStats(from: buckets, since: previousInterval.start, before: previousEnd, calendar: calendar),
            hasCompleteBaseline: buckets.map(\.startedAt).min().map { $0 <= previousInterval.start } == true
        )
    }

    static func rollingComparison(
        from buckets: [TokenUsageBucket],
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsagePeriodComparison {
        let currentStart = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let previousStart = calendar.date(byAdding: .day, value: -days, to: currentStart) ?? currentStart
        return UsagePeriodComparison(
            current: periodStats(from: buckets, since: currentStart, before: now, calendar: calendar),
            previous: periodStats(from: buckets, since: previousStart, before: currentStart, calendar: calendar),
            hasCompleteBaseline: buckets.map(\.startedAt).min().map { $0 <= previousStart } == true
        )
    }

    static func allowanceYield(
        from buckets: [TokenUsageBucket],
        history: PlanUsageHistory
    ) -> AllowanceYieldComparison {
        let samples = Dictionary(grouping: history.samples.compactMap { sample -> (Date, PlanUsageSample)? in
            guard let reset = sample.secondaryResetsAt, sample.secondaryPercent != nil else { return nil }
            return (reset, sample)
        }, by: \.0)
        .compactMap { reset, pairs -> AllowanceYieldSample? in
            let ordered = pairs.map(\.1).sorted { $0.recordedAt < $1.recordedAt }
            guard let first = ordered.first, let last = ordered.last,
                  let firstPercent = first.secondaryPercent, let lastPercent = last.secondaryPercent else {
                return nil
            }
            let points = lastPercent - firstPercent
            guard points >= 2 else { return nil }
            let tokens = buckets.lazy
                .filter {
                    $0.startedAt >= first.recordedAt &&
                    $0.startedAt <= last.recordedAt &&
                    $0.usesChatGPTCredits != false
                }
                .reduce(0) { $0 + $1.usage.totalTokens }
            guard tokens > 0 else { return nil }
            return AllowanceYieldSample(
                resetAt: reset,
                tokensPerPoint: Double(tokens) / Double(points),
                observedPoints: points
            )
        }
        .sorted { $0.resetAt > $1.resetAt }
        return AllowanceYieldComparison(current: samples.first, previous: samples.dropFirst().first)
    }

    static func planPace(snapshot: CodexUsageSnapshot?, now: Date = Date()) -> PlanPace? {
        guard snapshot?.isStale == false,
              let window = snapshot?.secondary,
              let durationMinutes = window.windowDurationMins,
              durationMinutes > 0,
              let resetsAt = window.resetsAt else {
            return nil
        }
        let duration = TimeInterval(durationMinutes * 60)
        let elapsed = min(max(now.timeIntervalSince(resetsAt.addingTimeInterval(-duration)) / duration, 0), 1)
        guard elapsed > 0 else { return nil }
        return PlanPace(
            multiplier: Double(window.usedPercent) / (elapsed * 100),
            projectedPercent: Int((Double(window.usedPercent) / elapsed).rounded())
        )
    }

    static func modelTotals(from days: [DailyTokenUsage]) -> [(model: String, usage: TokenUsagePayload, cost: Decimal?)] {
        var totals: [String: TokenUsagePayload] = [:]
        var costs: [String: Decimal] = [:]
        var unpriced = Set<String>()
        for day in days {
            for (model, usage) in day.byModel {
                totals[model, default: .zero].add(usage)
            }
            for (model, cost) in day.costByModel {
                costs[model, default: 0] += cost
            }
            unpriced.formUnion(day.unpricedModels)
        }
        return totals.map { model, usage in
            (model, usage, unpriced.contains(model) ? nil : costs[model])
        }.sorted { $0.usage.totalTokens > $1.usage.totalTokens }
    }

    private static func periodStats(
        from buckets: [TokenUsageBucket],
        since start: Date,
        before end: Date,
        calendar: Calendar
    ) -> UsagePeriodStats {
        var result = UsagePeriodStats()
        var days = Set<Date>()
        for bucket in buckets where bucket.startedAt >= start && bucket.startedAt < end {
            result.usage.add(bucket.usage)
            result.modelTokens[bucket.model, default: 0] += bucket.usage.totalTokens
            days.insert(calendar.startOfDay(for: bucket.startedAt))
        }
        result.activeDays = days.count
        return result
    }

    static func weeklyPointsToday(
        from history: PlanUsageHistory,
        current: CodexUsageSnapshot?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int? {
        guard let latest = current?.secondary,
              let first = history.samples.first(where: {
                  calendar.isDate($0.recordedAt, inSameDayAs: now) &&
                  $0.secondaryResetsAt == latest.resetsAt &&
                  $0.secondaryPercent != nil
              }),
              let percent = first.secondaryPercent else {
            return nil
        }
        return max(0, latest.usedPercent - percent)
    }
}
