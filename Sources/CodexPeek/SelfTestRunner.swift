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
        try testPlanUsageHistoryStore()
        try testSessionLogFallback()
        try testProfileScopedCachePaths()
        try await testRepositoryPrecedence()
        try testUsageLevelThresholds()
        try testCountdownFormatting()
        try testWeeklyExhaustionState()
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
        try expect(cost.total == 35, "GPT-5.6 Sol pricing mismatch")
        try expect(TokenPricingCatalog.standard.displayModelName(for: "gpt-5.6-terra-2026") == "GPT-5.6 Terra", "GPT-5.6 Terra prefix pricing missing")
        try expect(UIFormatters.compactTokenString(2_106_400_000) == "2.1B", "billion token formatting mismatch")
    }

    private func testTokenUsageHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let first = formatter.string(from: Date().addingTimeInterval(-3600))
        let second = formatter.string(from: Date().addingTimeInterval(-1800))
        let log = """
        {"timestamp":"\(first)","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(first)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":20,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":100}}}}
        {"timestamp":"\(first)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":30,"output_tokens":40,"reasoning_output_tokens":10,"total_tokens":160}}}}
        {"timestamp":"\(second)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":180,"cached_input_tokens":50,"output_tokens":70,"reasoning_output_tokens":20,"total_tokens":250}}}}
        """
        try Data(log.utf8).write(to: root.appendingPathComponent("rollout.jsonl"))

        let report = try CodexTokenUsageSource(sessionsRootURL: root).usageReport()
        let buckets = try unwrap(report.history?.buckets, "token history missing")
        let totals = Dictionary(uniqueKeysWithValues: UsageHistoryAnalytics.modelTotals(
            from: UsageHistoryAnalytics.dailyUsage(from: buckets, days: 2)
        ).map { ($0.model, $0.usage.totalTokens) })

        try expect(report.allTime.totalTokens == 250, "session token history should use the latest cumulative total")
        try expect(report.allTime.sessionCount == 1, "history should retain session counts")
        try expect(totals["gpt-5.4"] == 250, "model token history mismatch")
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
