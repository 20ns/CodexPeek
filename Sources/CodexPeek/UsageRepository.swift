import Foundation

actor UsageRepository {
    private let liveSource: CodexUsageLiveSource
    private let sessionLogSource: SessionLogUsageSource
    private let cacheStore: UsageSnapshotStoring
    private let accountInfoSource: AccountInfoSource

    init(
        liveSource: CodexUsageLiveSource,
        sessionLogSource: SessionLogUsageSource,
        cacheStore: UsageSnapshotStoring,
        accountInfoSource: AccountInfoSource
    ) {
        self.liveSource = liveSource
        self.sessionLogSource = sessionLogSource
        self.cacheStore = cacheStore
        self.accountInfoSource = accountInfoSource
    }

    func refresh() async throws -> CodexUsageSnapshot {
        let cached = try? cacheStore.load()
        let authAccount = try? accountInfoSource.loadAccountSnapshot()

        do {
            guard let live = merge(snapshot: try await liveSource.fetchUsageSnapshot(), fallback: cached, authFallback: authAccount) else {
                throw CodexUsageError.invalidResponse("live snapshot was empty")
            }
            try? cacheStore.save(live)
            return live
        } catch {
            let sessionSnapshot = try? sessionLogSource.latestSnapshot()
            if let sessionFallback = merge(snapshot: sessionSnapshot, fallback: cached, authFallback: authAccount)?
                .withSource(.sessionLog, stale: true) {
                if shouldUse(sessionFallback: sessionFallback, over: cached) {
                    try? cacheStore.save(sessionFallback)
                    return sessionFallback
                }
            }

            if let cached {
                return cached.withSource(.cache, stale: true)
            }

            throw error
        }
    }

    func loadCachedSnapshot() -> CodexUsageSnapshot? {
        try? cacheStore.load()
    }

    private func merge(
        snapshot: CodexUsageSnapshot?,
        fallback: CodexUsageSnapshot?,
        authFallback: CodexAccountSnapshot?
    ) -> CodexUsageSnapshot? {
        guard var snapshot else {
            return nil
        }

        if snapshot.account.email == nil {
            snapshot.account.email = fallback?.account.email ?? authFallback?.email
        }

        if snapshot.account.authMode == .unknown {
            snapshot.account.authMode = fallback?.account.authMode ?? authFallback?.authMode ?? .unknown
        }

        if snapshot.account.planType == .unknown {
            snapshot.account.planType = fallback?.account.planType ?? authFallback?.planType ?? .unknown
        }

        if snapshot.account.renewsAt == nil {
            snapshot.account.renewsAt = fallback?.account.renewsAt ?? authFallback?.renewsAt
        }

        return snapshot
    }

    private func shouldUse(sessionFallback: CodexUsageSnapshot, over cached: CodexUsageSnapshot?) -> Bool {
        guard let cached else {
            return true
        }

        if cached.source == .live, sessionFallback.lastUpdatedAt < cached.lastUpdatedAt {
            return false
        }

        return sessionFallback.lastUpdatedAt >= cached.lastUpdatedAt
    }
}
