import Foundation

protocol TokenUsageSource: Sendable {
    func weeklySummary() throws -> TokenUsageSummary
}

final class CodexTokenUsageSource: TokenUsageSource, @unchecked Sendable {
    private let sessionsRootURL: URL
    private let fileManager: FileManager
    private let pricingCatalog: TokenPricingCatalog
    private let lookback: TimeInterval

    init(
        sessionsRootURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex/sessions").expandingTildeInPath),
        fileManager: FileManager = .default,
        pricingCatalog: TokenPricingCatalog = .standard,
        lookback: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.fileManager = fileManager
        self.pricingCatalog = pricingCatalog
        self.lookback = lookback
    }

    func weeklySummary() throws -> TokenUsageSummary {
        let cutoff = Date().addingTimeInterval(-lookback)
        let files = try sessionLogFiles(modifiedSince: cutoff)
        var summary = TokenUsageSummary.empty
        var totalsByModel: [String: Int] = [:]

        for fileURL in files {
            guard let session = try sessionUsage(from: fileURL) else {
                continue
            }

            summary.inputTokens += session.usage.inputTokens
            summary.cachedInputTokens += session.usage.cachedInputTokens
            summary.outputTokens += session.usage.outputTokens
            summary.reasoningOutputTokens += session.usage.reasoningOutputTokens
            summary.totalTokens += session.usage.totalTokens
            summary.sessionCount += 1

            if let model = session.model,
               let cost = pricingCatalog.estimateCost(for: model, usage: session.usage) {
                summary.estimatedCostUSD += cost
                summary.pricedSessionCount += 1
                totalsByModel[pricingCatalog.displayModelName(for: model), default: 0] += session.usage.totalTokens
            }
        }

        summary.topModel = totalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        return summary
    }

    private func sessionLogFiles(modifiedSince cutoff: Date) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modifiedAt = values?.contentModificationDate, modifiedAt >= cutoff else {
                continue
            }
            files.append(fileURL)
        }

        return files
    }

    private func sessionUsage(from fileURL: URL) throws -> SessionUsage? {
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        var model: String?
        var latestUsage: TokenUsagePayload?

        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = try? decoder.decode(TokenUsageLogEntry.self, from: Data(line.utf8)) else {
                continue
            }

            if entry.type == "turn_context", let contextModel = entry.payload?.model, !contextModel.isEmpty {
                model = contextModel
            }

            guard entry.type == "event_msg",
                  entry.payload?.type == "token_count",
                  let usage = entry.payload?.info?.totalTokenUsage else {
                continue
            }

            latestUsage = usage
        }

        guard let latestUsage else {
            return nil
        }

        return SessionUsage(model: model, usage: latestUsage)
    }
}

struct TokenPricingCatalog: Sendable {
    struct Price: Sendable {
        let inputPerMillion: Decimal
        let cachedInputPerMillion: Decimal
        let outputPerMillion: Decimal
        let displayName: String
    }

    static let standard = TokenPricingCatalog(prices: [
        "gpt-5.5": Price(inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30, displayName: "GPT-5.5"),
        "gpt-5.5-pro": Price(inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180, displayName: "GPT-5.5 Pro"),
        "gpt-5.4": Price(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15, displayName: "GPT-5.4"),
        "gpt-5.4-pro": Price(inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180, displayName: "GPT-5.4 Pro"),
        "gpt-5.4-mini": Price(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.5, displayName: "GPT-5.4 Mini"),
        "gpt-5.3-codex": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, displayName: "GPT-5.3 Codex"),
        "gpt-5.2": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, displayName: "GPT-5.2"),
        "gpt-5.2-codex": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, displayName: "GPT-5.2 Codex")
    ])

    private let prices: [String: Price]

    func estimateCost(for model: String, usage: TokenUsagePayload) -> Decimal? {
        guard let price = price(for: model) else {
            return nil
        }

        let cachedInput = max(0, usage.cachedInputTokens)
        let uncachedInput = max(0, usage.inputTokens - cachedInput)
        let inputCost = Decimal(uncachedInput) / 1_000_000 * price.inputPerMillion
        let cachedCost = Decimal(cachedInput) / 1_000_000 * price.cachedInputPerMillion
        let outputCost = Decimal(usage.outputTokens) / 1_000_000 * price.outputPerMillion
        return inputCost + cachedCost + outputCost
    }

    func displayModelName(for model: String) -> String {
        price(for: model)?.displayName ?? model
    }

    private func price(for model: String) -> Price? {
        let normalized = model.lowercased()
        if let exact = prices[normalized] {
            return exact
        }

        return prices.first { normalized.hasPrefix($0.key) }?.value
    }
}

private struct SessionUsage {
    let model: String?
    let usage: TokenUsagePayload
}

struct TokenUsagePayload: Decodable, Equatable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct TokenUsageLogEntry: Decodable {
    let type: String
    let payload: TokenUsageLogPayload?
}

private struct TokenUsageLogPayload: Decodable {
    let type: String?
    let model: String?
    let info: TokenUsageInfoPayload?
}

private struct TokenUsageInfoPayload: Decodable {
    let totalTokenUsage: TokenUsagePayload?

    private enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
    }
}
