import Foundation
import os

/// Daily model prices from LiteLLM's public price list, so new models and price changes land without a release.
/// The built-in table stays the fallback: a failed fetch or bad file never removes a price.
enum PriceFeed {
    /// Dollars per million tokens.
    struct Rates: Codable, Equatable, Sendable {
        let input: Decimal
        let cachedInput: Decimal
        let output: Decimal
    }

    private struct Snapshot: Codable {
        let fetchedAt: Date
        let rates: [String: Rates]
    }

    private static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let maxAge: TimeInterval = 24 * 60 * 60
    private static let cacheURL = AccountProfileStore.baseSupportURL().appendingPathComponent("model-prices.json")

    private static let state: OSAllocatedUnfairLock<(catalog: TokenPricingCatalog, fetchedAt: Date?)> = {
        let saved = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        return OSAllocatedUnfairLock(initialState: (TokenPricingCatalog.builtIn.overlaid(saved?.rates ?? [:]), saved?.fetchedAt))
    }()

    static var current: TokenPricingCatalog { state.withLock { $0.catalog } }

    /// Fetches at most once per `maxAge`; keeps the last good prices on any failure.
    static func refreshIfStale(now: Date = Date()) async {
        if let fetchedAt = state.withLock({ $0.fetchedAt }), (0..<maxAge).contains(now.timeIntervalSince(fetchedAt)) { return }
        var request = URLRequest(url: sourceURL, timeoutInterval: 30)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rates = parse(data), !rates.isEmpty else { return }
        let catalog = TokenPricingCatalog.builtIn.overlaid(rates)
        state.withLock { $0 = (catalog, now) }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Snapshot(fetchedAt: now, rates: rates)).write(to: cacheURL, options: .atomic)
    }

    /// Keeps first-party Anthropic and OpenAI chat models with sane per-token prices.
    static func parse(_ data: Data) -> [String: Rates]? {
        guard let models = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var rates: [String: Rates] = [:]
        for (id, value) in models {
            guard let entry = value as? [String: Any],
                  ["anthropic", "openai"].contains(entry["litellm_provider"] as? String),
                  ["chat", "responses"].contains(entry["mode"] as? String),
                  id.hasPrefix("claude-") || id.hasPrefix("gpt-"),
                  let input = perMillion(entry["input_cost_per_token"]),
                  let output = perMillion(entry["output_cost_per_token"]) else { continue }
            let cached = perMillion(entry["cache_read_input_token_cost"]) ?? input // no cache price: no cache discount (e.g. Pro models)
            guard input > 0, output > 0, cached >= 0, cached <= input, input <= 1_000, output <= 1_000 else { continue }
            rates[id.lowercased()] = Rates(input: input, cachedInput: cached, output: output)
        }
        return rates
    }

    /// Goes through the shortest decimal string so 8e-06 becomes exactly 8, not 7.999….
    private static func perMillion(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber, let decimal = Decimal(string: "\(number.doubleValue)") else { return nil }
        return decimal * 1_000_000
    }
}
