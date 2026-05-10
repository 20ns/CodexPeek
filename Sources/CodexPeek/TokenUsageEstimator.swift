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

            add(session, to: &report.allTime, totalsByModel: &allTimeTotalsByModel)

            if session.updatedAt >= monthCutoff {
                add(session, to: &report.month, totalsByModel: &monthlyTotalsByModel)
            }

            if session.updatedAt >= weekCutoff {
                add(session, to: &report.week, totalsByModel: &weeklyTotalsByModel)
            }
        }

        report.week.topModel = weeklyTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.month.topModel = monthlyTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.allTime.topModel = allTimeTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.generatedAt = now
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
        _ session: SessionUsage,
        to summary: inout TokenUsageSummary,
        totalsByModel: inout [String: Int]
    ) {
        summary.inputTokens += session.usage.inputTokens
        summary.cachedInputTokens += session.usage.cachedInputTokens
        summary.outputTokens += session.usage.outputTokens
        summary.reasoningOutputTokens += session.usage.reasoningOutputTokens
        summary.totalTokens += session.usage.totalTokens
        summary.sessionCount += 1

        guard let model = session.model,
              let cost = pricingCatalog.estimateCost(for: model, usage: session.usage) else {
            return
        }

        summary.estimatedCostUSD += cost.total
        summary.uncachedInputCostUSD += cost.uncachedInput
        summary.cachedInputCostUSD += cost.cachedInput
        summary.outputCostUSD += cost.output
        summary.pricedSessionCount += 1
        totalsByModel[pricingCatalog.displayModelName(for: model), default: 0] += session.usage.totalTokens
    }

    private func sessionUsage(from fileURL: URL) throws -> SessionUsage? {
        let headData = try readHead(of: fileURL, maxBytes: 2_000_000)
        let tailData = try readTail(of: fileURL, maxBytes: 160_000)
        guard let headText = String(data: headData, encoding: .utf8),
              let tailText = String(data: tailData, encoding: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        let model = modelName(from: headText, decoder: decoder)
        var latestUsage: TokenUsagePayload?
        var latestTimestamp: Date?

        for line in tailText.split(whereSeparator: \.isNewline) {
            guard let entry = try? decoder.decode(TokenUsageLogEntry.self, from: Data(line.utf8)) else {
                continue
            }

            guard entry.type == "event_msg",
                  entry.payload?.type == "token_count",
                  let usage = entry.payload?.info?.totalTokenUsage else {
                continue
            }

            latestUsage = usage
            latestTimestamp = entry.timestamp.flatMap(Formatters.parseISO8601)
        }

        guard let latestUsage else {
            return nil
        }

        let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return SessionUsage(
            model: model,
            usage: latestUsage,
            updatedAt: latestTimestamp ?? modifiedAt ?? Date.distantPast
        )
    }

    private func modelName(from text: String, decoder: JSONDecoder) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = try? decoder.decode(TokenUsageLogEntry.self, from: Data(line.utf8)),
                  entry.type == "turn_context",
                  let model = entry.payload?.model,
                  !model.isEmpty else {
                continue
            }

            return model
        }

        return nil
    }

    private func readHead(of fileURL: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    private func readTail(of fileURL: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let offset = max(0, Int64(fileSize) - Int64(maxBytes))
        try handle.seek(toOffset: UInt64(offset))
        return try handle.readToEnd() ?? Data()
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
        let index = try decoder.decode(TokenUsageSessionIndex.self, from: data)
        guard index.schemaVersion == TokenUsageSessionIndex.schemaVersion else {
            return nil
        }
        return index
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
    static let schemaVersion = 1

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

    func matches(_ file: SessionLogFile) -> Bool {
        path == file.path && size == file.size && modifiedAt == file.modifiedAt
    }
}

struct SessionUsage: Codable {
    let model: String?
    let usage: TokenUsagePayload
    let updatedAt: Date
}

struct TokenUsagePayload: Codable, Equatable {
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
    let timestamp: String?
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
