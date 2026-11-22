import Foundation

struct AntigravityQuotaBucket: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var window: RateLimitWindowSnapshot
    var disabled: Bool = false
}

struct AntigravityUsageSnapshot: Codable, Equatable, Sendable {
    var buckets: [AntigravityQuotaBucket]
    var planTier: String? = nil
    var updatedAt: Date
    var isStale: Bool

    var activeBuckets: [AntigravityQuotaBucket] {
        buckets.filter { !$0.disabled }
    }

    /// Prefer a short session/5h bucket as primary if present, else highest-used active bucket.
    var primaryBucket: AntigravityQuotaBucket? {
        activeBuckets.first(where: { $0.window.isSession }) ?? activeBuckets.first
    }

    /// Prefer a weekly bucket as secondary if distinct from primary, else the next active bucket.
    var secondaryBucket: AntigravityQuotaBucket? {
        let primaryID = primaryBucket?.id
        return activeBuckets.first(where: { $0.id != primaryID && $0.window.isWeekly })
            ?? activeBuckets.first(where: { $0.id != primaryID })
    }
}

struct AntigravityModelShare: Equatable, Identifiable {
    let modelName: String
    let sharePercent: Int
    let costUSD: Decimal
    let totalTokens: Int
    var id: String { modelName }
}

enum AntigravityConfig {
    static func cliDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["AGY_CONFIG_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity-cli", isDirectory: true)
    }

    /// All local Antigravity brain roots: Antigravity App, Antigravity CLI, and T3 Code ACP.
    static func defaultBrainRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        if let configured = environment["AGY_BRAIN_ROOTS"], !configured.isEmpty {
            return configured
                .split(separator: ":")
                .map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath, isDirectory: true) }
        }
        var roots = [
            homeDirectory.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true),
            homeDirectory.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        ]
        let t3Root = homeDirectory.appendingPathComponent(".t3/userdata/providers/antigravity", isDirectory: true)
        if let entries = try? fileManager.contentsOfDirectory(at: t3Root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                let brain = entry.appendingPathComponent("antigravity-acp/brain", isDirectory: true)
                if fileManager.fileExists(atPath: brain.path) {
                    roots.append(brain)
                }
            }
        }
        return roots
    }
}

/// Official Antigravity CLI `statusLine` bridge (`~/.gemini/antigravity-cli/settings.json`).
/// Captures `quota` bucket percentages and reset times piped by `agy` without touching credentials.
enum AntigravityStatusLine {
    private static let staleAfter: TimeInterval = 15 * 60
    private static let helperName = ".codexpeek-statusline"

    static var cacheURL: URL {
        AntigravityConfig.cliDirectory().appendingPathComponent("codexpeek-agy-usage.json")
    }

