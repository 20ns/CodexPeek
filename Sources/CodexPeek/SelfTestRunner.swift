import Foundation

struct SelfTestRunner {
    func run() async throws {
        try testAccountProfileStore()
        try testDuplicateProfileRecoveryCandidates()
        try testDesktopAuthStore()
        try testAuthJSONAccountInfoSource()
        try testWorkspaceStateSanitization()
        try testTranscriptParser()
        try testRateLimitSelectorFallback()
        try testFutureCodexRateLimitSelector()
        try testCurrentModelPricing()
        try testTokenUsageHistory()
        try testArchivedAndLongContextUsage()
        try testTokenCounterResetAndFork()
        try testClaudeCodeUsage()
        try testClaudeCodeTokenHistory()
        try testLegacyClaudeBackfill()
        try testUsageComparisons()
        try testSubscriptionValue()
        try testPlanUsageHistoryStore()
        try testSessionLogFallback()
        try testProfileScopedCachePaths()
        try await testRepositoryPrecedence()
        try testUsageLevelThresholds()
        try testCountdownFormatting()
        try testWeeklyExhaustionState()
        try testRateLimitWindowSemantics()
        try testWindowTitleFormatting()
        try testRateLimitBucketClassifier()
        try await testMockClientIntegration()
        try await testCodexLaunch()
        print("All self-tests passed.")
    }

    private func testTranscriptParser() throws {
        let accountLine = #"{"id":2,"result":{"account":{"type":"chatgpt","email":"nav@example.com","planType":"plus"},"requiresOpenaiAuth":true}}"#
        let rateLine = #"{"id":3,"result":{"rateLimits":{"limitId":"fallback","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":33.4,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":155,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"new-plan"},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":4,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":7,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"}}}}"#
        let unknownAccountLine = #"{"id":2,"result":{"account":{"type":"future"},"requiresOpenaiAuth":true}}"#

        let accountEnvelope = try AppServerLineParser.decode(AppServerAccountReadResponse.self, from: accountLine)
        let unknownAccountEnvelope = try AppServerLineParser.decode(AppServerAccountReadResponse.self, from: unknownAccountLine)
        let rateEnvelope = try AppServerLineParser.decode(AppServerRateLimitsResponse.self, from: rateLine)
        let rateResult = try unwrap(rateEnvelope.result, "missing rate result")
        let selected = AppServerRateLimitSelector.selectCodexSnapshot(from: rateResult)
        let spark = AppServerRateLimitSelector.selectSparkSnapshot(from: rateResult)

        let extreme = try JSONDecoder().decode(AppServerRateLimitWindow.self, from: Data(#"{"usedPercent":1e100}"#.utf8))
        try expect(extreme.usedPercent == 100, "large usage percentages should clamp without overflow")
        try expect(accountEnvelope.result?.account == AppServerAccount.chatgpt(email: "nav@example.com", planType: .plus), "parser account mismatch")
        try expect(unknownAccountEnvelope.result?.account == .unknown, "unknown account should decode without breaking refresh")
        try expect(selected.limitId == "codex", "selector did not choose codex bucket")
        try expect(selected.primary?.usedPercent == 33, "primary percent mismatch")
        try expect(selected.secondary?.usedPercent == 100, "secondary percent should clamp")
        try expect(selected.planType == .unknown, "unknown plan should decode as unknown")
        try expect(spark?.limitId == "codex_bengalfox", "selector did not choose spark bucket")
    }

    private func testFutureCodexRateLimitSelector() throws {
        let response = AppServerRateLimitsResponse(
            rateLimits: AppServerRateLimitSnapshot(limitId: "fallback", limitName: nil, primary: nil, secondary: nil, planType: nil),
            rateLimitsByLimitId: [
                "gpt-5.6": AppServerRateLimitSnapshot(limitId: "gpt-5.6", limitName: "GPT-5.6 Sol Codex", primary: nil, secondary: nil, planType: nil)
            ]
        )

        try expect(
            AppServerRateLimitSelector.selectCodexSnapshot(from: response).limitId == "gpt-5.6",
            "future Codex bucket should be selected"
        )
    }

    private func testCurrentModelPricing() throws {
        let usage = TokenUsagePayload(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 1_000_000, reasoningOutputTokens: 0, totalTokens: 2_000_000)
        let cost = try unwrap(TokenPricingCatalog.standard.estimateCost(for: "gpt-5.6-sol", usage: usage), "GPT-5.6 Sol pricing missing")
        try expect(cost.total == 24, "GPT-5.6 Sol pricing mismatch")
        let priorityCost = try unwrap(TokenPricingCatalog.standard.estimateCost(for: "gpt-5.6-sol", usage: usage, serviceTier: "priority"), "GPT-5.6 priority pricing missing")
        try expect(priorityCost.total == 48, "GPT-5.6 priority pricing mismatch")
        let gpt55PriorityCost = try unwrap(TokenPricingCatalog.standard.estimateCost(for: "gpt-5.5", usage: usage, serviceTier: "priority"), "GPT-5.5 priority pricing missing")
        try expect(gpt55PriorityCost.total == 87.5, "GPT-5.5 priority pricing mismatch")
        try expect(TokenPricingCatalog.standard.fastCreditMultiplier(for: "gpt-5.6-sol") == 2.5, "GPT-5.6 Fast credit multiplier mismatch")
        try expect(TokenPricingCatalog.standard.fastCreditMultiplier(for: "gpt-5.4") == 2, "GPT-5.4 Fast credit multiplier mismatch")
        let cachedUsage = TokenUsagePayload(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1_000_000)
        try expect(TokenPricingCatalog.standard.estimateCacheSavings(for: "gpt-5.6-sol", usage: cachedUsage) == Decimal(string: "3.6"), "cache savings mismatch")
        try expect(TokenPricingCatalog.standard.displayModelName(for: "gpt-5.6-terra-2026") == "GPT-5.6 Terra", "GPT-5.6 Terra prefix pricing missing")
        let terraCost = try unwrap(TokenPricingCatalog.standard.estimateCost(for: "gpt-5.6-terra", usage: usage), "GPT-5.6 Terra pricing missing")
        try expect(terraCost.total == 14, "GPT-5.6 Terra pricing mismatch")
        let lunaCost = try unwrap(TokenPricingCatalog.standard.estimateCost(for: "gpt-5.6-luna", usage: usage), "GPT-5.6 Luna pricing missing")
        try expect(lunaCost.total == Decimal(1.4), "GPT-5.6 Luna pricing mismatch")
        try expect(TokenPricingCatalog.standard.estimateCacheSavings(for: "gpt-5.6-luna", usage: cachedUsage) == Decimal(0.18), "GPT-5.6 Luna cache savings mismatch")
        try expect(TokenPricingCatalog.standard.estimateCost(for: "gpt-5.3-codex-spark", usage: usage) == nil, "unpriced variants should not inherit base pricing")
        let astraCost = try unwrap(TokenPricingCatalog.standard.estimateCost(for: "gpt-6-astra", usage: usage), "GPT-6 Astra pricing missing")
        try expect(astraCost.total == 60, "GPT-6 Astra pricing mismatch")
        let astraFastCost = try unwrap(TokenPricingCatalog.standard.estimateCost(for: "gpt-6-astra", usage: usage, serviceTier: "fast"), "GPT-6 Astra Fast pricing missing")
        try expect(astraFastCost.total == 120, "GPT-6 Astra Fast pricing mismatch")
        try expect(TokenPricingCatalog.standard.estimateCost(for: "gpt-6-astra-2026", usage: usage)?.total == 60, "GPT-6 Astra snapshot pricing missing")
        try expect(TokenPricingCatalog.standard.displayModelName(for: "gpt-6-astra") == "GPT-6 Astra", "GPT-6 Astra display name mismatch")
        try expect(TokenPricingCatalog.standard.fastCreditMultiplier(for: "gpt-6-astra") == 2.5, "GPT-6 Astra Fast credit multiplier mismatch")
        try expect(TokenPricingCatalog.standard.estimateCacheSavings(for: "gpt-6-astra", usage: cachedUsage) == 9, "GPT-6 Astra cache savings mismatch")
        for (model, total) in [("gpt-6.1-sol", Decimal(12)), ("gpt-6-sol", Decimal(12)), ("gpt-6-luna", Decimal(string: "0.6")!), ("gpt-5.6-cyber", Decimal(string: "87.5")!), ("gpt-5.4-nano", Decimal(string: "1.45")!)] {
            try expect(TokenPricingCatalog.standard.estimateCost(for: model, usage: usage)?.total == total, "new model pricing mismatch: \(model)")
            try expect(TokenPricingCatalog.standard.estimateCost(for: model + "-2026-10-01", usage: usage)?.total == total, "snapshot pricing mismatch: \(model)")
        }
        try expect(TokenPricingCatalog.standard.estimateCost(for: "gpt-6.1-sol", usage: cachedUsage)?.total == Decimal(string: "0.1"), "Sol 6.1 cached rate mismatch")
        try expect(TokenPricingCatalog.standard.estimateCost(for: "gpt-6.1-sol", usage: usage, serviceTier: "fast", isLongContext: true)?.total == 38, "long-context Fast pricing mismatch")
        try expect(TokenPricingCatalog.standard.estimateCost(for: "gpt-6-astra", usage: usage, serviceTier: "ultrafast")?.total == 360, "Astra Ultrafast pricing mismatch")
        try expect(TokenPricingCatalog.standard.estimateCost(for: "gpt-6-sol", usage: usage, serviceTier: "ultrafast") == nil, "unsupported tier should remain unpriced")
        try expect(UIFormatters.compactTokenString(2_106_400_000) == "2.1B", "billion token formatting mismatch")
    }

    private func testTokenUsageHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let first = formatter.string(from: Date().addingTimeInterval(-31 * 24 * 60 * 60))
        let second = formatter.string(from: Date().addingTimeInterval(-1800))
        let log = """
        {"timestamp":"\(first)","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(first)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":100}}}}
        {"timestamp":"\(first)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":30,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":160}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"service_tier":"priority"}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":50,"output_tokens":70,"reasoning_output_tokens":20,"total_tokens":250}},"rate_limits":{"plan_type":"plus"}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":50,"output_tokens":70,"reasoning_output_tokens":20,"total_tokens":250}}}}
        """
        try Data(log.utf8).write(to: root.appendingPathComponent("rollout.jsonl"))

        let child = """
        {"timestamp":"\(second)","type":"session_meta","payload":{"multi_agent_version":"v2","thread_source":"subagent"}}
        {"timestamp":"\(first)","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(first)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":30,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":160}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":50,"output_tokens":70,"reasoning_output_tokens":20,"total_tokens":250}}}}
        {"timestamp":"\(second)","type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":220,"cached_input_tokens":60,"output_tokens":90,"reasoning_output_tokens":25,"total_tokens":310}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":290,"cached_input_tokens":80,"output_tokens":110,"reasoning_output_tokens":30,"total_tokens":400}}}}
        """
        try Data(child.utf8).write(to: root.appendingPathComponent("child.jsonl"))

        let parallel = """
        {"timestamp":"\(second)","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":60,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":80},"last_token_usage":{"input_tokens":60,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":80}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":150},"last_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":50}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":90,"cached_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":0,"total_tokens":120},"last_token_usage":{"input_tokens":30,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":40}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":258400}}}}
        """
        try Data(parallel.utf8).write(to: root.appendingPathComponent("parallel.jsonl"))
        let ancient = formatter.string(from: Date().addingTimeInterval(-120 * 24 * 60 * 60))
        let ancientLog = """
        {"timestamp":"\(ancient)","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(ancient)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":10}}}}
        """
        try Data(ancientLog.utf8).write(to: root.appendingPathComponent("ancient.jsonl"))

        let indexStore = InMemoryTokenUsageIndexStore()
        let source = CodexTokenUsageSource(sessionsRootURL: root, indexStore: indexStore)
        let report = try source.usageReport()
        let buckets = try unwrap(report.history?.buckets, "token history missing")
        let daily = UsageHistoryAnalytics.dailyUsage(from: buckets, days: 2)
        let modelSummaries = UsageHistoryAnalytics.modelTotals(from: daily)
        let totals = Dictionary(uniqueKeysWithValues: modelSummaries.map { ($0.model, $0.usage.totalTokens) })

        try expect(report.allTime.totalTokens == 680, "v2 sub-agent history should exclude its copied parent usage")
        try expect(report.week.totalTokens == 510, "recent history should count unique request deltas")
        try expect(report.month.totalTokens == 510, "30-day history should exclude older usage")
        try expect(report.allTime.sessionCount == 4, "history should retain session counts")
        try expect(buckets.contains { $0.startedAt < Date().addingTimeInterval(-90 * 24 * 60 * 60) }, "chart history should retain usage older than 90 days")
        try expect(buckets.contains { $0.startedAt < Date().addingTimeInterval(-30 * 24 * 60 * 60) }, "chart history should retain prior-month comparison data")
        try expect(totals["gpt-5.4"] == 510, "model token history mismatch")
        try expect(buckets.contains { $0.serviceTier == "priority" && $0.usesChatGPTCredits == true && $0.usage.totalTokens == 90 }, "Fast usage metadata was not retained")
        try expect(daily.reduce(0) { $0 + $1.priorityTokensByModel.values.reduce(0, +) } == 90, "Fast/priority token history mismatch")
        try expect(daily.reduce(0) { $0 + $1.fastTokensByModel.values.reduce(0, +) } == 90, "Fast token history mismatch")
        try expect(modelSummaries.first { $0.model == "gpt-5.4" }?.cost == report.week.estimatedCostUSD, "history should preserve mixed service-tier pricing")
        try expect(indexStore.saveCount == 1, "session index should be saved after parsing")
        _ = try source.usageReport()
        try expect(indexStore.saveCount == 1, "unchanged session index should not be rewritten")

        let updatedParallel = parallel + """

        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":0,"output_tokens":40,"reasoning_output_tokens":0,"total_tokens":200},"last_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":50}}}}
        """
        try Data(updatedParallel.utf8).write(to: root.appendingPathComponent("parallel.jsonl"))
        let refreshed = try source.usageReport()
        try expect(refreshed.week.totalTokens == 560, "changed session logs should refresh token totals")
        try expect(refreshed.week.estimatedCostUSD > report.week.estimatedCostUSD, "changed session logs should refresh API-equivalent cost")
        try expect(indexStore.saveCount == 2, "changed session index should be rewritten")
    }

    private func testArchivedAndLongContextUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let log = """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-6.1-sol"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300000,"cached_input_tokens":100000,"output_tokens":10000,"reasoning_output_tokens":0,"total_tokens":310000},"last_token_usage":{"input_tokens":300000,"cached_input_tokens":100000,"output_tokens":10000,"reasoning_output_tokens":0,"total_tokens":310000}}}}
        """
        let active = sessions.appendingPathComponent("rollout.jsonl")
        try Data(log.utf8).write(to: active)
        let index = InMemoryTokenUsageIndexStore()
        let source = CodexTokenUsageSource(sessionsRootURL: sessions, indexStore: index)
        let before = try source.usageReport()
        try expect(before.week.totalTokens == 310_000, "long request should be recorded once")
        try expect(before.week.estimatedCostUSD == Decimal(string: "0.97"), "recording should preserve long-context prices")
        try expect(before.history?.buckets.first?.isLongContext == true, "long-context flag missing")
        let daily = UsageHistoryAnalytics.dailyUsage(from: before.history!.buckets, days: 2)
        try expect(UsageHistoryAnalytics.modelTotals(from: daily).first?.cost == before.week.estimatedCostUSD, "history should use long-context prices")
        try FileManager.default.moveItem(at: active, to: archived.appendingPathComponent("rollout.jsonl"))
        let after = try source.usageReport()
        try expect(after.allTime == before.allTime, "archiving should preserve totals with a cached index")
        let invalid = TokenUsagePayload(inputTokens: 10, cachedInputTokens: 11, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 10)
        try expect(!invalid.isConsistent, "cached tokens cannot exceed input")
        let overflowing = TokenUsagePayload(inputTokens: Int.max, cachedInputTokens: 0, outputTokens: 1, reasoningOutputTokens: 0, totalTokens: Int.max)
        try expect(!overflowing.isConsistent, "inconsistent counters should not overflow validation")
    }

