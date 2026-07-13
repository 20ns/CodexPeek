import Foundation

protocol TokenUsageSource: Sendable {
    func usageReport() throws -> TokenUsageReport
}

protocol TokenUsageReportStoring: Sendable {
    func load() throws -> TokenUsageReport?
    func save(_ report: TokenUsageReport) throws
}

protocol TokenUsageSessionIndexStoring: Sendable {
    func load() throws -> TokenUsageSessionIndex?
    func save(_ index: TokenUsageSessionIndex) throws
}

final class CodexTokenUsageSource: TokenUsageSource, @unchecked Sendable {
    private let sessionsRootURL: URL
    private let fileManager: FileManager
    private let pricingCatalog: TokenPricingCatalog
    private let indexStore: TokenUsageSessionIndexStoring?

    init(
        sessionsRootURL: URL = URL(fileURLWithPath: NSString(string: "~/.codex/sessions").expandingTildeInPath),
        fileManager: FileManager = .default,
        pricingCatalog: TokenPricingCatalog = .standard,
        indexStore: TokenUsageSessionIndexStoring? = nil
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.fileManager = fileManager
        self.pricingCatalog = pricingCatalog
        self.indexStore = indexStore
    }

    func usageReport() throws -> TokenUsageReport {
        let now = Date()
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthCutoff = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? weekCutoff
        let files = try sessionLogFiles()
        var index = (try? indexStore?.load()) ?? TokenUsageSessionIndex()
        let currentPaths = Set(files.map(\.path))
        index.sessions = index.sessions.filter { currentPaths.contains($0.key) }
        var report = TokenUsageReport.empty
        var weeklyTotalsByModel: [String: Int] = [:]
        var monthlyTotalsByModel: [String: Int] = [:]
        var allTimeTotalsByModel: [String: Int] = [:]
        var allBuckets: [TokenUsageBucket] = []

        for file in files {
            let session: SessionUsage?
            if let cached = index.sessions[file.path], cached.matches(file) {
                session = cached.session
            } else {
                session = try autoreleasepool(invoking: {
                    try sessionUsage(from: file.url)
                })
                index.sessions[file.path] = IndexedSessionUsage(file: file, session: session)
            }

            guard let session else {
                continue
            }

            allBuckets.append(contentsOf: session.buckets)
            add(session.buckets, since: nil, to: &report.allTime, totalsByModel: &allTimeTotalsByModel)
            add(session.buckets, since: monthCutoff, to: &report.month, totalsByModel: &monthlyTotalsByModel)
            add(session.buckets, since: weekCutoff, to: &report.week, totalsByModel: &weeklyTotalsByModel)
        }

        report.week.topModel = weeklyTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.month.topModel = monthlyTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.allTime.topModel = allTimeTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.generatedAt = now
        report.history = TokenUsageHistory(buckets: allBuckets.sorted { $0.startedAt < $1.startedAt })
        try? indexStore?.save(index)
        return report
    }

    private func sessionLogFiles() throws -> [SessionLogFile] {
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [SessionLogFile] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            files.append(SessionLogFile(
                url: fileURL,
                path: fileURL.path,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? Date.distantPast
            ))
        }

