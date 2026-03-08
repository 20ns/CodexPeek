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
            if let sessionFallback = merge(snapshot: try sessionLogSource.latestSnapshot(), fallback: cached, authFallback: authAccount)?
                .withSource(.sessionLog, stale: true) {
                try? cacheStore.save(sessionFallback)
                return sessionFallback
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
            return fallback
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

        return snapshot
    }
}