    static func capture(
        _ data: Data,
        at url: URL = cacheURL,
        now: Date = Date()
    ) throws -> AntigravityUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.rejected
        }
        guard let rawQuota = root["quota"] as? [String: Any], !rawQuota.isEmpty else {
            return nil
        }

        var buckets: [AntigravityQuotaBucket] = []
        for (bucketID, rawEntry) in rawQuota {
            guard let entry = rawEntry as? [String: Any] else { continue }
            guard let fraction = finiteNumber(entry["remaining_fraction"]),
                  (0.0...1.0).contains(fraction) else {
                continue
            }
            let usedPercent = Int(((1.0 - fraction) * 100.0).rounded())
            let resetDate: Date?
            if let iso = entry["reset_time"] as? String, let parsed = Formatters.parseISO8601(iso) {
                resetDate = parsed
            } else if let seconds = finiteNumber(entry["reset_in_seconds"]), seconds >= 0 {
                resetDate = now.addingTimeInterval(seconds)
            } else {
                resetDate = nil
            }
            let durationMins = inferredDurationMinutes(bucketID: bucketID, resetInSeconds: finiteNumber(entry["reset_in_seconds"]))
            let disabled = (entry["disabled"] as? Bool) ?? false
            buckets.append(AntigravityQuotaBucket(
                id: bucketID,
                title: displayTitle(for: bucketID),
                window: RateLimitWindowSnapshot(
                    usedPercent: min(max(usedPercent, 0), 100),
                    windowDurationMins: durationMins,
                    resetsAt: resetDate
                ),
                disabled: disabled
            ))
        }

        buckets.sort { lhs, rhs in
            let lRank = sortRank(lhs.id)
            let rRank = sortRank(rhs.id)
            if lRank != rRank { return lRank < rRank }
            return lhs.id < rhs.id
        }
        guard !buckets.isEmpty else { return nil }

        let planTier = (root["plan_tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // `/usage` has no plan tier, so keep the one an earlier statusline capture stored.
        let kept = planTier?.isEmpty == false ? planTier : readCache(url)?.planTier
        let cache = Cache(updatedAt: now, planTier: kept, buckets: buckets)
        try writeCache(cache, to: url)
        return snapshot(cache, now: now)
    }

    static func load(from url: URL = cacheURL, now: Date = Date()) throws -> AntigravityUsageSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let cache = try decoder.decode(Cache.self, from: Data(contentsOf: url))
        return snapshot(cache, now: now)
    }

    /// Reshapes `agy -p /usage --output-format json` into the statusline `quota` payload.
    static func quotaPayload(fromUsage data: Data) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = ((root["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]] else {
            throw Failure.rejected
        }
        var quota: [String: Any] = [:]
        for bucket in groups.flatMap({ $0["buckets"] as? [[String: Any]] ?? [] }) {
            guard let id = bucket["id"] as? String else { continue }
            quota[id] = ["remaining_fraction": bucket["remaining_fraction"] as Any, "reset_time": bucket["reset_time"] as Any]
        }
        return try JSONSerialization.data(withJSONObject: ["quota": quota])
    }

    /// `/usage` is a 3-10 s run of a 230 MB binary and quota only moves when agy runs, so skip it until a
    /// brain transcript changes or a cached bucket resets. `maxAge` bounds use from another device, which leaves no local trace.
    static func needsFetch(
        lastFetch: Date,
        roots: [URL] = AntigravityConfig.defaultBrainRoots(),
        cacheURL: URL = cacheURL,
        now: Date = Date(),
        maxAge: TimeInterval = 60 * 60
    ) -> Bool {
        guard let cache = readCache(cacheURL) else { return true }
        return cache.buckets.contains { ($0.window.resetsAt ?? .distantFuture) <= now }
            || now.timeIntervalSince(lastFetch) >= maxAge
            || AntigravityTokenUsageSource.transcriptFiles(in: roots).contains { $0.modifiedAt > lastFetch }
    }

    /// Restamps a reading nothing could have changed, so a skipped fetch doesn't leave it showing as stale.
    static func renew(at url: URL = cacheURL, now: Date = Date()) {
        guard var cache = readCache(url) else { return }
        cache.updatedAt = now
        try? writeCache(cache, to: url)
    }

    /// Runs the local `/usage` slash command (0 tokens, ~10 s) and stores the result like a statusline capture.
    /// The ACP server exposes no quota, so this is what keeps AGY fresh when only T3 Code is running.
    static func fetchUsage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 30
    ) async throws -> AntigravityUsageSnapshot {
        guard let executable = findCLI(environment: environment) else { throw FetchError.notFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let output = try runUsage(executable, timeout: timeout)
                    guard let snapshot = try capture(quotaPayload(fromUsage: output)) else { throw Failure.rejected }
                    continuation.resume(returning: snapshot)
                } catch {
                    continuation.resume(throwing: FetchError.failed)
                }
            }
        }
    }

    static func updateHelperIfInstalled(executableURL: URL, configDirectory: URL = AntigravityConfig.cliDirectory()) {
        let helperURL = configDirectory.appendingPathComponent(helperName)
        guard (try? isInstalled(configDirectory: configDirectory)) == true,
              let fresh = try? Data(contentsOf: executableURL),
              (try? Data(contentsOf: helperURL)) != fresh else { return }
        try? installHelper(from: executableURL, to: helperURL)
    }

    static func isInstalled(configDirectory: URL = AntigravityConfig.cliDirectory()) throws -> Bool {
        let helperURL = configDirectory.appendingPathComponent(helperName)
        guard let command = try readSettings(configDirectory.appendingPathComponent("settings.json")).command else {
            return false
        }
        return isBridgeCommand(command, helperURL: helperURL)
            && FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    static func displayTitle(for bucketID: String) -> String {
        let lower = bucketID.lowercased()
        switch lower {
        case "gemini-5h", "gemini-session": return "Gemini 5-hour"
        case "gemini-weekly": return "Gemini weekly"
        case "gemini-pro": return "Gemini Pro"
        case "gemini-flash": return "Gemini Flash"
        case "claude-5h", "claude-gpt-5h", "3p-5h": return "Claude / GPT 5-hour"
        case "claude-weekly", "claude-gpt-weekly", "3p-weekly": return "Claude / GPT weekly"
        case "gemini-argon-wtu-weekly": return "Gemini Argon weekly"
        default:
            return bucketID
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { token -> String in
                    let s = String(token)
                    if s.lowercased() == "gpt" { return "GPT" }
                    if s.lowercased() == "5h" { return "5-hour" }
                    if s.lowercased() == "7d" { return "weekly" }
                    return s.capitalized
                }
                .joined(separator: " ")
        }
    }

    enum FetchError: LocalizedError {
        case notFound, failed
        var errorDescription: String? {
            self == .notFound ? "Antigravity CLI (agy) not found" : "Could not read agy /usage"
        }
    }

    private static func findCLI(environment: [String: String]) -> URL? {
        let explicit = environment["AGY_CLI_PATH"].map { [($0 as NSString).expandingTildeInPath] } ?? []
        let dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [("~/.local/bin" as NSString).expandingTildeInPath, "/opt/homebrew/bin", "/usr/local/bin"]
        return (explicit + dirs.map { $0 + "/agy" })
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// agy writes (and rotates) one log per run, so point it at a temp file and delete that afterwards.
    /// Output goes to a file, not a pipe: a child agy spawns could hold a pipe open and block the read forever.
    private static func runUsage(_ executable: URL, timeout: TimeInterval) throws -> Data {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codexpeek-agy-\(UUID().uuidString)")
        let logFile = base.appendingPathExtension("log"), outFile = base.appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: logFile)
            try? FileManager.default.removeItem(at: outFile)
        }
        FileManager.default.createFile(atPath: outFile.path, contents: nil)
        let output = try FileHandle(forWritingTo: outFile)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json", "--log-file", logFile.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        try process.run()
        // SIGKILL, not terminate(): a wedged agy ignoring SIGTERM would hang the fetch and its spinner forever.
        let watchdog = DispatchWorkItem { kill(process.processIdentifier, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { throw FetchError.failed }
        return try Data(contentsOf: outFile)
    }

    private static func readCache(_ url: URL) -> Cache? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Cache.self, from: $0) }
    }

    private struct Cache: Codable {
        var updatedAt: Date
        var planTier: String?
        var buckets: [AntigravityQuotaBucket]
    }

    private struct SettingsFile {
        var root: [String: Any] = [:]
        var command: String?
        var existed = false
    }

    private enum Failure: LocalizedError, Equatable {
        case rejected, installFailed
        var errorDescription: String? {
            self == .rejected ? "Antigravity usage data was rejected." : "Antigravity statusline bridge could not be installed."
        }
    }

    private static func snapshot(_ cache: Cache, now: Date) -> AntigravityUsageSnapshot? {
        let liveBuckets = cache.buckets.filter { bucket in
            bucket.window.resetsAt.map { $0 > now } ?? true
        }
        guard !liveBuckets.isEmpty else { return nil }
        return AntigravityUsageSnapshot(
            buckets: liveBuckets,
            planTier: cache.planTier,
            updatedAt: cache.updatedAt,
            isStale: !(0..<staleAfter).contains(now.timeIntervalSince(cache.updatedAt))
        )
    }

    private static func inferredDurationMinutes(bucketID: String, resetInSeconds: Double?) -> Int? {
        let lower = bucketID.lowercased()
        if lower.contains("week") || lower.contains("7d") { return 10080 }
        if lower.contains("5h") || lower.contains("session") { return 300 }
        if lower.contains("day") || lower.contains("24h") { return 1440 }
        if let seconds = resetInSeconds {
            if seconds > 24 * 3600 { return 10080 }
            if seconds > 5 * 3600 { return 1440 }
            return 300
        }
        return nil
    }

    private static func sortRank(_ bucketID: String) -> Int {
        let lower = bucketID.lowercased()
        if lower.contains("gemini") && (lower.contains("5h") || lower.contains("session")) { return 0 }
        if lower.contains("gemini") && lower.contains("week") && !lower.contains("argon") { return 1 }
        if lower.contains("gemini") { return 2 }
        if lower.contains("5h") || lower.contains("session") { return 3 }
        if lower.contains("week") { return 4 }
        return 5
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func writeCache(_ cache: Cache, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(cache).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readSettings(_ url: URL) throws -> SettingsFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return SettingsFile() }
        guard let root = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure.installFailed
        }
        guard let rawStatus = root["statusLine"], !(rawStatus is NSNull) else {
            return SettingsFile(root: root, command: nil, existed: true)
        }
        guard let status = rawStatus as? [String: Any] else { throw Failure.installFailed }
        if let type = status["type"], !(type is NSNull), (type as? String) != "command" { throw Failure.installFailed }
        guard let rawCommand = status["command"], !(rawCommand is NSNull) else {
            return SettingsFile(root: root, command: nil, existed: true)
        }
        guard let command = rawCommand as? String else { throw Failure.installFailed }
        return SettingsFile(root: root, command: command, existed: true)
    }

    private static func installHelper(from source: URL, to destination: URL) throws {
        do {
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        } catch {
            throw Failure.installFailed
        }
    }

    private static func isBridgeCommand(_ command: String, helperURL: URL) -> Bool {
        let helper = shellQuote(helperURL.path) + " --agy-statusline"
        return command == helper
            || command == helper + " --quiet"
            || command.hasPrefix("codexpeek_input=$(cat; printf x); codexpeek_input=${codexpeek_input%x}; printf '%s' \"$codexpeek_input\" | " + helper + " --quiet;")
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Scans local Antigravity `transcript.jsonl` logs across Antigravity App, Antigravity CLI, and T3 Code ACP.
final class AntigravityTokenUsageSource: TokenUsageSource, @unchecked Sendable {
    private static let parserVersion = 1
    private static let relevantMarkers = [Data("\"PLANNER_RESPONSE\"".utf8)]

    private let brainRootsProvider: @Sendable () -> [URL]
    private let fileManager: FileManager
    private let pinnedCatalog: TokenPricingCatalog?
    private var pricingCatalog: TokenPricingCatalog { pinnedCatalog ?? .standard }
    private let indexStore: TokenUsageSessionIndexStoring?
    private let memo = UnchangedScanMemo()

    init(
        brainRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        pricingCatalog: TokenPricingCatalog? = nil,
        indexStore: TokenUsageSessionIndexStoring? = nil
    ) {
        if let brainRoots {
            self.brainRootsProvider = { brainRoots }
        } else {
            self.brainRootsProvider = { AntigravityConfig.defaultBrainRoots() }
        }
        self.fileManager = fileManager
        pinnedCatalog = pricingCatalog
        self.indexStore = indexStore
    }

    func usageReport() throws -> TokenUsageReport {
        let pricingCatalog = pricingCatalog
        let now = Date()
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let files = Self.transcriptFiles(in: brainRootsProvider(), fileManager: fileManager)
        if let reused = memo.report(for: files, now: now) { return reused }
        var index = (try? indexStore?.load()) ?? TokenUsageSessionIndex()
        let parserChanged = index.agyParserVersion != Self.parserVersion
        if parserChanged {
            index = TokenUsageSessionIndex()
            index.agyParserVersion = Self.parserVersion
        }
        let currentPaths = Set(files.map(\.path))
        var indexChanged = parserChanged || Set(index.sessions.keys) != currentPaths
        index.sessions = index.sessions.filter { currentPaths.contains($0.key) }

        var requestsByDedupeKey: [String: (sessionKey: String, record: UsageRequestRecord)] = [:]
        var report = TokenUsageReport.empty
        var weekModels: [String: Int] = [:]
        var monthModels: [String: Int] = [:]
        var allModels: [String: Int] = [:]
        var historyRequests: [UsageRequestRecord] = []

        for file in files {
            try Task.checkCancellation()
            let session: SessionUsage?
            if let cached = index.sessions[file.path], cached.matches(file) {
                session = cached.session
            } else {
                session = try autoreleasepool {
                    try parseTranscript(at: file.url, fallbackTimestamp: file.modifiedAt, catalog: pricingCatalog)
                }
                index.sessions[file.path] = IndexedSessionUsage(file: file, session: session)
                indexChanged = true
            }

            for (offset, request) in (session?.requests ?? []).enumerated() {
                let sessionKey = request.requestID.isEmpty ? file.path : request.requestID
                let dedupeKey = request.messageID.isEmpty
                    ? "\(file.path)#\(offset)"
                    : "\(sessionKey)\n\(request.messageID)"
                if var existing = requestsByDedupeKey[dedupeKey] {
                    if request.usage.totalTokens > existing.record.usage.totalTokens {
                        existing.record.usage = request.usage
                        existing.record.isLongContext = request.isLongContext
                    }
                    existing.record.startedAt = min(existing.record.startedAt, request.startedAt)
                    requestsByDedupeKey[dedupeKey] = existing
                } else {
                    requestsByDedupeKey[dedupeKey] = (sessionKey, request)
                }
            }
        }

        let groupedBySession = Dictionary(grouping: requestsByDedupeKey.values, by: { $0.sessionKey })
        for sessionKey in groupedBySession.keys.sorted() {
            let requests = groupedBySession[sessionKey]!.map(\.record)
            historyRequests.append(contentsOf: requests)
            let priced = requests.map { request in
                (
                    request: request,
                    model: pricingCatalog.displayModelName(for: request.model),
                    cost: pricingCatalog.estimateCost(
                        for: request.model,
                        usage: request.usage,
                        serviceTier: request.serviceTier,
                        isLongContext: request.isLongContext == true,
                        inferenceGeo: request.inferenceGeo
                    )
                )
            }
            add(priced, since: nil, to: &report.allTime, totalsByModel: &allModels)
            add(priced, since: monthCutoff, to: &report.month, totalsByModel: &monthModels)
            add(priced, since: weekCutoff, to: &report.week, totalsByModel: &weekModels)
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
        memo.remember(report, for: files)
        return report
    }

    static func modelShares(
        from report: TokenUsageReport?,
        days: Int = 7,
        now: Date = Date(),
        catalog: TokenPricingCatalog = .standard
    ) -> [AntigravityModelShare] {
        guard let buckets = report?.history?.buckets, !buckets.isEmpty else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let recent = buckets.filter { $0.startedAt >= cutoff }
        let sourceBuckets = recent.isEmpty ? buckets : recent

        var costByModel: [String: Decimal] = [:]
        var tokensByModel: [String: Int] = [:]
        for bucket in sourceBuckets {
            let name = catalog.displayModelName(for: bucket.model)
            tokensByModel[name, default: 0] += bucket.usage.totalTokens
            if let cost = catalog.estimateCost(for: bucket.model, usage: bucket.usage, isLongContext: bucket.isLongContext == true) {
                costByModel[name, default: 0] += cost.total
            }
        }

        let totalCost = costByModel.values.reduce(Decimal(0), +)
        let totalTokens = tokensByModel.values.reduce(0, +)
        guard totalTokens > 0 else { return [] }

        let totalCostDouble = NSDecimalNumber(decimal: totalCost).doubleValue
        return tokensByModel.keys.map { name in
            let cost = costByModel[name] ?? 0
            let tokens = tokensByModel[name] ?? 0
            let fraction: Double = totalCostDouble > 0
                ? NSDecimalNumber(decimal: cost).doubleValue / totalCostDouble
                : Double(tokens) / Double(totalTokens)
            return AntigravityModelShare(
                modelName: name,
                sharePercent: Int((fraction * 100.0).rounded()),
                costUSD: cost,
                totalTokens: tokens
            )
        }
        .sorted { lhs, rhs in
            if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.modelName < rhs.modelName
        }
    }

    static func transcriptFiles(in roots: [URL], fileManager: FileManager = .default) -> [SessionLogFile] {
        var files: [SessionLogFile] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path),
                  let conversations = try? fileManager.contentsOfDirectory(
                      at: root,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ) else {
                continue
            }
            for conversationDir in conversations {
                let transcriptURL = conversationDir
                    .appendingPathComponent(".system_generated", isDirectory: true)
                    .appendingPathComponent("logs", isDirectory: true)
                    .appendingPathComponent("transcript.jsonl")
                guard fileManager.fileExists(atPath: transcriptURL.path),
                      let values = try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                    continue
                }
                files.append(SessionLogFile(
                    url: transcriptURL,
                    path: transcriptURL.path,
                    size: values.fileSize ?? 0,
                    modifiedAt: values.contentModificationDate ?? .distantPast
                ))
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private func parseTranscript(at url: URL, fallbackTimestamp: Date, catalog: TokenPricingCatalog) throws -> SessionUsage? {
        // Path: .../<conversationID>/.system_generated/logs/transcript.jsonl
        let conversationID = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        let decoder = JSONDecoder()
        var requests: [UsageRequestRecord] = []

        _ = try LogLines.forEach(in: url, matching: Self.relevantMarkers) { line, lineNumber in
            guard let entry = try? decoder.decode(AntigravityTranscriptLine.self, from: line),
                  entry.type == "PLANNER_RESPONSE",
                  let rawModel = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawModel.isEmpty,
                  entry.inputTokens != nil || entry.outputTokens != nil || entry.cacheReadTokens != nil else {
                return
            }
            let uncached = max(0, entry.inputTokens ?? 0)
            let cached = max(0, entry.cacheReadTokens ?? 0)
            let output = max(0, entry.outputTokens ?? 0)
            guard uncached <= Int.max - cached else { return }
            let totalInput = uncached + cached
            guard totalInput <= Int.max - output else { return }
            let total = totalInput + output
            guard total > 0 else { return }

            let usage = TokenUsagePayload(
                inputTokens: totalInput,
                cachedInputTokens: cached,
                outputTokens: output,
                reasoningOutputTokens: 0,
                totalTokens: total
            )
            guard usage.isConsistent else { return }

            let model = TokenPricingCatalog.canonicalAntigravityModelID(rawModel)
            let timestamp = entry.createdAt.flatMap(Formatters.parseISO8601) ?? fallbackTimestamp
            let stepKey = entry.stepIndex.map { "step:\($0)" } ?? "line:\(lineNumber)"
            requests.append(UsageRequestRecord(
                messageID: stepKey,
                requestID: conversationID,
                startedAt: timestamp,
                model: model,
                serviceTier: nil,
                inferenceGeo: nil,
                isLongContext: catalog.chargesLongContextPremium(for: model, inputTokens: totalInput),
                usage: usage
            ))
        }

        return requests.isEmpty ? nil : SessionUsage(buckets: [], requests: requests)
    }

    private func historyBuckets(from requests: [UsageRequestRecord]) -> [TokenUsageBucket] {
        var buckets: [TokenUsageBucket] = []
        for request in requests.sorted(by: { $0.startedAt < $1.startedAt }) {
            let interval = Date(timeIntervalSince1970: floor(request.startedAt.timeIntervalSince1970 / 900) * 900)
            if let last = buckets.indices.last,
               buckets[last].startedAt == interval,
               buckets[last].model == request.model,
               buckets[last].isLongContext == request.isLongContext {
                buckets[last].usage.add(request.usage)
            } else {
                buckets.append(TokenUsageBucket(
                    startedAt: interval,
                    model: request.model,
                    isLongContext: request.isLongContext,
                    usage: request.usage
                ))
            }
        }
        return buckets
    }

    private func add(
        _ requests: [(request: UsageRequestRecord, model: String, cost: TokenPricingCatalog.Cost?)],
        since cutoff: Date?,
        to summary: inout TokenUsageSummary,
        totalsByModel: inout [String: Int]
    ) {
        var selected = false
        var priced = false
        for (request, model, cost) in requests {
            if let cutoff, request.startedAt < cutoff { continue }
            selected = true
            summary.inputTokens += request.usage.inputTokens
            summary.cachedInputTokens += request.usage.cachedInputTokens
            summary.outputTokens += request.usage.outputTokens
            summary.reasoningOutputTokens += request.usage.reasoningOutputTokens
            summary.totalTokens += request.usage.totalTokens
            totalsByModel[model, default: 0] += request.usage.totalTokens
            guard let cost else { continue }
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
}

private struct AntigravityTranscriptLine: Decodable {
    let stepIndex: Int?
    let type: String?
    let createdAt: String?
    let model: String?
    let inputTokens: Int?
    let cacheReadTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case type, model
        case stepIndex = "step_index"
        case createdAt = "created_at"
        case inputTokens = "input_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case outputTokens = "output_tokens"
    }
}
