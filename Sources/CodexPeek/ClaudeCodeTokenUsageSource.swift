import Foundation

final class ClaudeCodeTokenUsageSource: TokenUsageSource, @unchecked Sendable {
    private let projectsRootURL: URL
    private let fileManager: FileManager
    private let pricingCatalog: TokenPricingCatalog
    private let indexStore: TokenUsageSessionIndexStoring?

    init(
        projectsRootURL: URL = ClaudeCodeTokenUsageSource.defaultProjectsRoot(),
        fileManager: FileManager = .default,
        pricingCatalog: TokenPricingCatalog = .standard,
        indexStore: TokenUsageSessionIndexStoring? = nil
    ) {
        self.projectsRootURL = projectsRootURL
        self.fileManager = fileManager
        self.pricingCatalog = pricingCatalog
        self.indexStore = indexStore
    }

    static func defaultProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base: URL
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            base = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    func usageReport() throws -> TokenUsageReport {
        let now = Date()
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let files = try logFiles()
        var index = (try? indexStore?.load()) ?? TokenUsageSessionIndex()
        let parserChanged = index.claudeParserVersion != 3
        if parserChanged {
            index = TokenUsageSessionIndex()
            index.claudeParserVersion = 3
        }
        let currentPaths = Set(files.map(\.path))
        var indexChanged = parserChanged || Set(index.sessions.keys) != currentPaths
        index.sessions = index.sessions.filter { currentPaths.contains($0.key) }

        var requestsByID: [String: (path: String, record: UsageRequestRecord)] = [:]
        var report = TokenUsageReport.empty
        var weekModels: [String: Int] = [:]
        var monthModels: [String: Int] = [:]
        var allModels: [String: Int] = [:]
        var historyRequests: [UsageRequestRecord] = []

        for file in files {
            let session: SessionUsage?
            if let cached = index.sessions[file.path], cached.matches(file) {
                session = cached.session
            } else {
                session = try autoreleasepool {
                    try sessionUsage(from: file.url, fallbackTimestamp: file.modifiedAt)
                }
                index.sessions[file.path] = IndexedSessionUsage(file: file, session: session)
                indexChanged = true
            }

            for (offset, request) in (session?.requests ?? []).enumerated() {
                let key = request.messageID.isEmpty && request.requestID.isEmpty
                    ? "\(file.path)#\(offset)" : "\(request.messageID)\n\(request.requestID)"
                if var existing = requestsByID[key] {
                    let old = existing.record.usage
                    let next = request.usage
                    let reads = max(old.cachedInputTokens, next.cachedInputTokens)
                    let five = max(old.cacheCreationInputTokens ?? 0, next.cacheCreationInputTokens ?? 0)
                    let hour = max(old.cacheCreation1hInputTokens ?? 0, next.cacheCreation1hInputTokens ?? 0)
                    let input = max(old.inputTokens, next.inputTokens)
                    let output = max(old.outputTokens, next.outputTokens)
                    guard input <= Int.max - output else { continue }
                    existing.record.usage = TokenUsagePayload(inputTokens: input, cachedInputTokens: reads,
                        outputTokens: output, reasoningOutputTokens: min(output, max(old.reasoningOutputTokens, next.reasoningOutputTokens)), totalTokens: input + output,
                        cacheCreationInputTokens: five, cacheCreation1hInputTokens: hour)
                    guard existing.record.usage.isConsistent else { continue }
                    existing.record.startedAt = min(existing.record.startedAt, request.startedAt)
                    existing.record.inferenceGeo = existing.record.inferenceGeo ?? request.inferenceGeo
                    if existing.record.serviceTier != "unpriced", request.serviceTier != nil {
                        existing.record.serviceTier = request.serviceTier
                    }
                    existing.record.isLongContext = pricingCatalog.chargesLongContextPremium(for: request.model, inputTokens: input)
                    requestsByID[key] = existing
                } else {
                    requestsByID[key] = (file.path, request)
                }
            }
        }

        let grouped = Dictionary(grouping: requestsByID.values, by: { $0.path })
        for path in grouped.keys.sorted() {
            let requests = grouped[path]!.map { $0.record }
            historyRequests.append(contentsOf: requests)
            add(requests, since: nil, to: &report.allTime, totalsByModel: &allModels)
            add(requests, since: monthCutoff, to: &report.month, totalsByModel: &monthModels)
            add(requests, since: weekCutoff, to: &report.week, totalsByModel: &weekModels)
        }

        report.week.topModel = weekModels.max { $0.value < $1.value }?.key
        report.month.topModel = monthModels.max { $0.value < $1.value }?.key
        report.allTime.topModel = allModels.max { $0.value < $1.value }?.key
        report.generatedAt = now
        report.historyIncludesAllRetainedSessions = true
        report.history = TokenUsageHistory(buckets: historyBuckets(from: historyRequests))
        if indexChanged {
            try? indexStore?.save(index)
        }
        return ClaudeLegacyUsage.backfill(report, from: projectsRootURL.deletingLastPathComponent().appendingPathComponent("stats-cache.json"))
    }

