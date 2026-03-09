import Foundation

struct SelfTestRunner {
    func run() async throws {
        try testTranscriptParser()
        try testRateLimitSelectorFallback()
        try testSessionLogFallback()
        try await testRepositoryPrecedence()
        try testUsageLevelThresholds()
        try testCountdownFormatting()
        try testWeeklyExhaustionState()
        try await testMockClientIntegration()
        print("All self-tests passed.")
    }

    private func testTranscriptParser() throws {
        let accountLine = #"{"id":2,"result":{"account":{"type":"chatgpt","email":"nav@example.com","planType":"plus"},"requiresOpenaiAuth":true}}"#
        let rateLine = #"{"id":3,"result":{"rateLimits":{"limitId":"fallback","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":33,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":55,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"}}}}"#

        let accountEnvelope = try AppServerLineParser.decode(AppServerAccountReadResponse.self, from: accountLine)
        let rateEnvelope = try AppServerLineParser.decode(AppServerRateLimitsResponse.self, from: rateLine)
        let selected = AppServerRateLimitSelector.selectCodexSnapshot(from: try unwrap(rateEnvelope.result, "missing rate result"))

        try expect(accountEnvelope.result?.account == AppServerAccount.chatgpt(email: "nav@example.com", planType: .plus), "parser account mismatch")
        try expect(selected.limitId == "codex", "selector did not choose codex bucket")
        try expect(selected.primary?.usedPercent == 33, "primary percent mismatch")
        try expect(selected.secondary?.usedPercent == 55, "secondary percent mismatch")
    }

    private func testRateLimitSelectorFallback() throws {
        let response = AppServerRateLimitsResponse(
            rateLimits: AppServerRateLimitSnapshot(
                limitId: "fallback",
                limitName: nil,
                primary: AppServerRateLimitWindow(usedPercent: 7, windowDurationMins: 300, resetsAt: 1),
                secondary: AppServerRateLimitWindow(usedPercent: 9, windowDurationMins: 10080, resetsAt: 2),
                planType: .pro
            ),
            rateLimitsByLimitId: nil
        )

        let selected = AppServerRateLimitSelector.selectCodexSnapshot(from: response)
        try expect(selected.limitId == "fallback", "selector fallback failed")
    }

    private func testSessionLogFallback() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/03/08", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let logURL = sessionDirectory.appendingPathComponent("rollout.jsonl")
        let log = """
        {"timestamp":"2026-03-08T20:03:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1773017651},"secondary":{"used_percent":24.0,"window_minutes":10080,"resets_at":1773533321}}}}
        """
        try Data(log.utf8).write(to: logURL)

        let source = CodexSessionLogUsageSource(sessionsRootURL: tempDirectory)
        let snapshot = try source.latestSnapshot()