    private func testTokenCounterResetAndFork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        func event(_ total: Int, last: Int? = nil, at: String? = nil) -> String {
            let latest = last.map { ",\"last_token_usage\":{\"input_tokens\":\($0),\"cached_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":\($0)}" } ?? ""
            return "{\"timestamp\":\"\(at ?? timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"cached_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":\(total)}\(latest)}}}"
        }
        let context = "{\"timestamp\":\"\(timestamp)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-6-sol\"}}"
        let reset = [context, event(100, last: 100), event(80, last: 80), event(100, last: 20), context.replacingOccurrences(of: "gpt-6-sol", with: "gpt-6-luna"), event(100, last: 20), event(120)].joined(separator: "\n")
        try Data(reset.utf8).write(to: root.appendingPathComponent("reset.jsonl"))
        var report = try CodexTokenUsageSource(sessionsRootURL: root).usageReport()
        try expect(report.allTime.totalTokens == 220, "counter reset should retain repeated totals and resume cumulative deltas")
        let copiedTime = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
        let fork = ["{\"timestamp\":\"\(timestamp)\",\"type\":\"session_meta\",\"payload\":{\"thread_source\":\"user\",\"forked_from_id\":\"parent\"}}", context, event(100, at: copiedTime), event(160, at: copiedTime), event(200, at: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30)))].joined(separator: "\n")
        try Data(fork.utf8).write(to: root.appendingPathComponent("fork.jsonl"))
        report = try CodexTokenUsageSource(sessionsRootURL: root).usageReport()
        try expect(report.allTime.totalTokens == 260, "fork should add only its own 40 tokens")
    }

    private func testClaudeCodeUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("usage.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionReset = 1_800_003_600.0
        let weekReset = 1_800_604_800.0
        let documented = #"{"session_id":"SECRET_SESSION","transcript_path":"/SECRET_TRANSCRIPT","cwd":"/SECRET_WORKSPACE","prompt":"SECRET_PROMPT","rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":\#(sessionReset)},"seven_day":{"used_percentage":41.2,"resets_at":\#(weekReset)}}}"#
        let snapshot = try unwrap(ClaudeCodeStatusLine.capture(Data(documented.utf8), at: cache, now: now), "documented rate limits")
        try expect(snapshot.fiveHour?.usedPercent == 24 && snapshot.fiveHour?.windowDurationMins == 300 && snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: sessionReset), "5h window")
        try expect(snapshot.sevenDay?.usedPercent == 41 && snapshot.sevenDay?.windowDurationMins == 10080, "7d window")
        try expect(!snapshot.isStale && snapshot.updatedAt == now, "fresh reading")
        let raw = String(decoding: try Data(contentsOf: cache), as: UTF8.self)
        let mode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber
        let decoded = try JSONDecoder().decode(ClaudeCodeUsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        try expect(!raw.contains("SECRET_") && !raw.contains("isStale") && mode?.intValue == 0o600 && decoded == snapshot, "cache keeps normalized private windows")
        let clamped = try unwrap(ClaudeCodeStatusLine.capture(Data(#"{"rate_limits":{"five_hour":{"used_percentage":140,"resets_at":\#(sessionReset)}}}"#.utf8), at: cache, now: now), "clamp")
        try expect(clamped.fiveHour?.usedPercent == 100 && clamped.sevenDay == nil, "missing windows must not inherit an old reading with a fresh timestamp")
        let expiredHundred = try ClaudeCodeStatusLine.load(from: cache, now: Date(timeIntervalSince1970: sessionReset))
        try expect(expiredHundred == nil, "an expired 100 is removed")
        let zeroReset = sessionReset + 60
        let zero = try unwrap(ClaudeCodeStatusLine.capture(Data(#"{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":\#(zeroReset)},"seven_day":null}}"#.utf8), at: cache, now: now), "zero")
        try expect(zero.fiveHour?.usedPercent == 0 && zero.sevenDay == nil, "zero is a reading and null is unknown")
        let kept = try Data(contentsOf: cache)
        let empty = try ClaudeCodeStatusLine.capture(Data(#"{}"#.utf8), at: cache, now: now)
        let missing = try ClaudeCodeStatusLine.capture(Data(#"{"rate_limits":{}}"#.utf8), at: cache, now: now)
        let stillKept = try Data(contentsOf: cache)
        try expect(empty == nil && missing == nil && stillKept == kept, "empty input leaves the cache")
        for bad in ["{", #"{"rate_limits":{"five_hour":{"used_percentage":-1,"resets_at":1}}}"#, #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":-1}}}"#, #"{"rate_limits":{"five_hour":{"used_percentage":true,"resets_at":1}}}"#, #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1e20}}}"#, #"{"rate_limits":[]}"#] {
            do { _ = try ClaudeCodeStatusLine.capture(Data(bad.utf8), at: cache, now: now) }
            catch {
                let after = try Data(contentsOf: cache)
                try expect(after == kept, "malformed input keeps the cache")
                continue
            }
            throw CodexUsageError.invalidResponse("malformed Claude usage should fail")
        }
        let recent = try ClaudeCodeStatusLine.load(from: cache, now: now.addingTimeInterval(299))
        let stale = try ClaudeCodeStatusLine.load(from: cache, now: now.addingTimeInterval(300))
        try expect(recent?.isStale == false && stale?.isStale == true && stale?.fiveHour?.usedPercent == 0, "readings go stale after 5 minutes")
        let expiredZero = try ClaudeCodeStatusLine.load(from: cache, now: Date(timeIntervalSince1970: zeroReset))
        try expect(expiredZero == nil, "an expired 0 is removed")
        try Data(#"{"updatedAt":1800000000,"fiveHour":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1e20}}"#.utf8).write(to: cache)
        let broken = try Data(contentsOf: cache)
        var rejected = false
        do { _ = try ClaudeCodeStatusLine.load(from: cache, now: now) } catch { rejected = true }
        let brokenAfter = try Data(contentsOf: cache)
        try expect(rejected && brokenAfter == broken, "a bad cache is rejected unchanged")
        let repaired = try ClaudeCodeStatusLine.capture(Data(documented.utf8), at: cache, now: now)
        try expect(repaired?.fiveHour?.usedPercent == 24, "fresh valid input must repair a corrupt cache")
        let absent = try ClaudeCodeStatusLine.load(from: root.appendingPathComponent("missing.json"), now: now)
        try expect(absent == nil, "missing cache")

        let config = root.appendingPathComponent("O'Brien Dir", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("CodexPeek")
        let helperScript = Data("#!/bin/sh\ncat >/dev/null\n".utf8)
        try helperScript.write(to: binary)
        let prior = "printf 'original\\n'; cat # preserve trailing comments"
        let settingsURL = config.appendingPathComponent("settings.json")
        let original = try JSONSerialization.data(withJSONObject: ["theme": "dark", "statusLine": ["type": "command", "command": prior, "padding": 2]])
        try original.write(to: settingsURL)
        try ClaudeCodeStatusLine.install(executableURL: binary, configDirectory: config)
        let helper = config.appendingPathComponent(".codexpeek-statusline")
        func command(at url: URL) throws -> String {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let status = root?["statusLine"] as? [String: Any]
            return try unwrap(status?["command"] as? String, "status command")
        }
        let installedCommand = try command(at: settingsURL)
        let shell = Process()
        let input = Pipe()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", installedCommand]
        shell.standardInput = input
        shell.standardOutput = output
        shell.standardError = output
        try shell.run()
        let payload = documented + "\n\n"
        try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        shell.waitUntilExit()
        try expect(shell.terminationStatus == 0 && printed == "original\n" + payload, "existing shell commands retain stdin, output and quoting")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
        let status = saved?["statusLine"] as? [String: Any]
        try expect(saved?["theme"] as? String == "dark" && status?["padding"] as? Int == 2, "other settings stay")
        let helperBytes = try Data(contentsOf: helper)
        try expect(helperBytes == helperScript, "helper is a private copy")
        let backupURL = config.appendingPathComponent("settings.json.codexpeek-backup")
        let backup = try Data(contentsOf: backupURL)
        try expect(backup == original, "backup is the first settings")
        let updatedScript = Data("#!/bin/sh\n# updated\ncat >/dev/null\n".utf8)
        try updatedScript.write(to: binary)
        try ClaudeCodeStatusLine.install(executableURL: binary, configDirectory: config)
        let reinstalled = try command(at: settingsURL)
        let refreshed = try Data(contentsOf: helper)
        let backupAgain = try Data(contentsOf: backupURL)
        let enabled = try ClaudeCodeStatusLine.isInstalled(configDirectory: config)
        try expect(reinstalled == installedCommand && refreshed == updatedScript && backupAgain == original && enabled, "reinstall does not nest")
        var missingBinaryRejected = false
        do { try ClaudeCodeStatusLine.install(executableURL: root.appendingPathComponent("missing-binary"), configDirectory: config) }
        catch { missingBinaryRejected = true }
        let helperAfterFailure = try Data(contentsOf: helper)
        try expect(missingBinaryRejected && helperAfterFailure == updatedScript, "failed helper updates retain the working executable")
        let freshConfig = root.appendingPathComponent("Fresh Dir")
        try FileManager.default.createDirectory(at: freshConfig, withIntermediateDirectories: true)
        try ClaudeCodeStatusLine.install(executableURL: binary, configDirectory: freshConfig)
        let freshHelper = freshConfig.appendingPathComponent(".codexpeek-statusline")
        let freshCommand = try command(at: freshConfig.appendingPathComponent("settings.json"))
        try expect(freshCommand == "'\(freshHelper.path)' --claude-statusline", "no prior command runs the helper")
        for bad in ["{", #"{"statusLine":["no"]}"#] {
            try Data(bad.utf8).write(to: settingsURL)
            var failed = false
            do { try ClaudeCodeStatusLine.install(executableURL: binary, configDirectory: config) } catch { failed = true }
            let untouched = try Data(contentsOf: settingsURL)
            try expect(failed && untouched == Data(bad.utf8), "invalid settings stay untouched")
        }
    }

    private func testClaudeCodeTokenHistory() throws {
        let catalog = TokenPricingCatalog.standard
        let paired = TokenUsagePayload(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 1_000_000, reasoningOutputTokens: 0, totalTokens: 2_000_000)
        let cachedOnly = TokenUsagePayload(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 1_000_000)
        let published: [(String, String, String)] = [
            ("claude-fable-5-1", "60", "0.25"),
            ("claude-mythos-5-1", "60", "0.25"),
            ("claude-opus-5-5", "24", "0.2"),
            ("claude-sonnet-5-5", "12", "0.2"),
            ("claude-fable-5", "60", "1"),
            ("claude-mythos-5", "60", "1"),
            ("claude-opus-5", "30", "0.5"),
            ("claude-opus-4-8", "30", "0.5"),
            ("claude-opus-4-7", "30", "0.5"),
            ("claude-opus-4-6", "30", "0.5"),
            ("claude-opus-4-5", "30", "0.5"),
            ("claude-opus-4-1", "90", "1.5"),
            ("claude-opus-4", "90", "1.5"),
            ("claude-sonnet-5", "12", "0.2"),
            ("claude-sonnet-4-6", "18", "0.3"),
            ("claude-sonnet-4-5", "18", "0.3"),
            ("claude-sonnet-4", "18", "0.3"),
            ("claude-haiku-4-5", "6", "0.1"),
            ("claude-haiku-3-5", "4.8", "0.08")
        ]
        for (model, total, read) in published {
            try expect(catalog.estimateCost(for: model, usage: paired)?.total == Decimal(string: total), "Claude price mismatch: \(model)")
            try expect(catalog.estimateCost(for: model + "-20261003", usage: paired)?.total == Decimal(string: total), "Claude snapshot mismatch: \(model)")
            try expect(catalog.estimateCost(for: model, usage: cachedOnly)?.cachedInput == Decimal(string: read), "Claude cache-read mismatch: \(model)")
        }
        try expect(catalog.estimateCost(for: "claude-sonnet-4-6-latest", usage: paired) == nil, "aliases should stay unpriced")
        try expect(catalog.estimateCost(for: "claude-3-5-haiku-20241022", usage: paired) == nil, "legacy ids should stay unpriced")
        try expect(catalog.estimateCost(for: "gpt-5.6-sol", usage: paired, inferenceGeo: "us")?.total == 24, "OpenAI prices should ignore US inference")
        for model in ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"] {
            let standardCost = try unwrap(catalog.estimateCost(for: model, usage: paired), "Claude price missing: \(model)")
            try expect(catalog.estimateCost(for: model, usage: paired, serviceTier: "fast")?.total == standardCost.total * 2, "Claude Fast mismatch: \(model)")
        }
        try expect(catalog.estimateCost(for: "claude-opus-4-6", usage: paired, serviceTier: "fast") == nil, "older Fast mode should stay unpriced")
        try expect(catalog.estimateCost(for: "claude-sonnet-4-5", usage: paired, serviceTier: "fast") == nil, "Sonnet Fast mode should stay unpriced")
        try expect(catalog.estimateCost(for: "claude-opus-4-8", usage: paired, serviceTier: "unpriced") == nil, "unknown speed should stay unpriced")
        try expect(catalog.estimateCost(for: "claude-opus-4-8", usage: paired, inferenceGeo: "us")?.total == Decimal(string: "33"), "US inference should be 1.1x")
        try expect(!catalog.chargesLongContextPremium(for: "claude-sonnet-4", inputTokens: 200_000), "200k is still standard context")
        try expect(catalog.chargesLongContextPremium(for: "claude-sonnet-4-5", inputTokens: 200_001), "Sonnet 4.5 above 200k is long context")
        try expect(!catalog.chargesLongContextPremium(for: "claude-sonnet-4-6", inputTokens: 300_000), "Sonnet 4.6 has no long-context premium")

        let cacheUsage = TokenUsagePayload(
            inputTokens: 3_000_000,
            cachedInputTokens: 1_000_000,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 3_000_000,
            cacheCreationInputTokens: 600_000,
            cacheCreation1hInputTokens: 400_000
        )
        let cacheCost = try unwrap(catalog.estimateCost(for: "claude-sonnet-4-6", usage: cacheUsage), "cache cost missing")
        try expect(cacheCost.uncachedInput == Decimal(string: "7.65"), "write cost should sit in uncached input")
        try expect(cacheCost.cachedInput == Decimal(string: "0.3"), "cache read cost mismatch")
        try expect(cacheCost.total == Decimal(string: "7.95"), "cache total mismatch")
        try expect(catalog.estimateCacheSavings(for: "claude-sonnet-4-6", usage: cacheUsage) == Decimal(string: "1.05"), "cache savings should subtract write premium")
        try expect(catalog.estimateCost(for: "claude-sonnet-4-6", usage: cacheUsage, inferenceGeo: "us")?.total == Decimal(string: "8.745"), "US cache pricing mismatch")
        let longUsage = TokenUsagePayload(inputTokens: 300_000, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 300_000)
        try expect(catalog.estimateCost(for: "claude-sonnet-4", usage: longUsage, isLongContext: true)?.total == Decimal(string: "1.8"), "old Sonnet long context should double input")
        try expect(catalog.estimateCost(for: "claude-sonnet-4-6", usage: longUsage, isLongContext: true)?.total == Decimal(string: "0.9"), "newer models ignore the long-context flag")
        let split = ClaudeCodeTokenUsageSource.partitionCacheWrites(aggregate: 100, ephemeral5m: 40, ephemeral1h: 30)
        try expect(split.five == 70 && split.hour == 30, "residual cache writes should be billed as 5-minute")
        try expect(ClaudeCodeTokenUsageSource.partitionCacheWrites(aggregate: 80, ephemeral5m: nil, ephemeral1h: nil).five == 80, "aggregate-only writes are 5-minute")

        let preserved = try JSONDecoder().decode(TokenUsagePayload.self, from: Data(#"{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":5}"#.utf8))
        try expect(preserved.cacheCreationInputTokens == nil && preserved.cacheCreation1hInputTokens == nil && preserved.isConsistent, "old payloads should decode without cache-write fields")
        let oldBucket = try JSONDecoder().decode(TokenUsageBucket.self, from: Data(#"{"startedAt":0,"model":"gpt-5.4","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1}}"#.utf8))
        try expect(oldBucket.inferenceGeo == nil, "old buckets should decode without inference geo")
        let oversized = TokenUsagePayload(inputTokens: 10, cachedInputTokens: 6, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 10, cacheCreationInputTokens: 5)
        try expect(!oversized.isConsistent, "cache writes plus reads cannot exceed input")

        let configured = ClaudeCodeTokenUsageSource.defaultProjectsRoot(
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-cfg"],
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        )
        try expect(configured.path == "/tmp/claude-cfg/projects", "CLAUDE_CONFIG_DIR should choose the projects root")
        let standardRoot = ClaudeCodeTokenUsageSource.defaultProjectsRoot(environment: [:], homeDirectory: URL(fileURLWithPath: "/Users/test"))
        try expect(standardRoot.path == "/Users/test/.claude/projects", "default projects root mismatch")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("proj", isDirectory: true)
        let subagents = project.appendingPathComponent("session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ days: Double, hours: Double = 0) -> String {
            formatter.string(from: Date().addingTimeInterval(-days * 24 * 60 * 60 + hours * 3600))
        }
        func line(id: String, request: String, model: String, at: String?, input: Int = 0, output: Int = 0, read: Int = 0, aggregate: Int? = nil, five: Int? = nil, hour: Int? = nil, speed: String? = nil, geo: String? = nil, reasoning: Int? = nil, tier: String? = nil) -> String {
            var usage = #"{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read)"#
            if let aggregate { usage += #","cache_creation_input_tokens":\#(aggregate)"# }
            if five != nil || hour != nil {
                usage += #","cache_creation":{"ephemeral_5m_input_tokens":\#(five ?? 0),"ephemeral_1h_input_tokens":\#(hour ?? 0)}"#
            }
            if let speed { usage += #","speed":"\#(speed)""# }
            if let tier { usage += #","service_tier":"\#(tier)""# }
            if let geo { usage += #","inference_geo":"\#(geo)""# }
            if let reasoning { usage += #","output_tokens_details":{"thinking_tokens":\#(reasoning)}"# }
            usage += "}"
            let timestamp = at.map { #""timestamp":"\#($0)","# } ?? ""
            return #"{\#(timestamp)"type":"assistant","requestId":"\#(request)","message":{"id":"\#(id)","model":"\#(model)","usage":\#(usage)}}"#
        }

        let parent = [
            #"{"type":"user","message":{"role":"user","content":"SECRET_PROMPT usage"}}"#,
            #"{"type":"assistant","isSynthetic":true,"requestId":"r-syn","message":{"id":"m-syn","model":"claude-sonnet-4-6","usage":{"input_tokens":999,"output_tokens":0}}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"requestId":"r-err","message":{"id":"m-err","model":"<synthetic>","usage":{"input_tokens":999,"output_tokens":0}}}"#,
            line(id: "m-cache", request: "r-cache", model: "claude-sonnet-4-6", at: stamp(2), input: 1_000_000, read: 1_000_000, aggregate: 1_000_000, five: 600_000, hour: 400_000),
            line(id: "m-residual", request: "r-residual", model: "claude-sonnet-4-6", at: stamp(2, hours: 1), aggregate: 100, five: 40, hour: 30),
            line(id: "m-stream", request: "r-stream", model: "claude-sonnet-4-6", at: stamp(2, hours: 2), input: 100, output: 10),
            line(id: "m-stream", request: "r-stream", model: "claude-sonnet-4-6", at: stamp(2, hours: 2), input: 100, output: 50, reasoning: 30),
            line(id: "m-stream", request: "r-stream", model: "claude-sonnet-4-6", at: stamp(2, hours: 2), input: 80, output: 20),
            line(id: "m-separate", request: "r-separate", model: "claude-sonnet-4-6", at: stamp(2, hours: 3), input: 40, output: 10),
            line(id: "m-fast", request: "r-fast", model: "claude-sonnet-4-5", at: stamp(2, hours: 5), input: 8, speed: "fast"),
            line(id: "m-turbo", request: "r-turbo", model: "claude-opus-4-8", at: stamp(2, hours: 6), input: 7, speed: "turbo"),
            line(id: "m-long", request: "r-long", model: "claude-sonnet-4", at: stamp(2, hours: 7), input: 300_000),
            line(id: "m-new", request: "r-new", model: "claude-sonnet-4-6", at: stamp(2, hours: 8), input: 300_000),
            line(id: "m-us", request: "r-us", model: "claude-opus-4-8", at: stamp(2, hours: 9), input: 1_000_000, geo: "us"),
            line(id: "m-reclassified", request: "r-reclassified", model: "claude-sonnet-4-6", at: stamp(2, hours: 11), input: 80, output: 10),
            line(id: "m-reclassified", request: "r-reclassified", model: "claude-sonnet-4-6", at: stamp(2, hours: 11), input: 30, output: 10, read: 50, tier: "Priority"),
            line(id: "m-invalid-ttl", request: "r-invalid-ttl", model: "claude-sonnet-4-6", at: stamp(2), aggregate: 1, five: 2),
            #"{"type":"assistant","message":{"id":"m-partial""#
        ].joined(separator: "\n")
        try Data(parent.utf8).write(to: project.appendingPathComponent("session.jsonl"))
        let child = [
            line(id: "m-cache", request: "r-cache", model: "claude-sonnet-4-6", at: stamp(2), input: 1_000_000, read: 1_000_000, aggregate: 1_000_000, five: 600_000, hour: 400_000),
            line(id: "m-child", request: "r-child", model: "claude-sonnet-4-6", at: stamp(2, hours: 10), input: 21)
        ].joined(separator: "\n")
        try Data(child.utf8).write(to: subagents.appendingPathComponent("agent.jsonl"))
        try Data(line(id: "m-unknown", request: "r-unknown", model: "claude-not-a-model", at: stamp(2, hours: 4), input: 11).utf8)
            .write(to: project.appendingPathComponent("unknown.jsonl"))
        try Data(line(id: "m-mid", request: "r-mid", model: "claude-sonnet-4-6", at: stamp(10), input: 70).utf8)
            .write(to: project.appendingPathComponent("mid.jsonl"))
        try Data([
            line(id: "m-old", request: "r-old", model: "claude-sonnet-4-6", at: stamp(40), input: 15),
            line(id: "m-ancient", request: "r-ancient", model: "claude-sonnet-4-6", at: stamp(120), input: 9)
        ].joined(separator: "\n").utf8).write(to: project.appendingPathComponent("old.jsonl"))
        let mtimeURL = project.appendingPathComponent("mtime.jsonl")
        try Data(line(id: "m-mtime", request: "r-mtime", model: "claude-sonnet-4-6", at: nil, input: 4).utf8).write(to: mtimeURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 24 * 60 * 60)],
            ofItemAtPath: mtimeURL.path
        )

        // A copied partial response must not hide the completed response in another file.
        try Data(line(id: "m-stream", request: "r-stream", model: "claude-sonnet-4-6", at: stamp(2, hours: 2), input: 100, output: 5).utf8)
            .write(to: project.appendingPathComponent("aaa-partial.jsonl"))
        let indexStore = InMemoryTokenUsageIndexStore()
        let source = ClaudeCodeTokenUsageSource(projectsRootURL: root, indexStore: indexStore)
        let report = try source.usageReport()
        let buckets = try unwrap(report.history?.buckets, "Claude history missing")
        let cache = 3_000_000
        let residual = 100
        let streaming = 150
        let separate = 50
        let unknown = 11
        let fast = 8
        let turbo = 7
        let long = 300_000
        let newer = 300_000
        let us = 1_000_000
        let childTokens = 21
        let week = cache + residual + streaming + separate + unknown + fast + turbo + long + newer + us + childTokens + 90
        try expect(report.week.totalTokens == week, "7-day Claude history mismatch")
        try expect(report.month.totalTokens == week + 70 + 4, "30-day Claude history mismatch")
        try expect(report.allTime.totalTokens == week + 70 + 4 + 15 + 9, "all-time Claude history mismatch")
        try expect(report.week.sessionCount == 4 && report.week.pricedSessionCount == 3, "unknown models should count without a price")
        try expect(report.month.sessionCount == 6 && report.allTime.sessionCount == 7, "historical sessions should stay in their windows")
        try expect(buckets.contains { $0.startedAt < Date().addingTimeInterval(-90 * 24 * 60 * 60) }, "Claude history should keep usage older than 90 days")
        let cacheBucket = try unwrap(buckets.first { $0.usage.cacheCreation1hInputTokens == 400_000 }, "cache bucket missing")
        try expect(cacheBucket.usage.inputTokens == 3_000_000 && cacheBucket.usage.cachedInputTokens == 1_000_000 && cacheBucket.usage.cacheCreationInputTokens == 600_000, "TTL split should not double count")
        try expect(catalog.estimateCost(for: cacheBucket.model, usage: cacheBucket.usage)?.total == Decimal(string: "7.95"), "parsed cache cost mismatch")
        let residualBucket = try unwrap(buckets.first { $0.usage.cacheCreation1hInputTokens == 30 }, "residual bucket missing")
        try expect(residualBucket.usage.cacheCreationInputTokens == 70 && residualBucket.usage.inputTokens == 100, "parsed residual TTL mismatch")
        try expect(buckets.contains { $0.usage.outputTokens == 50 && $0.usage.inputTokens == 100 && $0.usage.totalTokens == 150 }, "streaming rows should merge maxima once")
        try expect(buckets.contains { $0.usage.outputTokens == 50 && $0.usage.reasoningOutputTokens == 30 }, "reasoning must be retained inside output, never added to totals")
        let reclassified = try unwrap(buckets.first { $0.usage.cachedInputTokens == 50 }, "reclassified request missing")
        try expect(reclassified.usage.inputTokens == 80 && reclassified.usage.totalTokens == 90, "streamed cache reclassification must not inflate total input")
        try expect(catalog.estimateCost(for: reclassified.model, usage: reclassified.usage, serviceTier: reclassified.serviceTier)?.total == Decimal(string: "0.000255"), "Priority capacity must not imply Fast pricing")
        try expect(buckets.contains { $0.usage.totalTokens == 50 && $0.usage.outputTokens == 10 }, "separate requests should both count")
        try expect(buckets.contains { $0.serviceTier == "fast" && $0.usage.totalTokens == 8 }, "fast speed should map to the fast tier")
        try expect(buckets.contains { $0.serviceTier == "unpriced" && $0.usage.totalTokens == 7 }, "unavailable speed should be retained unpriced")
        try expect(buckets.contains { $0.model == "claude-not-a-model" && $0.usage.totalTokens == 11 }, "unknown models should still be counted")
        try expect(buckets.first { $0.model == "claude-sonnet-4" }?.isLongContext == true, "Sonnet 4 above 200k should be long context")
        try expect(buckets.first { $0.model == "claude-sonnet-4-6" && $0.usage.inputTokens == 300_000 }?.isLongContext != true, "Sonnet 4.6 should not take the long-context premium")
        let usBucket = try unwrap(buckets.first { $0.inferenceGeo == "us" }, "US inference bucket missing")
        try expect(catalog.estimateCost(for: usBucket.model, usage: usBucket.usage, inferenceGeo: usBucket.inferenceGeo)?.total == Decimal(string: "5.5"), "parsed US price mismatch")
        var weekCost = Decimal(0)
        for bucket in buckets where bucket.startedAt >= Date().addingTimeInterval(-7 * 24 * 60 * 60) {
            weekCost += catalog.estimateCost(for: bucket.model, usage: bucket.usage, serviceTier: bucket.serviceTier, isLongContext: bucket.isLongContext == true, inferenceGeo: bucket.inferenceGeo)?.total ?? 0
        }
        try expect(report.week.estimatedCostUSD == weekCost, "window cost should match per-request prices")
        try expect(indexStore.saveCount == 1, "Claude session index should be saved after parsing")
        let cachedIndex = try indexStore.encoded()
        try expect(!String(decoding: cachedIndex, as: UTF8.self).contains("SECRET_PROMPT"), "prompt text should not be cached")
        _ = try source.usageReport()
        try expect(indexStore.saveCount == 1, "unchanged Claude index should not be rewritten")
        let updated = parent + "\n" + line(id: "m-extra", request: "r-extra", model: "claude-sonnet-4-6", at: stamp(1), input: 5)
        try Data(updated.utf8).write(to: project.appendingPathComponent("session.jsonl"))
        let refreshed = try source.usageReport()
        try expect(refreshed.week.totalTokens == week + 5, "changed Claude logs should refresh totals")
        try expect(indexStore.saveCount == 2, "changed Claude index should be rewritten")

        let missing = try ClaudeCodeTokenUsageSource(projectsRootURL: root.appendingPathComponent("missing")).usageReport()
        try expect(missing.allTime.totalTokens == 0, "missing projects directory should be an empty report")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("broken.jsonl"), withIntermediateDirectories: true)
        do {
            _ = try ClaudeCodeTokenUsageSource(projectsRootURL: root).usageReport()
        } catch {
            return
        }
        throw CodexUsageError.invalidResponse("unreadable Claude logs should throw")
    }

    private func testLegacyClaudeBackfill() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stats-cache.json")
        let oldDate = Date().addingTimeInterval(-120 * 86400)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let stats = #"{"lastComputedDate":"\#(formatter.string(from: oldDate))","modelUsage":{"claude-sonnet-4-6":{"inputTokens":1000000,"outputTokens":1000,"cacheReadInputTokens":1000000,"cacheCreationInputTokens":1000000}}}"#
        try Data(stats.utf8).write(to: url)
        var report = TokenUsageReport.empty
        report.history = TokenUsageHistory(buckets: [])
        let filled = ClaudeLegacyUsage.backfill(report, from: url)
        try expect(filled.allTime.totalTokens == 3_001_000 && filled.allTime.estimatedCostUSD == Decimal(string: "7.065"), "legacy counts and 5m cache math mismatch")
        try expect(filled.legacyStats != nil && filled.week == .empty && filled.month == .empty, "legacy backfill must be labeled and only affect all-time")
        try expect(ClaudeLegacyUsage.backfill(filled, from: url) == filled, "legacy backfill must be idempotent")
        report.history = TokenUsageHistory(buckets: [TokenUsageBucket(startedAt: oldDate, model: "claude-sonnet-4-6", usage: .zero)])
        try expect(ClaudeLegacyUsage.backfill(report, from: url) == report, "overlapping stats must not double count")
        try Data(stats.replacingOccurrences(of: formatter.string(from: oldDate), with: formatter.string(from: Date())).utf8).write(to: url)
        report.history = TokenUsageHistory(buckets: [])
        try expect(ClaudeLegacyUsage.backfill(report, from: url) == report, "recent aggregates cannot produce exact rolling windows")
    }

    private func testUsageComparisons() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try unwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 29, hour: 12)),
            "comparison date missing"
        )
        let usage: (Int) -> TokenUsagePayload = {
            TokenUsagePayload(
                inputTokens: $0,
                cachedInputTokens: $0 / 2,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: $0
            )
        }
        let date: (Int, Int, Int) -> Date = { year, month, day in
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
        }
        var buckets = [
            TokenUsageBucket(startedAt: date(2026, 5, 31), model: "gpt-5.4", usage: usage(0)),
            TokenUsageBucket(startedAt: date(2026, 6, 5), model: "gpt-5.4", usage: usage(200)),
            TokenUsageBucket(startedAt: date(2026, 7, 5), model: "gpt-5.6-sol", usage: usage(300))
        ]
        let month = try unwrap(
            UsageHistoryAnalytics.calendarComparison(from: buckets, component: .month, now: now, calendar: calendar),
            "month comparison missing"
        )
        try expect(month.tokenChangePercent == 50, "equal-elapsed month comparison mismatch")
        try expect(month.activeDayChangePercent == 50, "active-day intensity comparison mismatch")
        try expect(month.current.contextLeverage == 2, "context leverage mismatch")

        let firstReset = date(2026, 6, 30)
        let secondReset = date(2026, 7, 30)
        let firstStart = date(2026, 6, 24)
        let firstEnd = date(2026, 6, 26)
        let secondStart = date(2026, 7, 24)
        let secondEnd = date(2026, 7, 26)
        buckets += [
            TokenUsageBucket(startedAt: firstStart.addingTimeInterval(60), model: "gpt-5.4", usesChatGPTCredits: true, usage: usage(1_000)),
            TokenUsageBucket(startedAt: secondStart.addingTimeInterval(60), model: "gpt-5.4", usesChatGPTCredits: true, usage: usage(1_500))
        ]
        let history = PlanUsageHistory(samples: [
            PlanUsageSample(recordedAt: firstStart, secondaryPercent: 10, secondaryResetsAt: firstReset),
            PlanUsageSample(recordedAt: firstEnd, secondaryPercent: 20, secondaryResetsAt: firstReset),
            PlanUsageSample(recordedAt: secondStart, secondaryPercent: 5, secondaryResetsAt: secondReset),
            PlanUsageSample(recordedAt: secondEnd, secondaryPercent: 15, secondaryResetsAt: secondReset)
        ])
        let yield = UsageHistoryAnalytics.allowanceYield(from: buckets, history: history)
        try expect(yield.current?.tokensPerPoint == 150, "current allowance yield mismatch")
        try expect(yield.previous?.tokensPerPoint == 100, "previous allowance yield mismatch")
        try expect(yield.changePercent == 50, "allowance yield comparison mismatch")

        var snapshot = sampleSnapshot(source: .live, stale: false, email: nil, lastUpdatedAt: now)
        snapshot.secondary = RateLimitWindowSnapshot(
            usedPercent: 50,
            windowDurationMins: 10_080,
            resetsAt: now.addingTimeInterval(3.5 * 24 * 60 * 60)
        )
        let pace = try unwrap(UsageHistoryAnalytics.planPace(snapshot: snapshot, now: now), "plan pace missing")
        try expect(abs(pace.multiplier - 1) < 0.001 && pace.projectedPercent == 100, "plan pace mismatch")
    }

    private func testSubscriptionValue() throws {
        try expect(CodexPlanType.go.listPriceUSD == 8, "Go list price mismatch")
        try expect(CodexPlanType.plus.listPriceUSD == 20, "Plus list price mismatch")
        try expect(CodexPlanType.prolite.listPriceUSD == 100, "Pro Lite list price mismatch")
        try expect(CodexPlanType.pro.listPriceUSD == 200, "Pro list price mismatch")
        try expect(CodexPlanType.business.listPriceUSD == 25, "Business list price mismatch")
        try expect(CodexPlanType.free.listPriceUSD == nil, "Free should have no list seat price")
        try expect(CodexPlanType.unknown.listPriceUSD == nil, "Unknown should have no list seat price")
        try expect(CodexPlanType.prolite.seatLabel == "Pro 5×", "Pro Lite seat label mismatch")
        try expect(CodexPlanType.pro.seatLabel == "Pro 20×", "Pro seat label mismatch")

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try unwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 30, hour: 18)),
            "subscription value date missing"
        )
        let day: (Int) -> Date = { offset in
            calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
                .addingTimeInterval(10 * 60 * 60)
        }
        // Sol: $4 input + $20 output per request, with reasoning already inside output.
        let heavy = TokenUsagePayload(
            inputTokens: 1_000_000,
            cachedInputTokens: 0,
            outputTokens: 1_000_000,
            reasoningOutputTokens: 250_000,
            totalTokens: 2_000_000
        )
        let light = TokenUsagePayload(
            inputTokens: 100_000,
            cachedInputTokens: 80_000,
            outputTokens: 20_000,
            reasoningOutputTokens: 0,
            totalTokens: 120_000
        )
        let buckets = [
            TokenUsageBucket(startedAt: day(-6), model: "gpt-5.6-sol", usesChatGPTCredits: true, usage: heavy),
            TokenUsageBucket(startedAt: day(-5), model: "gpt-5.6-sol", usesChatGPTCredits: true, usage: heavy),
            TokenUsageBucket(startedAt: day(-4), model: "gpt-5.6-sol", usesChatGPTCredits: true, usage: heavy),
            TokenUsageBucket(startedAt: day(-2), model: "gpt-5.6-luna", usesChatGPTCredits: false, usage: light)
        ]
        let allowance = AllowanceYieldComparison(
            current: AllowanceYieldSample(resetAt: now, tokensPerPoint: 1_000_000, observedPoints: 10),
            previous: nil
        )
        let value = UsageHistoryAnalytics.subscriptionValue(
            from: buckets,
            days: 7,
            planType: .plus,
            allowance: allowance,
            now: now,
            calendar: calendar
        )

        // Plus $20 × 7/30; three million-token Sol requests plus Luna.
        let lunaCost = try unwrap(
            TokenPricingCatalog.standard.estimateCost(for: "gpt-5.6-luna", usage: light)?.total,
            "luna cost missing"
        )
        let expectedSpend = Decimal(72) + lunaCost
        try expect(value.listPriceUSD == 20, "subscription value should use Plus list price")
        try expect(value.proratedSeatCost == Decimal(20) * Decimal(7) / Decimal(30), "prorated seat cost mismatch")
        try expect(value.apiEquivalentSpend == expectedSpend, "API-equivalent spend mismatch")
        try expect(value.openMarketMultiple.map { abs($0 - NSDecimalNumber(decimal: expectedSpend / value.proratedSeatCost!).doubleValue) < 0.001 } == true, "open-market multiple mismatch")
        try expect(value.breakEvenDayIndex == 1, "heavy day-1 spend should break even immediately")
        try expect(value.cacheRebate > 0, "cached luna usage should produce a cache rebate")
        try expect(value.reasoningTaxUSD == 15, "reasoning must use each model's output rate, without blending in Luna prices")
        try expect(value.creditModeSharePercent == 98, "credit-mode share mismatch")
        try expect(value.dollarsPerAllowancePoint != nil, "allowance dollar yield should use tokens/pt")
        try expect(value.topModelsByValue.first?.model == "gpt-5.6-sol", "top value model should be Sol")

        let unpricedPlan = UsageHistoryAnalytics.subscriptionValue(
            from: buckets,
            days: 7,
            planType: .unknown,
            allowance: AllowanceYieldComparison(current: nil, previous: nil),
            now: now,
            calendar: calendar
        )
        try expect(unpricedPlan.openMarketMultiple == nil, "unknown plan should hide ROI multiple")
        try expect(unpricedPlan.breakEvenDayIndex == nil, "unknown plan should not report break-even")

        try expect(
            UsageHistoryAnalytics.availableHistoryDays(from: buckets, now: now, calendar: calendar) == 7,
            "available history should span first bucket day through today"
        )
        try expect(
            UsageHistoryAnalytics.availableHistoryDays(from: [], now: now, calendar: calendar) == 1,
            "empty history should default to 1 day"
        )
    }

    private func testPlanUsageHistoryStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PlanUsageHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let now = Date()
        let reset = now.addingTimeInterval(24 * 60 * 60)
        var snapshot = sampleSnapshot(source: .live, stale: false, email: "history@example.com", lastUpdatedAt: now)
        snapshot.secondary = RateLimitWindowSnapshot(usedPercent: 20, windowDurationMins: 10080, resetsAt: reset)

        _ = store.record(snapshot, at: now)
        _ = store.record(snapshot, at: now.addingTimeInterval(10 * 60))
        snapshot.secondary?.usedPercent = 21
        _ = store.record(snapshot, at: now.addingTimeInterval(20 * 60))
        _ = store.record(snapshot, at: now.addingTimeInterval(2 * 60 * 60))

        let history = store.load()
        try expect(history.samples.count == 3, "plan history should deduplicate unchanged minute samples")
        try expect(history.samples.last?.secondaryPercent == 21, "plan history should persist changed usage")
    }

    private func testAccountProfileStore() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AccountProfileStore(
            stateURL: tempDirectory.appendingPathComponent("accounts.json"),
            managedProfilesRootURL: tempDirectory.appendingPathComponent("Profiles", isDirectory: true)
        )

        let initialState = try store.loadState()
        try expect(initialState.profiles.count == 1, "profile store should bootstrap default profile")
        try expect(initialState.activeProfileID == "default", "default profile should start active")
        try expect(initialState.activeProfile()?.kind == .systemDefault, "default profile kind mismatch")

        let managedState = try store.createManagedProfile(activate: true)
        try expect(managedState.profiles.count == 2, "managed profile was not added")
        try expect(managedState.activeProfile()?.kind == .managed, "managed profile should become active")

        let managedProfile = try unwrap(managedState.activeProfile(), "missing managed profile")
        try expect(FileManager.default.fileExists(atPath: managedProfile.homeURL.path), "managed profile directory missing")

        let renamedState = try store.renameProfile(id: managedProfile.id, name: "  nav@example.com  ")
        try expect(renamedState.activeProfile()?.displayName == "nav@example.com", "managed profile rename mismatch")

        let deletedState = try store.deleteManagedProfile(id: managedProfile.id)
        try expect(deletedState.profiles.count == 1, "managed profile was not removed")
        try expect(deletedState.activeProfileID == "default", "removing active managed profile should return to default")
        try expect(!FileManager.default.fileExists(atPath: managedProfile.homeURL.path), "managed profile directory was not removed")

        let secondManagedState = try store.createManagedProfile(activate: true)
        try expect(secondManagedState.profiles.count == 2, "managed profile should be addable after deletion")

        let revertedState = try store.setActiveProfileID("default")
        try expect(revertedState.activeProfileID == "default", "active profile should switch back to default")

        let tamperedRoot = tempDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: tamperedRoot, withIntermediateDirectories: true)
        let tamperedStateURL = tempDirectory.appendingPathComponent("tampered-accounts.json")
        let safeID = "11111111-1111-1111-1111-111111111111"
        let tamperedJSON = """
        {
          "activeProfileID": "\(safeID)",
          "profiles": [
            {
              "homePath": "\(tamperedRoot.path)",
              "id": "evil-default",
              "kind": "systemDefault"
            },
            {
              "homePath": "\(tamperedRoot.path)",
              "id": "\(safeID)",
              "kind": "managed"
            }
          ]
        }
        """
        try Data(tamperedJSON.utf8).write(to: tamperedStateURL)
        let tamperedStore = AccountProfileStore(
            stateURL: tamperedStateURL,
            managedProfilesRootURL: tempDirectory.appendingPathComponent("TamperedProfiles", isDirectory: true)
        )
        let normalizedTamperedState = try tamperedStore.loadState()
        try expect(
            !normalizedTamperedState.profiles.contains { $0.id == "evil-default" },
            "non-default system profiles should be dropped"
        )
        let normalizedProfile = try unwrap(
            normalizedTamperedState.profiles.first { $0.id == safeID },
            "tampered managed profile should normalize"
        )
        try expect(normalizedProfile.homePath != tamperedRoot.path, "managed profile home should not trust accounts.json")
        _ = try tamperedStore.deleteManagedProfile(id: safeID)
        try expect(FileManager.default.fileExists(atPath: tamperedRoot.path), "delete should not remove tampered external path")

        try Data("{not-json".utf8).write(to: tamperedStateURL)
        let recoveredState = try tamperedStore.loadState()
        try expect(recoveredState.activeProfileID == AccountProfileStore.defaultProfileID, "corrupt account state should recover to default")
        let quarantinedAccountFiles = try FileManager.default.contentsOfDirectory(
            at: tamperedStateURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("tampered-accounts.json.bad-") }
        try expect(!quarantinedAccountFiles.isEmpty, "corrupt account state should be quarantined")
    }

    private func testDuplicateProfileRecoveryCandidates() throws {
        let defaultProfile = AccountProfile(
            id: "default",
            name: nil,
            homePath: "/tmp/default",
            kind: .systemDefault
        )
        let activeManagedProfile = AccountProfile(
            id: "managed-a",
            name: "Managed A",
            homePath: "/tmp/managed-a",
            kind: .managed
        )
        let duplicateManagedProfile = AccountProfile(
            id: "managed-b",
            name: "Managed B",
            homePath: "/tmp/managed-b",
            kind: .managed
        )
        let unrelatedProfile = AccountProfile(
            id: "managed-c",
            name: "Managed C",
            homePath: "/tmp/managed-c",
            kind: .managed
        )

        let state = AccountProfilesState(
            profiles: [activeManagedProfile, unrelatedProfile, defaultProfile, duplicateManagedProfile],
            activeProfileID: activeManagedProfile.id
        )
        let snapshotsByProfileID: [String: CodexAccountSnapshot] = [
            defaultProfile.id: CodexAccountSnapshot(email: "nav@example.com", authMode: .chatgpt, planType: .plus),
            activeManagedProfile.id: CodexAccountSnapshot(email: "nav@example.com", authMode: .chatgpt, planType: .plus),
            duplicateManagedProfile.id: CodexAccountSnapshot(email: "nav@example.com", authMode: .chatgpt, planType: .plus),
            unrelatedProfile.id: CodexAccountSnapshot(email: "other@example.com", authMode: .chatgpt, planType: .pro)
        ]

        let candidates = DuplicateProfileRecovery.candidateProfiles(
            from: state,
            activeProfile: activeManagedProfile,
            snapshotsByProfileID: snapshotsByProfileID
        )

        try expect(
            candidates.map(\.id) == [defaultProfile.id, duplicateManagedProfile.id],
            "duplicate recovery should prioritize the default profile"
        )

        let keeper = DuplicateProfileRecovery.keeper(
            for: activeManagedProfile,
            snapshot: snapshotsByProfileID[activeManagedProfile.id]!,
            in: state,
            snapshotsByProfileID: snapshotsByProfileID,
            pendingCreatedProfileIDs: [activeManagedProfile.id]
        )
        try expect(keeper?.id == defaultProfile.id, "duplicate keeper should reuse the existing default profile")
    }

    private func testDesktopAuthStore() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let systemHomeURL = tempDirectory.appendingPathComponent("system-home", isDirectory: true)
        let defaultSnapshotURL = tempDirectory.appendingPathComponent("default-snapshot/auth.json")
        let ownerStateURL = tempDirectory.appendingPathComponent("desktop-auth-owner.json")
        let managedHomeURL = tempDirectory.appendingPathComponent("managed-home", isDirectory: true)

        try FileManager.default.createDirectory(at: systemHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedHomeURL, withIntermediateDirectories: true)

        let systemAuthURL = systemHomeURL.appendingPathComponent("auth.json")
        let managedAuthURL = managedHomeURL.appendingPathComponent("auth.json")
        let defaultAuth = authDocument(email: "default@example.com", marker: "default")
        let managedAuth = authDocument(email: "managed@example.com", marker: "managed")
        let managedRefreshedAuth = authDocument(email: "managed@example.com", marker: "managed-refreshed")
        let defaultRefreshedAuth = authDocument(email: "default@example.com", marker: "default-refreshed")

        try Data(defaultAuth.utf8).write(to: systemAuthURL)
        try Data(managedAuth.utf8).write(to: managedAuthURL)

        let store = CodexDesktopAuthStore(
            fileManager: .default,
            systemHomeURL: systemHomeURL,
            defaultSnapshotURL: defaultSnapshotURL,
            ownerStateURL: ownerStateURL
        )

        try store.bootstrapDefaultSnapshotIfNeeded()
        let bootstrappedSnapshot = try String(contentsOf: defaultSnapshotURL, encoding: .utf8)
        try expect(bootstrappedSnapshot == defaultAuth, "default auth snapshot bootstrap mismatch")

        let managedProfile = AccountProfile(
            id: "managed",
            name: "Managed",
            homePath: managedHomeURL.path,
            kind: .managed
        )
        let managedChanged = try store.prepareSystemAuth(for: managedProfile)
        try expect(managedChanged, "managed auth should replace system auth")
        let managedSystemAuth = try String(contentsOf: systemAuthURL, encoding: .utf8)
        try expect(managedSystemAuth == managedAuth, "managed auth was not copied into system home")
        try Data(managedRefreshedAuth.utf8).write(to: systemAuthURL)
        try store.reconcileSystemAuth(among: [managedProfile])
        let persistedManagedAuth = try String(contentsOf: managedAuthURL, encoding: .utf8)
        try expect(persistedManagedAuth == managedRefreshedAuth, "refreshed desktop auth should persist back to managed profile")

        let shouldSyncBorrowedDefault = try store.shouldSyncDefaultSnapshotFromSystemAuth(among: [managedProfile])
        try expect(!shouldSyncBorrowedDefault, "borrowed managed auth should not overwrite the default snapshot")
        let displayAuthURL = try store.accountInfoURL(
            for: AccountProfile(id: "default", name: nil, homePath: systemHomeURL.path, kind: .systemDefault),
            among: [managedProfile]
        )
        try expect(displayAuthURL == defaultSnapshotURL, "default profile should read from its saved snapshot while auth is borrowed")

        let defaultProfile = AccountProfile(
            id: "default",
            name: nil,
            homePath: systemHomeURL.path,
            kind: .systemDefault
        )
        let defaultChanged = try store.prepareSystemAuth(for: defaultProfile, among: [managedProfile])
        try expect(defaultChanged, "default auth should restore system auth")
        let restoredSystemAuth = try String(contentsOf: systemAuthURL, encoding: .utf8)
        try expect(restoredSystemAuth == defaultAuth, "default auth restore mismatch")
        try Data(defaultRefreshedAuth.utf8).write(to: systemAuthURL)
        try store.reconcileSystemAuth(among: [managedProfile])
        let refreshedDefaultSnapshot = try String(contentsOf: defaultSnapshotURL, encoding: .utf8)
        try expect(refreshedDefaultSnapshot == defaultRefreshedAuth, "refreshed default auth should persist to default snapshot")

        _ = try store.prepareSystemAuth(for: managedProfile, among: [managedProfile])
        try store.clearPersistedAuth(for: managedProfile, among: [managedProfile])
        try expect(!FileManager.default.fileExists(atPath: managedAuthURL.path), "managed auth should be removed on clean logout")
        let restoredDefaultAfterManagedClear = try String(contentsOf: systemAuthURL, encoding: .utf8)
        try expect(restoredDefaultAfterManagedClear == defaultRefreshedAuth, "managed clean logout should restore default desktop auth")

        try store.clearPersistedAuth(for: defaultProfile, among: [managedProfile])
        try expect(!FileManager.default.fileExists(atPath: defaultSnapshotURL.path), "default auth snapshot should be removed on clean logout")

        try Data(defaultAuth.utf8).write(to: defaultSnapshotURL)
        try FileManager.default.removeItem(at: systemAuthURL)
        try store.syncDefaultSnapshotFromSystemAuth()
        try expect(FileManager.default.fileExists(atPath: defaultSnapshotURL.path), "missing system auth should not delete default snapshot")

        try FileManager.default.removeItem(at: defaultSnapshotURL)
        try Data(managedAuth.utf8).write(to: systemAuthURL)
        let missingDefaultStore = CodexDesktopAuthStore(
            fileManager: .default,
            systemHomeURL: systemHomeURL,
            defaultSnapshotURL: defaultSnapshotURL,
            ownerStateURL: tempDirectory.appendingPathComponent("missing-default-owner.json")
        )
        do {
            _ = try missingDefaultStore.prepareSystemAuth(for: defaultProfile, among: [managedProfile])
            throw CodexUsageError.invalidResponse("missing default snapshot should prevent default switch")
        } catch CodexUsageError.invalidResponse {
            let preservedSystemAuth = try String(contentsOf: systemAuthURL, encoding: .utf8)
            try expect(preservedSystemAuth == managedAuth, "failed default switch should not alter system auth")
        }

        let borrowedDefaultURL = tempDirectory.appendingPathComponent("borrowed-default/auth.json")
        let borrowedOwnerURL = tempDirectory.appendingPathComponent("borrowed-owner.json")
        try Data(managedAuth.utf8).write(to: systemAuthURL)
        try Data(#"{"profileID":"managed"}"#.utf8).write(to: borrowedOwnerURL)
        let borrowedStore = CodexDesktopAuthStore(
            fileManager: .default,
            systemHomeURL: systemHomeURL,
            defaultSnapshotURL: borrowedDefaultURL,
            ownerStateURL: borrowedOwnerURL
        )
        try borrowedStore.reconcileSystemAuth(among: [managedProfile])
        try expect(
            !FileManager.default.fileExists(atPath: borrowedDefaultURL.path),
            "borrowed managed auth should not bootstrap a default snapshot"
        )

        let staleBorrowedOwnerURL = tempDirectory.appendingPathComponent("stale-borrowed-owner.json")
        let staleBorrowedDefaultURL = tempDirectory.appendingPathComponent("stale-borrowed-default/auth.json")
        try Data(managedAuth.utf8).write(to: systemAuthURL)
        try Data(#"{"profileID":"removed-managed"}"#.utf8).write(to: staleBorrowedOwnerURL)
        let staleBorrowedStore = CodexDesktopAuthStore(
            fileManager: .default,
            systemHomeURL: systemHomeURL,
            defaultSnapshotURL: staleBorrowedDefaultURL,
            ownerStateURL: staleBorrowedOwnerURL
        )
        try staleBorrowedStore.reconcileSystemAuth(among: [])
        try expect(
            !FileManager.default.fileExists(atPath: staleBorrowedDefaultURL.path),
            "stale borrowed owner should not relabel system auth as default"
        )
        let shouldSyncStaleBorrowedDefault = try staleBorrowedStore.shouldSyncDefaultSnapshotFromSystemAuth(among: [])
        try expect(!shouldSyncStaleBorrowedDefault, "stale borrowed owner should block default snapshot sync")

        let mismatchedOwnerURL = tempDirectory.appendingPathComponent("mismatched-owner.json")
        let mismatchedDefaultURL = tempDirectory.appendingPathComponent("mismatched-default/auth.json")
        try Data(defaultAuth.utf8).write(to: managedAuthURL)
        try Data(managedRefreshedAuth.utf8).write(to: systemAuthURL)
        try Data(#"{"profileID":"managed"}"#.utf8).write(to: mismatchedOwnerURL)
        let mismatchedOwnerStore = CodexDesktopAuthStore(
            fileManager: .default,
            systemHomeURL: systemHomeURL,
            defaultSnapshotURL: mismatchedDefaultURL,
            ownerStateURL: mismatchedOwnerURL
        )
        try mismatchedOwnerStore.reconcileSystemAuth(among: [managedProfile])
        try expect(
            !FileManager.default.fileExists(atPath: mismatchedDefaultURL.path),
            "mismatched borrowed owner should not relabel system auth as default"
        )
        let shouldSyncMismatchedBorrowedDefault = try mismatchedOwnerStore.shouldSyncDefaultSnapshotFromSystemAuth(among: [managedProfile])
        try expect(!shouldSyncMismatchedBorrowedDefault, "mismatched borrowed owner should block default snapshot sync")

        try Data("{not-json".utf8).write(to: borrowedOwnerURL)
        try borrowedStore.reconcileSystemAuth(among: [managedProfile])
        try expect(
            !FileManager.default.fileExists(atPath: borrowedDefaultURL.path),
            "corrupt owner state should not relabel system auth as default"
        )
        let shouldSyncCorruptBorrowedDefault = try borrowedStore.shouldSyncDefaultSnapshotFromSystemAuth(among: [managedProfile])
        try expect(!shouldSyncCorruptBorrowedDefault, "corrupt owner state should block default snapshot sync")
        let quarantinedOwnerFiles = try FileManager.default.contentsOfDirectory(
            at: borrowedOwnerURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("borrowed-owner.json.bad-") }
        try expect(!quarantinedOwnerFiles.isEmpty, "corrupt owner state should be quarantined")
    }

    private func testWorkspaceStateSanitization() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existingWorkspaceURL = tempDirectory.appendingPathComponent("existing-workspace", isDirectory: true)
        let missingWorkspacePath = tempDirectory.appendingPathComponent("missing-workspace", isDirectory: true).path
        let globalStateURL = tempDirectory.appendingPathComponent(".codex-global-state.json")

        try FileManager.default.createDirectory(at: existingWorkspaceURL, withIntermediateDirectories: true)

        let globalState: [String: Any] = [
            "electron-saved-workspace-roots": [existingWorkspaceURL.path, missingWorkspacePath],
            "active-workspace-roots": [missingWorkspacePath, existingWorkspaceURL.path],
            "electron-workspace-root-labels": [
                existingWorkspaceURL.path: "Existing",
                missingWorkspacePath: "Missing"
            ],
            "electron-persisted-atom-state": [
                "sidebar-collapsed-groups": [
                    existingWorkspaceURL.path: true,
                    missingWorkspacePath: true
                ]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: globalState, options: [.sortedKeys])
        try data.write(to: globalStateURL)

        let store = CodexWorkspaceStateStore(
            fileManager: .default,
            globalStateURL: globalStateURL
        )
        let result = try store.sanitizePersistedWorkspaceState()

        try expect(result.removedWorkspacePaths == [missingWorkspacePath], "workspace sanitizer should report removed stale paths")

        let sanitizedData = try Data(contentsOf: globalStateURL)
        let sanitizedState = try unwrap(
            JSONSerialization.jsonObject(with: sanitizedData) as? [String: Any],
            "missing sanitized workspace state"
        )
        let savedRoots = try unwrap(sanitizedState["electron-saved-workspace-roots"] as? [String], "missing saved roots")
        let activeRoots = try unwrap(sanitizedState["active-workspace-roots"] as? [String], "missing active roots")
        let labels = try unwrap(sanitizedState["electron-workspace-root-labels"] as? [String: String], "missing labels")
        let atomState = try unwrap(sanitizedState["electron-persisted-atom-state"] as? [String: Any], "missing atom state")
        let collapsedGroups = try unwrap(atomState["sidebar-collapsed-groups"] as? [String: Bool], "missing collapsed groups")

        try expect(savedRoots == [existingWorkspaceURL.path], "saved roots should keep only existing workspaces")
        try expect(activeRoots == [existingWorkspaceURL.path], "active roots should keep only existing workspaces")
        try expect(labels == [existingWorkspaceURL.path: "Existing"], "workspace labels should drop stale entries")
        try expect(collapsedGroups == [existingWorkspaceURL.path: true], "collapsed groups should drop stale entries")
    }

    private func testAuthJSONAccountInfoSource() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let authURL = tempDirectory.appendingPathComponent("auth.json")
        let payload = """
        {
          "sub": "acct_123",
          "email": "renew@example.com",
          "https://api.openai.com/auth": {
            "chatgpt_plan_type": "plus",
            "chatgpt_subscription_active_until": "2026-04-19T09:33:13+00:00"
          }
        }
        """
        let document = """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "id_token": "\(makeJWT(payloadJSON: payload))"
          }
        }
        """
        try Data(document.utf8).write(to: authURL)

        let source = AuthJSONAccountInfoSource(authURL: authURL, fileManager: .default)
        let snapshot = try unwrap(source.loadAccountSnapshot(), "auth snapshot missing")

        try expect(snapshot.email == "renew@example.com", "auth email mismatch")
        try expect(snapshot.accountID == "acct_123", "auth subject mismatch")
        try expect(snapshot.planType == .plus, "auth plan mismatch")
        try expect(
            snapshot.renewsAt == Formatters.parseISO8601("2026-04-19T09:33:13+00:00"),
            "auth renewal mismatch"
        )
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
        try expect(AppServerRateLimitSelector.selectSparkSnapshot(from: response) == nil, "spark selector should fall back to nil")
    }

    private func testSessionLogFallback() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionDirectory = tempDirectory
            .appendingPathComponent("2026/03/08", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let logURL = sessionDirectory.appendingPathComponent("rollout.jsonl")
        let partialLinePrefix = String(repeating: "x", count: 210_000)
        let log = """
        \(partialLinePrefix)
        {"timestamp":"2026-03-08T20:03:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1773017651},"secondary":{"used_percent":24.0,"window_minutes":10080,"resets_at":1773533321}}}}
        """
        try Data(log.utf8).write(to: logURL)

        let source = CodexSessionLogUsageSource(sessionsRootURL: tempDirectory)
        let snapshot = try source.latestSnapshot()

        try expect(snapshot?.primary?.usedPercent == 12, "session log primary mismatch")
        try expect(snapshot?.secondary?.usedPercent == 24, "session log secondary mismatch")
        try expect(snapshot?.source == .sessionLog, "session log source mismatch")

        let sparkDirectory = tempDirectory.appendingPathComponent("2026/03/09", isDirectory: true)
        try FileManager.default.createDirectory(at: sparkDirectory, withIntermediateDirectories: true)
        let sparkLogURL = sparkDirectory.appendingPathComponent("spark.jsonl")
        let logWithSpark = """
        {"timestamp":"2026-03-09T20:01:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":31.0,"window_minutes":10080,"resets_at":1773533321}}}}
        {"timestamp":"2026-03-09T20:02:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1773017651},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1773533321}}}}
        """
        try Data(logWithSpark.utf8).write(to: sparkLogURL)
        let sparkSource = CodexSessionLogUsageSource(sessionsRootURL: tempDirectory)
        let sparkSnapshot = try sparkSource.latestSnapshot()
        try expect(sparkSnapshot?.primary?.usedPercent == 31, "should prefer codex limit over spark for primary")
        try expect(sparkSnapshot?.spark?.primary?.usedPercent == 0, "should map spark limits to spark snapshot")
    }

    private func testProfileScopedCachePaths() throws {
        let defaultCache = SnapshotCacheStore.defaultCacheURL(profileID: "default")
        let altCache = SnapshotCacheStore.defaultCacheURL(profileID: "alt")

        try expect(defaultCache != altCache, "cache paths should differ per profile")
        try expect(defaultCache.lastPathComponent == "default.json", "default cache filename mismatch")
        try expect(altCache.lastPathComponent == "alt.json", "alternate cache filename mismatch")
    }

    private func testRepositoryPrecedence() async throws {
        let live = StubLiveSource(result: .success(sampleSnapshot(source: .live, stale: false, email: "live@example.com")))
        let session = StubSessionSource(snapshot: sampleSnapshot(source: .sessionLog, stale: true, email: nil))
        let oldDate = Date(timeIntervalSince1970: 1_800_000_000)
        let newDate = oldDate.addingTimeInterval(60)
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
            sessionLogSource: StubSessionSource(
                snapshot: sampleSnapshot(source: .sessionLog, stale: true, email: nil, lastUpdatedAt: newDate)
            ),
            cacheStore: InMemoryStore(
                snapshot: sampleSnapshot(source: .cache, stale: true, email: "cache@example.com", lastUpdatedAt: oldDate)
            ),
            accountInfoSource: StubAccountInfoSource(
                snapshot: CodexAccountSnapshot(
                    email: "auth@example.com",
                    authMode: .chatgpt,
                    planType: .plus,
                    renewsAt: Formatters.parseISO8601("2026-04-19T09:33:13+00:00")
                )
            )
        )
        let fallbackSnapshot = try await fallbackRepository.refresh()
        try expect(fallbackSnapshot.source == .sessionLog, "repository should prefer session log fallback")
        try expect(fallbackSnapshot.account.email == "cache@example.com", "fallback account enrichment failed")
        try expect(
            fallbackSnapshot.account.renewsAt == Formatters.parseISO8601("2026-04-19T09:33:13+00:00"),
            "fallback renewal enrichment failed"
        )

        let fresherLiveCacheRepository = UsageRepository(
            liveSource: StubLiveSource(result: .failure(CodexUsageError.processFailed("boom"))),
            sessionLogSource: StubSessionSource(
                snapshot: sampleSnapshot(source: .sessionLog, stale: true, email: nil, lastUpdatedAt: oldDate)
            ),
            cacheStore: InMemoryStore(
                snapshot: sampleSnapshot(source: .live, stale: false, email: "cache@example.com", lastUpdatedAt: newDate)
            ),
            accountInfoSource: StubAccountInfoSource(snapshot: nil)
        )
        let fresherLiveCacheSnapshot = try await fresherLiveCacheRepository.refresh()
        try expect(fresherLiveCacheSnapshot.source == .cache, "newer live cache should beat older session fallback")

        let noSessionFallbackRepository = UsageRepository(
            liveSource: StubLiveSource(result: .failure(CodexUsageError.processFailed("boom"))),
            sessionLogSource: StubSessionSource(snapshot: nil),
            cacheStore: InMemoryStore(
                snapshot: sampleSnapshot(source: .live, stale: false, email: "cache@example.com", lastUpdatedAt: newDate)
            ),
            accountInfoSource: StubAccountInfoSource(snapshot: nil)
        )
        let noSessionFallbackSnapshot = try await noSessionFallbackRepository.refresh()
        try expect(noSessionFallbackSnapshot.source == .cache, "missing session fallback must not relabel cache as session log")

        let throwingSessionFallbackRepository = UsageRepository(
            liveSource: StubLiveSource(result: .failure(CodexUsageError.processFailed("boom"))),
            sessionLogSource: ThrowingSessionSource(),
            cacheStore: InMemoryStore(
                snapshot: sampleSnapshot(source: .live, stale: false, email: "cache@example.com", lastUpdatedAt: newDate)
            ),
            accountInfoSource: StubAccountInfoSource(snapshot: nil)
        )
        let throwingSessionFallbackSnapshot = try await throwingSessionFallbackRepository.refresh()
        try expect(throwingSessionFallbackSnapshot.source == .cache, "thrown session fallback should still return cache")

        let authOnlyFallbackRepository = UsageRepository(
            liveSource: StubLiveSource(result: .failure(CodexUsageError.processFailed("boom"))),
            sessionLogSource: StubSessionSource(snapshot: sampleSnapshot(source: .sessionLog, stale: true, email: nil)),
            cacheStore: InMemoryStore(snapshot: nil),
            accountInfoSource: StubAccountInfoSource(
                snapshot: CodexAccountSnapshot(
                    email: "auth@example.com",
                    authMode: .chatgpt,
                    planType: .plus,
                    renewsAt: Formatters.parseISO8601("2026-04-19T09:33:13+00:00")
                )
            )
        )
        let authOnlySnapshot = try await authOnlyFallbackRepository.refresh()
        try expect(authOnlySnapshot.account.email == "auth@example.com", "auth fallback account enrichment failed")
        try expect(
            authOnlySnapshot.account.renewsAt == Formatters.parseISO8601("2026-04-19T09:33:13+00:00"),
            "auth-only renewal enrichment failed"
        )
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

        let singleWindow = CodexUsageSnapshot(
            account: CodexAccountSnapshot(email: "nav@example.com", authMode: .chatgpt, planType: .prolite),
            primary: RateLimitWindowSnapshot(usedPercent: 100, windowDurationMins: 10080, resetsAt: Date()),
            secondary: nil,
            source: .live,
            lastUpdatedAt: Date(),
            isStale: false
        )
        try expect(singleWindow.isWeeklyExhausted, "single weekly window exhaustion should be detected")
    }

    private func testRateLimitWindowSemantics() throws {
        let twoWindow = CodexUsageSnapshot(
            account: .empty,
            primary: RateLimitWindowSnapshot(usedPercent: 20, windowDurationMins: 300, resetsAt: nil),
            secondary: RateLimitWindowSnapshot(usedPercent: 40, windowDurationMins: 10080, resetsAt: nil),
            source: .live,
            lastUpdatedAt: Date(),
            isStale: false
        )
        try expect(twoWindow.sessionWindow?.usedPercent == 20, "2-window sessionWindow mismatch")
        try expect(twoWindow.weeklyWindow?.usedPercent == 40, "2-window weeklyWindow mismatch")
        try expect(!twoWindow.isWeeklyExhausted, "2-window should not be exhausted")

        let singleWeekly = CodexUsageSnapshot(
            account: .empty,
            primary: RateLimitWindowSnapshot(usedPercent: 100, windowDurationMins: 10080, resetsAt: nil),
            secondary: nil,
            source: .live,
            lastUpdatedAt: Date(),
            isStale: false
        )
        try expect(singleWeekly.sessionWindow == nil, "single weekly plan should have no sessionWindow")
        try expect(singleWeekly.weeklyWindow?.usedPercent == 100, "single weekly plan weeklyWindow mismatch")
        try expect(singleWeekly.isWeeklyExhausted, "single weekly plan at 100% should be weekly exhausted")

        let singleSession = CodexUsageSnapshot(
            account: .empty,
            primary: RateLimitWindowSnapshot(usedPercent: 50, windowDurationMins: 300, resetsAt: nil),
            secondary: nil,
            source: .live,
            lastUpdatedAt: Date(),
            isStale: false
        )
        try expect(singleSession.sessionWindow?.usedPercent == 50, "single session plan sessionWindow mismatch")
        try expect(singleSession.weeklyWindow == nil, "single session plan should have no weeklyWindow")
        try expect(!singleSession.isWeeklyExhausted, "single session plan should not be weekly exhausted")
    }

    private func testWindowTitleFormatting() throws {
        let fiveHour = RateLimitWindowSnapshot(usedPercent: 10, windowDurationMins: 300, resetsAt: nil)
        let weekly = RateLimitWindowSnapshot(usedPercent: 20, windowDurationMins: 10080, resetsAt: nil)
        let oneHour = RateLimitWindowSnapshot(usedPercent: 5, windowDurationMins: 60, resetsAt: nil)
        let twoDay = RateLimitWindowSnapshot(usedPercent: 15, windowDurationMins: 2880, resetsAt: nil)
        let nilWindow: RateLimitWindowSnapshot? = nil

        try expect(UIFormatters.rateLimitWindowTitle(for: fiveHour) == "5-hour window", "5-hour window title mismatch")
        try expect(UIFormatters.rateLimitWindowTitle(for: weekly) == "Weekly window", "weekly window title mismatch")
        try expect(UIFormatters.rateLimitWindowTitle(for: oneHour) == "1-hour window", "1-hour window title mismatch")
        try expect(UIFormatters.rateLimitWindowTitle(for: twoDay) == "2-day window", "2-day window title mismatch")
        try expect(UIFormatters.rateLimitWindowTitle(for: nilWindow, fallback: "Custom") == "Custom", "fallback title mismatch")
    }

    private func testRateLimitBucketClassifier() throws {
        try expect(RateLimitBucketClassifier.isSpark(limitID: "codex_bengalfox", limitName: "GPT-5.3-Codex-Spark"), "bengalfox should be spark")
        try expect(RateLimitBucketClassifier.isSpark(limitID: "spark-preview", limitName: nil), "spark id should be spark")
        try expect(!RateLimitBucketClassifier.isSpark(limitID: "codex", limitName: nil), "codex should not be spark")

        try expect(RateLimitBucketClassifier.isCodex(limitID: "codex", limitName: nil), "codex id should be codex")
        try expect(RateLimitBucketClassifier.isCodex(limitID: nil, limitName: "Codex Plus"), "codex name should be codex")
        try expect(RateLimitBucketClassifier.isCodex(limitID: nil, limitName: nil), "nil bucket should default to codex")
        try expect(!RateLimitBucketClassifier.isCodex(limitID: "codex_bengalfox", limitName: "GPT-5.3-Codex-Spark"), "spark should not be codex")
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
              printf '%s\n' 'not-json'
              printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"mock@example.com","planType":"plus"},"requiresOpenaiAuth":true}}'
              ;;
            *'"id":3'*)
              printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"fallback","primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":44,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":66,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"},"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1773017651},"secondary":{"usedPercent":22,"windowDurationMins":10080,"resetsAt":1773533321},"planType":"plus"}}}}'
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
        try expect(snapshot.spark?.title == "5.3 Spark", "mock client spark title mismatch")
        try expect(snapshot.spark?.primary?.usedPercent == 12, "mock client spark primary mismatch")
        try expect(snapshot.spark?.secondary?.usedPercent == 22, "mock client spark secondary mismatch")
        try expect(snapshot.source == .live, "mock client source mismatch")
    }

    private func testCodexLaunch() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = tempDirectory.appendingPathComponent("Codex.app", isDirectory: true)
        let macOSURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let outputURL = tempDirectory.appendingPathComponent("launch-env.txt")
        let executableURL = macOSURL.appendingPathComponent("Codex")
        let script = """
        #!/bin/sh
        printf 'launched' > "\(outputURL.path)"
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let opener = CodexAppOpener(
            executableLocator: StubExecutableLocator(url: executableURL),
            workspaceStateStore: CodexWorkspaceStateStore(
                fileManager: .default,
                globalStateURL: tempDirectory.appendingPathComponent(".codex-global-state.json")
            ),
            codexAppURL: appURL,
            codexBundleIdentifier: "test.codex",
            runningApplicationsProvider: { _ in [] }
        )

        try await opener.openCodex(relaunchIfRunning: false)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                let contents = try String(contentsOf: outputURL, encoding: .utf8)
                try expect(contents == "launched", "Codex app launch did not execute")
                return
            }

            try await Task.sleep(for: .milliseconds(100))
        }

        throw CodexUsageError.invalidResponse("Codex app launch test timed out")
    }

    private func sampleSnapshot(
        source: SnapshotSource,
        stale: Bool,
        email: String?,
        lastUpdatedAt: Date = Date()
    ) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            account: CodexAccountSnapshot(email: email, authMode: .chatgpt, planType: .plus),
            primary: RateLimitWindowSnapshot(usedPercent: 10, windowDurationMins: 300, resetsAt: Date()),
            secondary: RateLimitWindowSnapshot(usedPercent: 20, windowDurationMins: 10080, resetsAt: Date()),
            source: source,
            lastUpdatedAt: lastUpdatedAt,
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

    private func makeJWT(payloadJSON: String) -> String {
        let header = #"{"alg":"none","typ":"JWT"}"#
        return "\(base64url(header)).\(base64url(payloadJSON)).signature"
    }

    private func authDocument(email: String, marker: String) -> String {
        let payload = """
        {
          "email": "\(email)",
          "marker": "\(marker)",
          "https://api.openai.com/auth": {
            "chatgpt_plan_type": "plus",
            "chatgpt_subscription_active_until": "2026-04-19T09:33:13+00:00"
          }
        }
        """

        return """
        {
          "auth_mode": "chatgpt",
          "tokens": {
            "id_token": "\(makeJWT(payloadJSON: payload))"
          }
        }
        """
    }

    private func base64url(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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

private struct ThrowingSessionSource: SessionLogUsageSource {
    func latestSnapshot() throws -> CodexUsageSnapshot? {
        throw CodexUsageError.processFailed("session read failed")
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

private final class InMemoryTokenUsageIndexStore: TokenUsageSessionIndexStoring, @unchecked Sendable {
    private var index: TokenUsageSessionIndex?
    private(set) var saveCount = 0

    func load() throws -> TokenUsageSessionIndex? {
        index
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(index ?? TokenUsageSessionIndex())
    }

    func save(_ index: TokenUsageSessionIndex) throws {
        self.index = index
        saveCount += 1
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