    private func logFiles() throws -> [SessionLogFile] {
        do {
            guard try projectsRootURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: projectsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }

        var files: [SessionLogFile] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            files.append(SessionLogFile(
                url: fileURL,
                path: fileURL.path,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }

    private func add(
        _ requests: [UsageRequestRecord],
        since cutoff: Date?,
        to summary: inout TokenUsageSummary,
        totalsByModel: inout [String: Int]
    ) {
        var selected = false
        var priced = false
        for request in requests {
            if let cutoff, request.startedAt < cutoff { continue }
            selected = true
            summary.inputTokens += request.usage.inputTokens
            summary.cachedInputTokens += request.usage.cachedInputTokens
            summary.outputTokens += request.usage.outputTokens
            summary.reasoningOutputTokens += request.usage.reasoningOutputTokens
            summary.totalTokens += request.usage.totalTokens
            totalsByModel[pricingCatalog.displayModelName(for: request.model), default: 0] += request.usage.totalTokens
            guard let cost = pricingCatalog.estimateCost(
                for: request.model,
                usage: request.usage,
                serviceTier: request.serviceTier,
                isLongContext: request.isLongContext == true,
                inferenceGeo: request.inferenceGeo
            ) else { continue }
            summary.estimatedCostUSD += cost.total
            summary.uncachedInputCostUSD += cost.uncachedInput
            summary.cachedInputCostUSD += cost.cachedInput
            summary.outputCostUSD += cost.output
            priced = true
        }
        guard selected else { return }
        summary.sessionCount += 1
        summary.pricedSessionCount += priced ? 1 : 0
    }

    private func historyBuckets(from requests: [UsageRequestRecord]) -> [TokenUsageBucket] {
        var buckets: [TokenUsageBucket] = []
        for request in requests.sorted(by: { $0.startedAt < $1.startedAt }) {
            let interval = Date(timeIntervalSince1970: floor(request.startedAt.timeIntervalSince1970 / 900) * 900)
            if let last = buckets.indices.last,
               buckets[last].startedAt == interval,
               buckets[last].model == request.model,
               buckets[last].serviceTier == request.serviceTier,
               buckets[last].inferenceGeo == request.inferenceGeo,
               buckets[last].isLongContext == request.isLongContext {
                buckets[last].usage.add(request.usage)
            } else {
                buckets.append(TokenUsageBucket(
                    startedAt: interval,
                    model: request.model,
                    serviceTier: request.serviceTier,
                    isLongContext: request.isLongContext,
                    usage: request.usage,
                    inferenceGeo: request.inferenceGeo
                ))
            }
        }
        return buckets
    }

    private func sessionUsage(from fileURL: URL, fallbackTimestamp: Date) throws -> SessionUsage? {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        let usageMarker = Data("\"usage\"".utf8)
        var grouped: [String: PendingRequest] = [:]
        var order: [String] = []
        var lineNumber = 0
        var lineStart = data.startIndex

        while lineStart < data.endIndex {
            let lineEnd = data[lineStart...].firstIndex(of: 10) ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            lineNumber += 1
            lineStart = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            guard line.range(of: usageMarker) != nil,
                  let entry = try? decoder.decode(ClaudeTranscriptLine.self, from: Data(line)),
                  let pending = pendingRequest(from: entry, lineNumber: lineNumber) else { continue }
            if var existing = grouped[pending.key] {
                existing.merge(pending)
                grouped[pending.key] = existing
            } else {
                order.append(pending.key)
                grouped[pending.key] = pending
            }
        }

        let requests = order.compactMap { grouped[$0]?.record(fallbackTimestamp: fallbackTimestamp, catalog: pricingCatalog) }
        return requests.isEmpty ? nil : SessionUsage(buckets: [], requests: requests)
    }

    private func pendingRequest(from entry: ClaudeTranscriptLine, lineNumber: Int) -> PendingRequest? {
        guard entry.type == "assistant",
              entry.isApiErrorMessage != true,
              entry.isSynthetic != true,
              entry.isMeta != true,
              let model = entry.message?.model,
              !model.isEmpty,
              !model.hasPrefix("<"),
              let usage = entry.message?.usage,
              [usage.inputTokens, usage.outputTokens, usage.cacheReadInputTokens, usage.cacheCreationInputTokens,
               usage.cacheCreation?.ephemeral5m, usage.cacheCreation?.ephemeral1h, usage.outputDetails?.thinkingTokens]
                .compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { return nil }

        let five = usage.cacheCreation?.ephemeral5m ?? 0
        let hour = usage.cacheCreation?.ephemeral1h ?? 0
        guard five <= Int.max - hour else { return nil }
        if let aggregate = usage.cacheCreationInputTokens, aggregate < five + hour { return nil }
        var input = 0
        for count in [usage.inputTokens ?? 0, usage.cacheReadInputTokens ?? 0, max(usage.cacheCreationInputTokens ?? 0, five + hour)] {
            guard count <= Int.max - input else { return nil }
            input += count
        }
        let messageID = entry.message?.id ?? ""
        let requestID = entry.requestId ?? entry.requestIDSnake ?? ""
        let speed: PendingRequest.Speed
        switch usage.speed?.lowercased() {
        case nil, "", "standard":
            speed = .standard
        case "fast":
            speed = .fast
        default:
            speed = .unpriced
        }
        let knownTier = usage.serviceTier == nil || ["standard", "priority"].contains(usage.serviceTier?.lowercased() ?? "")
        return PendingRequest(
            key: messageID.isEmpty && requestID.isEmpty ? "#\(lineNumber)" : "\(messageID)\n\(requestID)",
            messageID: messageID,
            requestID: requestID,
            startedAt: entry.timestamp.flatMap(Formatters.parseISO8601),
            model: model,
            speed: knownTier ? speed : .unpriced,
            inferenceGeo: usage.inferenceGeo,
            input: input,
            hasAggregateWrites: usage.cacheCreationInputTokens != nil,
            reads: max(0, usage.cacheReadInputTokens ?? 0),
            aggregateWrites: max(0, usage.cacheCreationInputTokens ?? 0),
            five: usage.cacheCreation?.ephemeral5m,
            hour: usage.cacheCreation?.ephemeral1h,
            output: max(0, usage.outputTokens ?? 0),
            reasoning: usage.outputDetails?.thinkingTokens ?? 0
        )
    }

    /// Structured 5-minute and 1-hour fields split `cache_creation_input_tokens`. They are not added to it.
    static func partitionCacheWrites(aggregate: Int, ephemeral5m: Int?, ephemeral1h: Int?) -> (five: Int, hour: Int) {
        let aggregate = max(0, aggregate)
        guard ephemeral5m != nil || ephemeral1h != nil else { return (aggregate, 0) }
        let five = max(0, ephemeral5m ?? 0)
        let hour = max(0, ephemeral1h ?? 0)
        let structured = five + hour
        // ponytail: leftover cache_creation without a TTL is billed as 5-minute writes; split it if Anthropic adds another duration.
        let residual = aggregate > structured ? aggregate - structured : 0
        return (five + residual, hour)
    }
}

private struct PendingRequest {
    enum Speed {
        case standard
        case fast
        case unpriced
    }

    var key: String
    var messageID: String
    var requestID: String
    var startedAt: Date?
    var model: String
    var speed: Speed
    var inferenceGeo: String?
    var input: Int
    var hasAggregateWrites: Bool
    var reads: Int
    var aggregateWrites: Int
    var five: Int?
    var hour: Int?
    var output: Int
    var reasoning: Int

    mutating func merge(_ other: PendingRequest) {
        if startedAt == nil { startedAt = other.startedAt }
        if model.isEmpty { model = other.model }
        if inferenceGeo == nil { inferenceGeo = other.inferenceGeo }
        switch other.speed {
        case .unpriced:
            speed = .unpriced
        case .fast where speed != .unpriced:
            speed = .fast
        case .standard, .fast:
            break
        }
        input = max(input, other.input)
        hasAggregateWrites = hasAggregateWrites || other.hasAggregateWrites
        reads = max(reads, other.reads)
        output = max(output, other.output)
        reasoning = max(reasoning, other.reasoning)
        aggregateWrites = max(aggregateWrites, other.aggregateWrites)
        if let value = other.five { five = max(five ?? 0, value) }
        if let value = other.hour { hour = max(hour ?? 0, value) }
    }

    func record(fallbackTimestamp: Date, catalog: TokenPricingCatalog) -> UsageRequestRecord? {
        guard (five ?? 0) <= Int.max - (hour ?? 0),
              !hasAggregateWrites || (five ?? 0) + (hour ?? 0) <= aggregateWrites else { return nil }
        let (writes5, writes1) = ClaudeCodeTokenUsageSource.partitionCacheWrites(
            aggregate: aggregateWrites,
            ephemeral5m: five,
            ephemeral1h: hour
        )
        guard input <= Int.max - output else { return nil }
        let total = input + output
        guard total > 0 else { return nil }
        let usage = TokenUsagePayload(
            inputTokens: input,
            cachedInputTokens: reads,
            outputTokens: output,
            reasoningOutputTokens: min(reasoning, output),
            totalTokens: total,
            cacheCreationInputTokens: writes5,
            cacheCreation1hInputTokens: writes1
        )
        guard usage.isConsistent else { return nil }
        let serviceTier: String?
        switch speed {
        case .standard: serviceTier = nil
        case .fast: serviceTier = "fast"
        case .unpriced: serviceTier = "unpriced"
        }
        return UsageRequestRecord(
            messageID: messageID,
            requestID: requestID,
            startedAt: startedAt ?? fallbackTimestamp,
            model: model,
            serviceTier: serviceTier,
            inferenceGeo: inferenceGeo,
            isLongContext: catalog.chargesLongContextPremium(for: model, inputTokens: input),
            usage: usage
        )
    }
}

private struct ClaudeTranscriptLine: Decodable {
    var type: String?
    var timestamp: String?
    var requestId: String?
    var requestIDSnake: String?
    var isApiErrorMessage: Bool?
    var isSynthetic: Bool?
    var isMeta: Bool?
    var message: ClaudeTranscriptMessage?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, message
        case requestId
        case requestIDSnake = "request_id"
        case isApiErrorMessage
        case isSynthetic
        case isMeta
    }
}

private struct ClaudeTranscriptMessage: Decodable {
    var id: String?
    var model: String?
    var usage: ClaudeTranscriptUsage?
}

private struct ClaudeTranscriptUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreation: ClaudeCacheCreation?
    var inferenceGeo: String?
    var speed: String?
    var outputDetails: ClaudeOutputDetails?
    var serviceTier: String?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
        case inferenceGeo = "inference_geo"
        case speed
        case serviceTier = "service_tier"
        case outputDetails = "output_tokens_details"
    }
}

private struct ClaudeOutputDetails: Decodable {
    var thinkingTokens: Int?
    enum CodingKeys: String, CodingKey { case thinkingTokens = "thinking_tokens" }
}

private struct ClaudeCacheCreation: Decodable {
    var ephemeral5m: Int?
    var ephemeral1h: Int?

    enum CodingKeys: String, CodingKey {
        case ephemeral5m = "ephemeral_5m_input_tokens"
        case ephemeral1h = "ephemeral_1h_input_tokens"
    }
}