        return files
    }

    private func add(
        _ buckets: [TokenUsageBucket],
        since cutoff: Date?,
        to summary: inout TokenUsageSummary,
        totalsByModel: inout [String: Int]
    ) {
        let selected = buckets.filter { cutoff == nil || $0.startedAt >= cutoff! }
        guard !selected.isEmpty else { return }
        var priced = false

        for bucket in selected {
            summary.inputTokens += bucket.usage.inputTokens
            summary.cachedInputTokens += bucket.usage.cachedInputTokens
            summary.outputTokens += bucket.usage.outputTokens
            summary.reasoningOutputTokens += bucket.usage.reasoningOutputTokens
            summary.totalTokens += bucket.usage.totalTokens
            totalsByModel[pricingCatalog.displayModelName(for: bucket.model), default: 0] += bucket.usage.totalTokens

            guard let cost = pricingCatalog.estimateCost(for: bucket.model, usage: bucket.usage) else { continue }
            summary.estimatedCostUSD += cost.total
            summary.uncachedInputCostUSD += cost.uncachedInput
            summary.cachedInputCostUSD += cost.cachedInput
            summary.outputCostUSD += cost.output
            priced = true
        }
        summary.sessionCount += 1
        summary.pricedSessionCount += priced ? 1 : 0
    }

    private func sessionUsage(from fileURL: URL) throws -> SessionUsage? {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        let markers = ["\"session_meta\"", "\"turn_context\"", "\"token_count\"", "\"inter_agent_communication_metadata\""]
            .map { Data($0.utf8) }
        let fallbackTimestamp = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        var buckets: [TokenUsageBucket] = []
        var previousUsage = TokenUsagePayload.zero
        var seenTotals = Set<TokenUsagePayload>()
        var model = "Unknown model"
        var sawSessionMetadata = false
        var includeUsage = true
        var lineStart = data.startIndex

        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 10) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            defer {
                lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            }
            guard markers.contains(where: { line.range(of: $0) != nil }),
                  let entry = try? decoder.decode(TokenUsageLogEntry.self, from: line) else { continue }

            if entry.type == "session_meta", !sawSessionMetadata {
                sawSessionMetadata = true
                includeUsage = entry.payload?.multiAgentVersion != "v2" || entry.payload?.threadSource != "subagent"
            } else if entry.type == "inter_agent_communication_metadata" {
                includeUsage = true
            } else if entry.type == "turn_context", let nextModel = entry.payload?.model, !nextModel.isEmpty {
                model = nextModel
            } else if entry.type == "event_msg",
                      entry.payload?.type == "token_count",
                      let info = entry.payload?.info,
                      let usage = info.totalTokenUsage,
                      usage.isConsistent,
                      seenTotals.insert(usage).inserted {
                let delta = usage.delta(since: previousUsage)
                if delta != nil { previousUsage = usage }
                guard includeUsage,
                      let incrementalUsage = info.lastTokenUsage?.isConsistent == true ? info.lastTokenUsage : delta,
                      incrementalUsage.totalTokens > 0 else { continue }

                let timestamp = entry.timestamp.flatMap(Formatters.parseISO8601) ?? fallbackTimestamp
                let interval = Date(timeIntervalSince1970: floor(timestamp.timeIntervalSince1970 / 900) * 900)
                if let last = buckets.indices.last,
                   buckets[last].startedAt == interval,
                   buckets[last].model == model {
                    buckets[last].usage.add(incrementalUsage)
                } else {
                    buckets.append(TokenUsageBucket(startedAt: interval, model: model, usage: incrementalUsage))
                }
            }
        }

        return buckets.isEmpty ? nil : SessionUsage(buckets: buckets)
    }
}

final class TokenUsageSessionIndexStore: TokenUsageSessionIndexStoring, @unchecked Sendable {
    private let cacheURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        cacheURL: URL = TokenUsageSessionIndexStore.defaultCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> TokenUsageSessionIndex? {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: cacheURL)
        if let index = try? decoder.decode(TokenUsageSessionIndex.self, from: data),
           index.schemaVersion == TokenUsageSessionIndex.schemaVersion {
            return index
        }
        guard let legacy = try? decoder.decode(LegacyTokenUsageSessionIndex.self, from: data),
              legacy.schemaVersion == 1 else { return nil }
        return TokenUsageSessionIndex(sessions: legacy.sessions.mapValues { item in
            let bucket = item.session.map {
                TokenUsageBucket(startedAt: $0.updatedAt, model: $0.model ?? "Unknown model", usage: $0.usage)
            }
            return IndexedSessionUsage(
                path: item.path,
                size: item.size,
                modifiedAt: item.modifiedAt,
                session: bucket.map { SessionUsage(buckets: [$0]) }
            )
        })
    }

    func save(_ index: TokenUsageSessionIndex) throws {
        try fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(index)
        try data.write(to: cacheURL, options: .atomic)
    }

    static func defaultCacheURL(profileID: String = "default") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("CodexPeek", isDirectory: true)
            .appendingPathComponent("TokenSessionIndexes", isDirectory: true)
            .appendingPathComponent("\(profileID).json")
    }
}

final class TokenUsageReportCacheStore: TokenUsageReportStoring, @unchecked Sendable {
    private let cacheURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        cacheURL: URL = TokenUsageReportCacheStore.defaultCacheURL(),
        fileManager: FileManager = .default
    ) {
        self.cacheURL = cacheURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() throws -> TokenUsageReport? {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: cacheURL)
        return try decoder.decode(TokenUsageReport.self, from: data)
    }

    func save(_ report: TokenUsageReport) throws {
        try fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(report)
        try data.write(to: cacheURL, options: .atomic)
    }

    static func defaultCacheURL(profileID: String = "default") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("CodexPeek", isDirectory: true)
            .appendingPathComponent("TokenReports", isDirectory: true)
            .appendingPathComponent("\(profileID).json")
    }
}

struct TokenPricingCatalog: Sendable {
    struct Price: Sendable {
        let inputPerMillion: Decimal
        let cachedInputPerMillion: Decimal
        let outputPerMillion: Decimal
        let displayName: String
    }

    struct Cost: Sendable {
        let uncachedInput: Decimal
        let cachedInput: Decimal
        let output: Decimal

        var total: Decimal {
            uncachedInput + cachedInput + output
        }
    }