        try expect(snapshot?.primary?.usedPercent == 12, "session log primary mismatch")
        try expect(snapshot?.secondary?.usedPercent == 24, "session log secondary mismatch")
        try expect(snapshot?.source == .sessionLog, "session log source mismatch")
    }

    private func testRepositoryPrecedence() async throws {
        let live = StubLiveSource(result: .success(sampleSnapshot(source: .live, stale: false, email: "live@example.com")))
        let session = StubSessionSource(snapshot: sampleSnapshot(source: .sessionLog, stale: true, email: nil))
        let repository = UsageRepository(
            liveSource: live,
            sessionLogSource: session,
            cacheStore: InMemoryStore(snapshot: sampleSnapshot(source: .cache, stale: true, email: "cache@example.com")),
            accountInfoSource: StubAccountInfoSource(snapshot: nil)
        )

        let liveSnapshot = try await repository.refresh()
        try expect(liveSnapshot.source == .live, "repository should prefer live")
        try expect(liveSnapshot.account.email == "live@example.com", "live email mismatch")

        let fallbackRepository = UsageRepository(
            liveSource: StubLiveSource(result: .failure(CodexUsageError.processFailed("boom"))),
            sessionLogSource: session,
            cacheStore: InMemoryStore(snapshot: sampleSnapshot(source: .cache, stale: true, email: "cache@example.com")),
            accountInfoSource: StubAccountInfoSource(snapshot: CodexAccountSnapshot(email: "auth@example.com", authMode: .chatgpt, planType: .plus))
        )
        let fallbackSnapshot = try await fallbackRepository.refresh()
        try expect(fallbackSnapshot.source == .sessionLog, "repository should prefer session log fallback")
        try expect(fallbackSnapshot.account.email == "cache@example.com", "fallback account enrichment failed")

        let authOnlyFallbackRepository = UsageRepository(
            liveSource: StubLiveSource(result: .failure(CodexUsageError.processFailed("boom"))),
            sessionLogSource: StubSessionSource(snapshot: sampleSnapshot(source: .sessionLog, stale: true, email: nil)),
            cacheStore: InMemoryStore(snapshot: nil),
            accountInfoSource: StubAccountInfoSource(snapshot: CodexAccountSnapshot(email: "auth@example.com", authMode: .chatgpt, planType: .plus))
        )
        let authOnlySnapshot = try await authOnlyFallbackRepository.refresh()
        try expect(authOnlySnapshot.account.email == "auth@example.com", "auth fallback account enrichment failed")
    }

    private func testUsageLevelThresholds() throws {
        try expect(UsageLevelResolver.resolve(for: nil) == .unavailable, "nil threshold mismatch")
        try expect(UsageLevelResolver.resolve(for: 69) == .normal, "69 threshold mismatch")
        try expect(UsageLevelResolver.resolve(for: 70) == .warning, "70 threshold mismatch")
        try expect(UsageLevelResolver.resolve(for: 90) == .critical, "90 threshold mismatch")
    }

    private func testCountdownFormatting() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try expect(
            UIFormatters.usageResetCountdownString(from: now.addingTimeInterval(4 * 3600 + 59 * 60), now: now) == "resets in 4 hrs 59 mins",
            "hour countdown mismatch"
        )
        try expect(
            UIFormatters.usageResetCountdownString(from: now.addingTimeInterval(6 * 24 * 3600 + 23 * 3600), now: now) == "resets in 6 days 23 hrs",
            "day countdown mismatch"
        )
        try expect(
            UIFormatters.usageResetCountdownString(from: now.addingTimeInterval(14 * 60), now: now) == "resets in 14 mins",
            "minute countdown mismatch"
        )
    }

    private func testWeeklyExhaustionState() throws {
        let snapshot = CodexUsageSnapshot(
            account: CodexAccountSnapshot(email: "nav@example.com", authMode: .chatgpt, planType: .plus),
            primary: RateLimitWindowSnapshot(usedPercent: 12, windowDurationMins: 300, resetsAt: Date()),
            secondary: RateLimitWindowSnapshot(usedPercent: 100, windowDurationMins: 10080, resetsAt: Date()),
            source: .live,
            lastUpdatedAt: Date(),
            isStale: false
        )

        try expect(snapshot.isWeeklyExhausted, "weekly exhaustion should be detected")
        try expect(snapshot.secondary?.isExhausted == true, "secondary window exhaustion mismatch")
    }

    private func testMockClientIntegration() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let scriptURL = tempDirectory.appendingPathComponent("mock-codex.sh")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"id":1'*)
              printf '%s\n' '{"id":1,"result":{"userAgent":"mock"}}'
              ;;
            *'"id":2'*)
              printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"mock@example.com","planType":"plus"},"requiresOpenaiAuth":true}}'
              ;;
            *'"id":3'*)
              printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"fallback","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":44,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":66,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"}}}}'
              ;;
          esac
        done
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let client = CodexCLIProtocolClient(
            executableLocator: StubExecutableLocator(url: scriptURL),
            arguments: [],
            timeout: 3
        )
        let snapshot = try await client.fetchUsageSnapshot()

        try expect(snapshot.account.email == "mock@example.com", "mock client email mismatch")
        try expect(snapshot.primary?.usedPercent == 44, "mock client primary mismatch")
        try expect(snapshot.secondary?.usedPercent == 66, "mock client secondary mismatch")
        try expect(snapshot.source == .live, "mock client source mismatch")
    }

    private func sampleSnapshot(source: SnapshotSource, stale: Bool, email: String?) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            account: CodexAccountSnapshot(email: email, authMode: .chatgpt, planType: .plus),
            primary: RateLimitWindowSnapshot(usedPercent: 10, windowDurationMins: 300, resetsAt: Date()),
            secondary: RateLimitWindowSnapshot(usedPercent: 20, windowDurationMins: 10080, resetsAt: Date()),
            source: source,
            lastUpdatedAt: Date(),
            isStale: stale
        )
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw CodexUsageError.invalidResponse(message)
        }
    }

    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CodexUsageError.invalidResponse(message)
        }
        return value
    }
}

private final class StubLiveSource: CodexUsageLiveSource, @unchecked Sendable {
    private let result: Result<CodexUsageSnapshot, Error>

    init(result: Result<CodexUsageSnapshot, Error>) {
        self.result = result
    }

    func fetchUsageSnapshot() async throws -> CodexUsageSnapshot {
        try result.get()
    }
}

private final class StubSessionSource: SessionLogUsageSource, @unchecked Sendable {
    private let snapshot: CodexUsageSnapshot?

    init(snapshot: CodexUsageSnapshot?) {
        self.snapshot = snapshot
    }

    func latestSnapshot() throws -> CodexUsageSnapshot? {
        snapshot
    }
}

private final class InMemoryStore: UsageSnapshotStoring, @unchecked Sendable {
    private var snapshot: CodexUsageSnapshot?

    init(snapshot: CodexUsageSnapshot?) {
        self.snapshot = snapshot
    }

    func load() throws -> CodexUsageSnapshot? {
        snapshot
    }

    func save(_ snapshot: CodexUsageSnapshot) throws {
        self.snapshot = snapshot
    }
}

private struct StubAccountInfoSource: AccountInfoSource {
    let snapshot: CodexAccountSnapshot?

    func loadAccountSnapshot() throws -> CodexAccountSnapshot? {
        snapshot
    }
}

private struct StubExecutableLocator: CodexExecutableLocating {
    let url: URL

    func findExecutableURL() throws -> URL {
        url
    }
}
