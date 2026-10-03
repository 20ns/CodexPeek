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
    private static let relevantLogMarkers = [
        "\"session_meta\"",
        "\"turn_context\"",
        "\"token_count\"",
        "\"thread_settings_applied\"",
        "\"inter_agent_communication_metadata\""
    ].map { Data($0.utf8) }

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
        let last30DaysCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let files = try sessionLogFiles()
        var index = (try? indexStore?.load()) ?? TokenUsageSessionIndex()
        let currentPaths = Set(files.map(\.path))
        var indexChanged = Set(index.sessions.keys) != currentPaths
        index.sessions = index.sessions.filter { currentPaths.contains($0.key) }
        var report = TokenUsageReport.empty
        var weeklyTotalsByModel: [String: Int] = [:]
        var last30DaysTotalsByModel: [String: Int] = [:]
        var allTimeTotalsByModel: [String: Int] = [:]
        var allBuckets: [TokenUsageBucket] = []

        for file in files {
            let session: SessionUsage?
            if let cached = index.sessions[file.path], cached.matches(file) {
                session = cached.session
            } else {
                session = try autoreleasepool(invoking: {
                    try sessionUsage(from: file.url, fallbackTimestamp: file.modifiedAt)
                })
                index.sessions[file.path] = IndexedSessionUsage(file: file, session: session)
                indexChanged = true
            }

            guard let session else {
                continue
            }

            allBuckets.append(contentsOf: session.buckets)
            add(session.buckets, since: nil, to: &report.allTime, totalsByModel: &allTimeTotalsByModel)
            add(session.buckets, since: last30DaysCutoff, to: &report.month, totalsByModel: &last30DaysTotalsByModel)
            add(session.buckets, since: weekCutoff, to: &report.week, totalsByModel: &weeklyTotalsByModel)
        }

        report.week.topModel = weeklyTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.month.topModel = last30DaysTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.allTime.topModel = allTimeTotalsByModel.max { lhs, rhs in lhs.value < rhs.value }?.key
        report.generatedAt = now
        report.historyIncludesAllRetainedSessions = true
        report.history = TokenUsageHistory(buckets: allBuckets.sorted { $0.startedAt < $1.startedAt })
        if indexChanged {
            try? indexStore?.save(index)
        }
        return report
    }

    private func sessionLogFiles() throws -> [SessionLogFile] {
        var files: [SessionLogFile] = []
        let archived = sessionsRootURL.deletingLastPathComponent().appendingPathComponent("archived_sessions", isDirectory: true)
        for root in [sessionsRootURL, archived] {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append(SessionLogFile(
                    url: fileURL,
                    path: fileURL.path,
                    size: values.fileSize ?? 0,
                    modifiedAt: values.contentModificationDate ?? Date.distantPast
                ))
            }
        }

        return files
    }

    private func add(
        _ buckets: [TokenUsageBucket],
        since cutoff: Date?,
        to summary: inout TokenUsageSummary,
        totalsByModel: inout [String: Int]
    ) {
        var selectedAny = false
        var priced = false

        for bucket in buckets {
            if let cutoff, bucket.startedAt < cutoff { continue }
            selectedAny = true
            summary.inputTokens += bucket.usage.inputTokens
            summary.cachedInputTokens += bucket.usage.cachedInputTokens
            summary.outputTokens += bucket.usage.outputTokens
            summary.reasoningOutputTokens += bucket.usage.reasoningOutputTokens
            summary.totalTokens += bucket.usage.totalTokens
            totalsByModel[pricingCatalog.displayModelName(for: bucket.model), default: 0] += bucket.usage.totalTokens

            guard let cost = pricingCatalog.estimateCost(
                for: bucket.model,
                usage: bucket.usage,
                serviceTier: bucket.serviceTier,
                isLongContext: bucket.isLongContext == true,
                inferenceGeo: bucket.inferenceGeo
            ) else { continue }
            summary.estimatedCostUSD += cost.total
            summary.uncachedInputCostUSD += cost.uncachedInput
            summary.cachedInputCostUSD += cost.cachedInput
            summary.outputCostUSD += cost.output
            priced = true
        }
        guard selectedAny else { return }
        summary.sessionCount += 1
        summary.pricedSessionCount += priced ? 1 : 0
    }

    private func sessionUsage(from fileURL: URL, fallbackTimestamp: Date) throws -> SessionUsage? {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        var buckets: [TokenUsageBucket] = []
        var previousUsage = TokenUsagePayload.zero
        var model = "Unknown model"
        var serviceTier: String?
        var sawSessionMetadata = false
        var includeUsage = true
        var inheritedUsageCutoff: Date?
        var lineStart = data.startIndex

        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 10) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            defer {
                lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            }
            guard Self.relevantLogMarkers.contains(where: { line.range(of: $0) != nil }),
                  let entry = try? decoder.decode(TokenUsageLogEntry.self, from: line) else { continue }

            if entry.type == "session_meta", !sawSessionMetadata {
                sawSessionMetadata = true
                includeUsage = entry.payload?.multiAgentVersion != "v2" || entry.payload?.threadSource != "subagent"
                if entry.payload?.forkedFromID != nil || entry.payload?.threadSource == "fork" {
                    inheritedUsageCutoff = entry.timestamp.flatMap(Formatters.parseISO8601)
                }
            } else if entry.type == "inter_agent_communication_metadata" {
                includeUsage = true
            } else if entry.type == "event_msg", entry.payload?.type == "thread_settings_applied" {
                serviceTier = entry.payload?.threadSettings?.serviceTier
            } else if entry.type == "turn_context", let nextModel = entry.payload?.model, !nextModel.isEmpty {
                model = nextModel
            } else if entry.type == "event_msg",
                      entry.payload?.type == "token_count",
                      let info = entry.payload?.info,
                      let usage = info.totalTokenUsage,
                      usage.isConsistent,
                      usage != previousUsage {
                let delta = usage.delta(since: previousUsage)
                previousUsage = usage
                let timestamp = entry.timestamp.flatMap(Formatters.parseISO8601) ?? fallbackTimestamp
                // ponytail: copied fork rows retain timestamps; ordinal boundaries are needed if that format changes.
                if let inheritedUsageCutoff, timestamp <= inheritedUsageCutoff { continue }
                guard includeUsage,
                      let incrementalUsage = info.lastTokenUsage?.isConsistent == true ? info.lastTokenUsage : delta,
                      incrementalUsage.totalTokens > 0 else { continue }

                let interval = Date(timeIntervalSince1970: floor(timestamp.timeIntervalSince1970 / 900) * 900)
                let usesChatGPTCredits = entry.payload?.rateLimits.map { $0.planType != nil }
                // ponytail: cumulative-only rows may span requests; exact long-context pricing needs per-request input counts.
                let isLongContext = incrementalUsage.inputTokens > 272_000
                if let last = buckets.indices.last,
                   buckets[last].startedAt == interval,
                   buckets[last].model == model,
                   buckets[last].serviceTier == serviceTier,
                   buckets[last].usesChatGPTCredits == usesChatGPTCredits,
                   buckets[last].isLongContext == isLongContext {
                    buckets[last].usage.add(incrementalUsage)
                } else {
                    buckets.append(TokenUsageBucket(
                        startedAt: interval,
                        model: model,
                        serviceTier: serviceTier,
                        usesChatGPTCredits: usesChatGPTCredits,
                        isLongContext: isLongContext,
                        usage: incrementalUsage
                    ))
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
    }

    func load() throws -> TokenUsageSessionIndex? {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: cacheURL)
        let index = try decoder.decode(TokenUsageSessionIndex.self, from: data)
        return index.schemaVersion == TokenUsageSessionIndex.schemaVersion ? index : nil
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
        var priorityMultiplier: Decimal = 1
        var fastCreditMultiplier: Decimal? = nil
        var longContext: Bool = false
        var ultrafastMultiplier: Decimal? = nil
        var fastModeUnpriced: Bool = false
        var usDataResidency: Bool = false
        var longContextThreshold: Int? = nil
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
        "gpt-6.1-sol": Price(inputPerMillion: 2, cachedInputPerMillion: 0.1, outputPerMillion: 10, displayName: "GPT-6.1 Sol", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-6-sol": Price(inputPerMillion: 2, cachedInputPerMillion: 0.2, outputPerMillion: 10, displayName: "GPT-6 Sol", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-6-luna": Price(inputPerMillion: 0.1, cachedInputPerMillion: 0.01, outputPerMillion: 0.5, displayName: "GPT-6 Luna", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-6-astra": Price(inputPerMillion: 10, cachedInputPerMillion: 1, outputPerMillion: 50, displayName: "GPT-6 Astra", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true, ultrafastMultiplier: 6),
        "gpt-5.6-sol": Price(inputPerMillion: 4, cachedInputPerMillion: 0.4, outputPerMillion: 20, displayName: "GPT-5.6 Sol", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-5.6-terra": Price(inputPerMillion: 2, cachedInputPerMillion: 0.2, outputPerMillion: 12, displayName: "GPT-5.6 Terra", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-5.6-luna": Price(inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.2, displayName: "GPT-5.6 Luna", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-5.6-cyber": Price(inputPerMillion: 12.5, cachedInputPerMillion: 1.25, outputPerMillion: 75, displayName: "GPT-5.6 Cyber"),
        "gpt-daybreak-blue-latest": Price(inputPerMillion: 4, cachedInputPerMillion: 0.4, outputPerMillion: 20, displayName: "Daybreak Blue", priorityMultiplier: 2, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-daybreak-red-latest": Price(inputPerMillion: 12.5, cachedInputPerMillion: 1.25, outputPerMillion: 75, displayName: "Daybreak Red"),
        "gpt-5.5": Price(inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30, displayName: "GPT-5.5", priorityMultiplier: 2.5, fastCreditMultiplier: 2.5, longContext: true),
        "gpt-5.5-pro": Price(inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180, displayName: "GPT-5.5 Pro", longContext: true),
        "gpt-5.4": Price(inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15, displayName: "GPT-5.4", priorityMultiplier: 2, fastCreditMultiplier: 2, longContext: true),
        "gpt-5.4-pro": Price(inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180, displayName: "GPT-5.4 Pro", longContext: true),
        "gpt-5.4-mini": Price(inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.5, displayName: "GPT-5.4 Mini", priorityMultiplier: 2),
        "gpt-5.4-nano": Price(inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.25, displayName: "GPT-5.4 Nano"),
        "gpt-5.3-codex": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, displayName: "GPT-5.3 Codex"),
        "gpt-5.2": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, displayName: "GPT-5.2", priorityMultiplier: 2),
        "gpt-5.2-codex": Price(inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, displayName: "GPT-5.2 Codex"),
        "claude-fable-5-1": claudePrice("Claude Fable 5.1", "10", "50", "0.25"),
        "claude-mythos-5-1": claudePrice("Claude Mythos 5.1", "10", "50", "0.25"),
        "claude-opus-5-5": claudePrice("Claude Opus 5.5", "4", "20", "0.2", fast: true),
        "claude-sonnet-5-5": claudePrice("Claude Sonnet 5.5", "2", "10", "0.2"),
        "claude-fable-5": claudePrice("Claude Fable 5", "10", "50", "1"),
        "claude-mythos-5": claudePrice("Claude Mythos 5", "10", "50", "1"),
        "claude-opus-5": claudePrice("Claude Opus 5", "5", "25", "0.5", fast: true),
        "claude-opus-4-8": claudePrice("Claude Opus 4.8", "5", "25", "0.5", fast: true),
        "claude-opus-4-7": claudePrice("Claude Opus 4.7", "5", "25", "0.5"),
        "claude-opus-4-6": claudePrice("Claude Opus 4.6", "5", "25", "0.5"),
        "claude-opus-4-5": claudePrice("Claude Opus 4.5", "5", "25", "0.5", us: false),
        "claude-opus-4-1": claudePrice("Claude Opus 4.1", "15", "75", "1.5", us: false),
        "claude-opus-4": claudePrice("Claude Opus 4", "15", "75", "1.5", us: false),
        "claude-sonnet-5": claudePrice("Claude Sonnet 5", "2", "10", "0.2"),
        "claude-sonnet-4-6": claudePrice("Claude Sonnet 4.6", "3", "15", "0.3"),
        "claude-sonnet-4-5": claudePrice("Claude Sonnet 4.5", "3", "15", "0.3", us: false, longContextAt: 200_000),
        "claude-sonnet-4": claudePrice("Claude Sonnet 4", "3", "15", "0.3", us: false, longContextAt: 200_000),
        "claude-haiku-4-5": claudePrice("Claude Haiku 4.5", "1", "5", "0.1", us: false),
        "claude-haiku-3-5": claudePrice("Claude Haiku 3.5", "0.8", "4", "0.08", us: false)
    ])

    private static func claudePrice(
        _ name: String,
        _ input: String,
        _ output: String,
        _ read: String,
        fast: Bool = false,
        us: Bool = true,
        longContextAt threshold: Int? = nil
    ) -> Price {
        Price(
            inputPerMillion: Decimal(string: input)!,
            cachedInputPerMillion: Decimal(string: read)!,
            outputPerMillion: Decimal(string: output)!,
            displayName: name,
            priorityMultiplier: fast ? 2 : 1,
            longContext: threshold != nil,
            fastModeUnpriced: !fast,
            usDataResidency: us,
            longContextThreshold: threshold
        )
    }

    private let prices: [String: Price]
    private let snapshotPrices: [(prefix: String, price: Price)]

    private init(prices: [String: Price]) {
        self.prices = prices
        snapshotPrices = prices.map { ("\($0.key)-20", $0.value) }
            .sorted { $0.prefix.count > $1.prefix.count }
    }

    func estimateCost(
        for model: String,
        usage: TokenUsagePayload,
        serviceTier: String? = nil,
        isLongContext: Bool = false,
        inferenceGeo: String? = nil
    ) -> Cost? {
        guard let price = price(for: model), let multiplier = speedMultiplier(for: price, serviceTier: serviceTier) else {
            return nil
        }

        let long = isLongContext && price.longContext
        let geo = geoMultiplier(for: price, inferenceGeo: inferenceGeo)
        let cachedInput = max(0, usage.cachedInputTokens)
        let writes5 = max(0, usage.cacheCreationInputTokens ?? 0)
        let writes1 = max(0, usage.cacheCreation1hInputTokens ?? 0)
        if writes5 == 0, writes1 == 0, geo == 1 {
            let uncachedInput = max(0, usage.inputTokens - cachedInput)
            return Cost(
                uncachedInput: Decimal(uncachedInput) / 1_000_000 * price.inputPerMillion * multiplier * (long ? 2 : 1),
                cachedInput: Decimal(cachedInput) / 1_000_000 * price.cachedInputPerMillion * multiplier * (long ? 2 : 1),
                output: Decimal(usage.outputTokens) / 1_000_000 * price.outputPerMillion * multiplier * (long ? 1.5 : 1)
            )
        }

        let fresh = max(0, usage.inputTokens - cachedInput - writes5 - writes1)
        let inputScale = multiplier * geo * (long ? 2 : 1)
        let outputScale = multiplier * geo * (long ? Decimal(string: "1.5")! : 1)
        let write5Rate = Decimal(string: "1.25")!
        let uncached = (
            Decimal(fresh) * price.inputPerMillion
                + Decimal(writes5) * price.inputPerMillion * write5Rate
                + Decimal(writes1) * price.inputPerMillion * 2
        ) / 1_000_000 * inputScale
        return Cost(
            uncachedInput: uncached,
            cachedInput: Decimal(cachedInput) / 1_000_000 * price.cachedInputPerMillion * inputScale,
            output: Decimal(max(0, usage.outputTokens)) / 1_000_000 * price.outputPerMillion * outputScale
        )
    }

    func estimateCacheSavings(
        for model: String,
        usage: TokenUsagePayload,
        serviceTier: String? = nil,
        isLongContext: Bool = false,
        inferenceGeo: String? = nil
    ) -> Decimal? {
        guard let price = price(for: model), let multiplier = speedMultiplier(for: price, serviceTier: serviceTier) else {
            return nil
        }
        let geo = geoMultiplier(for: price, inferenceGeo: inferenceGeo)
        let writes5 = max(0, usage.cacheCreationInputTokens ?? 0)
        let writes1 = max(0, usage.cacheCreation1hInputTokens ?? 0)
        let longScale = (isLongContext && price.longContext) ? Decimal(2) : Decimal(1)
        if writes5 == 0, writes1 == 0, geo == 1 {
            return Decimal(max(0, usage.cachedInputTokens)) / 1_000_000
                * (price.inputPerMillion - price.cachedInputPerMillion)
                * multiplier * ((isLongContext && price.longContext) ? 2 : 1)
        }
        let scale = multiplier * geo * longScale
        let readSavings = Decimal(max(0, usage.cachedInputTokens)) / 1_000_000
            * (price.inputPerMillion - price.cachedInputPerMillion) * scale
        let writePremium = Decimal(writes5) / 1_000_000 * price.inputPerMillion * Decimal(string: "0.25")! * scale
            + Decimal(writes1) / 1_000_000 * price.inputPerMillion * scale
        return readSavings - writePremium
    }

    func chargesLongContextPremium(for model: String, inputTokens: Int) -> Bool {
        guard let price = price(for: model), price.longContext else { return false }
        return inputTokens > (price.longContextThreshold ?? 272_000)
    }

    func displayModelName(for model: String) -> String {
        price(for: model)?.displayName ?? model
    }

    func fastCreditMultiplier(for model: String) -> Decimal? {
        price(for: model)?.fastCreditMultiplier
    }

    static func isFastTier(_ serviceTier: String?) -> Bool {
        switch serviceTier?.lowercased() {
        case "priority", "fast", "ultrafast":
            return true
        default:
            return false
        }
    }

    private func speedMultiplier(for price: Price, serviceTier: String?) -> Decimal? {
        switch serviceTier?.lowercased() {
        case "unpriced":
            return nil
        case "ultrafast":
            return price.ultrafastMultiplier
        case "priority", "fast":
            return price.fastModeUnpriced ? nil : price.priorityMultiplier
        default:
            return 1
        }
    }

    private func geoMultiplier(for price: Price, inferenceGeo: String?) -> Decimal {
        guard price.usDataResidency, inferenceGeo?.lowercased() == "us" else { return 1 }
        return Decimal(string: "1.1") ?? 1
    }

    private func price(for model: String) -> Price? {
        let normalized = model.lowercased()
        if let exact = prices[normalized] {
            return exact
        }

        return snapshotPrices.first { normalized.hasPrefix($0.prefix) }?.price
    }
}

struct SessionLogFile {
    let url: URL
    let path: String
    let size: Int
    let modifiedAt: Date
}

struct TokenUsageSessionIndex: Codable {
    static let schemaVersion = 9

    var schemaVersion = TokenUsageSessionIndex.schemaVersion
    var claudeParserVersion: Int? = nil
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

struct UsageRequestRecord: Codable, Equatable {
    var messageID: String
    var requestID: String
    var startedAt: Date
    var model: String
    var serviceTier: String?
    var inferenceGeo: String?
    var isLongContext: Bool?
    var usage: TokenUsagePayload
}

struct SessionUsage: Codable {
    var buckets: [TokenUsageBucket]
    var requests: [UsageRequestRecord]? = nil
}

struct TokenUsagePayload: Codable, Hashable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let totalTokens: Int
    var cacheCreationInputTokens: Int? = nil
    var cacheCreation1hInputTokens: Int? = nil

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
            totalTokens: totalTokens + other.totalTokens,
            cacheCreationInputTokens: Self.combined(cacheCreationInputTokens, other.cacheCreationInputTokens, +),
            cacheCreation1hInputTokens: Self.combined(cacheCreation1hInputTokens, other.cacheCreation1hInputTokens, +)
        )
    }

    var isConsistent: Bool {
        let writes5 = cacheCreationInputTokens ?? 0
        let writes1 = cacheCreation1hInputTokens ?? 0
        return inputTokens >= 0 && cachedInputTokens >= 0 && outputTokens >= 0 && reasoningOutputTokens >= 0
            && writes5 >= 0 && writes1 >= 0
            && cachedInputTokens <= inputTokens && reasoningOutputTokens <= outputTokens
            && totalTokens >= inputTokens && totalTokens - inputTokens == outputTokens
            && cachePartsFit(cachedInputTokens, writes5, writes1, within: inputTokens)
    }

    func delta(since previous: TokenUsagePayload) -> TokenUsagePayload? {
        let writes5 = Self.combined(cacheCreationInputTokens, previous.cacheCreationInputTokens, -)
        let writes1 = Self.combined(cacheCreation1hInputTokens, previous.cacheCreation1hInputTokens, -)
        let delta = TokenUsagePayload(
            inputTokens: inputTokens - previous.inputTokens,
            cachedInputTokens: cachedInputTokens - previous.cachedInputTokens,
            outputTokens: outputTokens - previous.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens: totalTokens - previous.totalTokens,
            cacheCreationInputTokens: writes5,
            cacheCreation1hInputTokens: writes1
        )
        if [delta.inputTokens, delta.cachedInputTokens, delta.outputTokens, delta.reasoningOutputTokens, delta.totalTokens].contains(where: { $0 < 0 }) {
            return nil
        }
        if (writes5 ?? 0) < 0 || (writes1 ?? 0) < 0 {
            return nil
        }
        return delta
    }

    private func cachePartsFit(_ parts: Int..., within limit: Int) -> Bool {
        var sum = 0
        for part in parts where part > 0 {
            if sum > limit - part { return false }
            sum += part
        }
        return sum <= limit
    }

    private static func combined(_ current: Int?, _ previous: Int?, _ operation: (Int, Int) -> Int) -> Int? {
        if current == nil, previous == nil { return nil }
        return operation(current ?? 0, previous ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation1hInputTokens = "cache_creation_1h_input_tokens"
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
    let threadSettings: TokenUsageThreadSettings?
    let rateLimits: TokenUsageRateLimits?

    let multiAgentVersion: String?
    let threadSource: String?
    let forkedFromID: String?

    private enum CodingKeys: String, CodingKey {
        case type, model, info
        case threadSettings = "thread_settings"
        case rateLimits = "rate_limits"
        case multiAgentVersion = "multi_agent_version"
        case threadSource = "thread_source"
        case forkedFromID = "forked_from_id"
    }
}

private struct TokenUsageRateLimits: Decodable {
    let planType: String?

    private enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
    }
}

private struct TokenUsageThreadSettings: Decodable {
    let serviceTier: String?

    private enum CodingKeys: String, CodingKey {
        case serviceTier = "service_tier"
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
