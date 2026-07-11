import Foundation

struct TokenUsageHistory: Codable, Equatable {
    var buckets: [TokenUsageBucket]
}

struct TokenUsageBucket: Codable, Equatable {
    var startedAt: Date
    var model: String
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

    var totalTokens: Int {
        byModel.values.reduce(0) { $0 + $1.totalTokens }
    }
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

        for bucket in buckets where bucket.startedAt >= firstDay && bucket.startedAt <= now {
            let day = calendar.startOfDay(for: bucket.startedAt)
            totals[day, default: [:]][bucket.model, default: .zero].add(bucket.usage)
        }

        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, byModel: totals[day] ?? [:])
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

    static func modelTotals(from days: [DailyTokenUsage]) -> [(model: String, usage: TokenUsagePayload)] {
        var totals: [String: TokenUsagePayload] = [:]
        for day in days {
            for (model, usage) in day.byModel {
                totals[model, default: .zero].add(usage)
            }
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.usage.totalTokens > $1.usage.totalTokens }
    }

    static func hourlyActivity(
        from buckets: [TokenUsageBucket],
        days: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [[Int]] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        var values = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for bucket in buckets where bucket.startedAt >= cutoff && bucket.startedAt <= now {
            let weekday = calendar.component(.weekday, from: bucket.startedAt) - 1
            let hour = calendar.component(.hour, from: bucket.startedAt)
            values[weekday][hour] += bucket.usage.totalTokens
        }
        return values
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