    static let standard = TokenPricingCatalog(prices: [
        "gpt-5.6-sol": Price(inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30, displayName: "GPT-5.6 Sol"),
        "gpt-5.6-terra": Price(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15, displayName: "GPT-5.6 Terra"),
        "gpt-5.6-luna": Price(inputPerMillion: 1, cachedInputPerMillion: 0.1, outputPerMillion: 6, displayName: "GPT-5.6 Luna"),
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

    func estimateCost(for model: String, usage: TokenUsagePayload) -> Cost? {
        guard let price = price(for: model) else {
            return nil
        }

        let cachedInput = max(0, usage.cachedInputTokens)
        let uncachedInput = max(0, usage.inputTokens - cachedInput)
        let inputCost = Decimal(uncachedInput) / 1_000_000 * price.inputPerMillion
        let cachedCost = Decimal(cachedInput) / 1_000_000 * price.cachedInputPerMillion
        let outputCost = Decimal(usage.outputTokens) / 1_000_000 * price.outputPerMillion
        return Cost(
            uncachedInput: inputCost,
            cachedInput: cachedCost,
            output: outputCost
        )
    }

    func displayModelName(for model: String) -> String {
        price(for: model)?.displayName ?? model
    }

    private func price(for model: String) -> Price? {
        let normalized = model.lowercased()
        if let exact = prices[normalized] {
            return exact
        }

        return prices
            .sorted { lhs, rhs in lhs.key.count > rhs.key.count }
            .first { normalized.hasPrefix($0.key) }?.value
    }
}

struct SessionLogFile {
    let url: URL
    let path: String
    let size: Int
    let modifiedAt: Date
}

struct TokenUsageSessionIndex: Codable {
    static let schemaVersion = 4

    var schemaVersion = TokenUsageSessionIndex.schemaVersion
    var sessions: [String: IndexedSessionUsage] = [:]
}

struct IndexedSessionUsage: Codable {
    let path: String
    let size: Int
    let modifiedAt: Date
    let session: SessionUsage?

    init(file: SessionLogFile, session: SessionUsage?) {
        self.path = file.path
        self.size = file.size
        self.modifiedAt = file.modifiedAt
        self.session = session
    }

    init(path: String, size: Int, modifiedAt: Date, session: SessionUsage?) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.session = session
    }

    func matches(_ file: SessionLogFile) -> Bool {
        path == file.path && size == file.size && modifiedAt == file.modifiedAt
    }
}

private struct LegacyTokenUsageSessionIndex: Decodable {
    let schemaVersion: Int
    let sessions: [String: LegacyIndexedSessionUsage]
}

private struct LegacyIndexedSessionUsage: Decodable {
    let path: String
    let size: Int
    let modifiedAt: Date
    let session: LegacySessionUsage?
}

private struct LegacySessionUsage: Decodable {
    let model: String?
    let usage: TokenUsagePayload
    let updatedAt: Date
}

struct SessionUsage: Codable {
    let buckets: [TokenUsageBucket]
}

struct TokenUsagePayload: Codable, Hashable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int

    static let zero = TokenUsagePayload(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )

    mutating func add(_ other: TokenUsagePayload) {
        self = TokenUsagePayload(
            inputTokens: inputTokens + other.inputTokens,
            cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
            outputTokens: outputTokens + other.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens + other.reasoningOutputTokens,
            totalTokens: totalTokens + other.totalTokens
        )
    }

    var isConsistent: Bool {
        inputTokens >= 0 && cachedInputTokens >= 0 && outputTokens >= 0 && reasoningOutputTokens >= 0
            && totalTokens == inputTokens + outputTokens
    }

    func delta(since previous: TokenUsagePayload) -> TokenUsagePayload? {
        let delta = TokenUsagePayload(
            inputTokens: inputTokens - previous.inputTokens,
            cachedInputTokens: cachedInputTokens - previous.cachedInputTokens,
            outputTokens: outputTokens - previous.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: totalTokens - previous.totalTokens
        )
        return [delta.inputTokens, delta.cachedInputTokens, delta.outputTokens, delta.reasoningOutputTokens, delta.totalTokens]
            .contains(where: { $0 < 0 }) ? nil : delta
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct TokenUsageLogEntry: Decodable {
    let timestamp: String?
    let type: String
    let payload: TokenUsageLogPayload?
}

private struct TokenUsageLogPayload: Decodable {
    let type: String?
    let model: String?
    let info: TokenUsageInfoPayload?

    let multiAgentVersion: String?
    let threadSource: String?

    private enum CodingKeys: String, CodingKey {
        case type, model, info
        case multiAgentVersion = "multi_agent_version"
        case threadSource = "thread_source"
    }
}

private struct TokenUsageInfoPayload: Decodable {
    let totalTokenUsage: TokenUsagePayload?
    let lastTokenUsage: TokenUsagePayload?

    private enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
    }
}
