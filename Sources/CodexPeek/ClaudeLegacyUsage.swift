import Foundation

struct LegacyTokenUsageStats: Codable, Equatable {
    let through: Date
    let summary: TokenUsageSummary
}

enum ClaudeLegacyUsage {
    static func backfill(_ report: TokenUsageReport, from statsURL: URL) -> TokenUsageReport {
        guard report.legacyStats == nil,
              let data = try? Data(contentsOf: statsURL),
              let stats = try? JSONDecoder().decode(Stats.self, from: data) else { return report }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let through = formatter.date(from: stats.lastComputedDate),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: through),
              end <= Date().addingTimeInterval(-30 * 86400),
              let buckets = report.history?.buckets,
              buckets.allSatisfy({ $0.startedAt >= end }) else { return report }

        // ponytail: aggregate stats lack cache TTL, speed and request context. Use standard 5m writes;
        // replace this approximation with detailed request logs when they become available.
        var summary = TokenUsageSummary.empty
        for (model, tokens) in stats.modelUsage {
            guard [tokens.inputTokens, tokens.outputTokens, tokens.cacheReadInputTokens, tokens.cacheCreationInputTokens]
                .allSatisfy({ $0 >= 0 }),
                  tokens.inputTokens <= Int.max - tokens.cacheReadInputTokens,
                  tokens.inputTokens + tokens.cacheReadInputTokens <= Int.max - tokens.cacheCreationInputTokens else { return report }
            let input = tokens.inputTokens + tokens.cacheReadInputTokens + tokens.cacheCreationInputTokens
            guard input <= Int.max - tokens.outputTokens,
                  input + tokens.outputTokens <= Int.max - summary.totalTokens else { return report }
            let usage = TokenUsagePayload(
                inputTokens: input,
                cachedInputTokens: tokens.cacheReadInputTokens,
                outputTokens: tokens.outputTokens,
                reasoningOutputTokens: 0,
                totalTokens: input + tokens.outputTokens,
                cacheCreationInputTokens: tokens.cacheCreationInputTokens
            )
            summary.inputTokens += usage.inputTokens
            summary.cachedInputTokens += usage.cachedInputTokens
            summary.outputTokens += usage.outputTokens
            summary.totalTokens += usage.totalTokens
            if let cost = TokenPricingCatalog.standard.estimateCost(for: model, usage: usage) {
                summary.estimatedCostUSD += cost.total
                summary.uncachedInputCostUSD += cost.uncachedInput
                summary.cachedInputCostUSD += cost.cachedInput
                summary.outputCostUSD += cost.output
            }
        }
        guard summary.hasUsage, summary.totalTokens <= Int.max - report.allTime.totalTokens else { return report }
        var result = report
        result.legacyStats = LegacyTokenUsageStats(through: through, summary: summary)
        result.allTime.inputTokens += summary.inputTokens
        result.allTime.cachedInputTokens += summary.cachedInputTokens
        result.allTime.outputTokens += summary.outputTokens
        result.allTime.totalTokens += summary.totalTokens
        result.allTime.estimatedCostUSD += summary.estimatedCostUSD
        result.allTime.uncachedInputCostUSD += summary.uncachedInputCostUSD
        result.allTime.cachedInputCostUSD += summary.cachedInputCostUSD
        result.allTime.outputCostUSD += summary.outputCostUSD
        return result
    }

    private struct Stats: Decodable {
        let lastComputedDate: String
        let modelUsage: [String: ModelUsage]
    }

    private struct ModelUsage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationInputTokens: Int
    }
}
