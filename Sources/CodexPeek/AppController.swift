@preconcurrency import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let refreshTolerance: TimeInterval = 30

    private let accountStore: AccountProfileStore
    private let defaults: UserDefaults
    private enum Provider: String { case codex, claude }
    private var primaryProvider: Provider { Provider(rawValue: defaults.string(forKey: "primaryProvider") ?? "") ?? .codex }
    // The primary provider is always tracked; the stored flag remembers the choice for when it is secondary.
    private var codexEnabled: Bool { primaryProvider == .codex || defaults.bool(forKey: "codexEnabled") }
    private var claudeEnabled: Bool { primaryProvider == .claude || defaults.bool(forKey: "claudeEnabled") }
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let accountsMenu = NSMenu(title: "Accounts")
    private let providersMenu = NSMenu(title: "Providers")
    private let iconRenderer = StatusIconRenderer()
    private let launchAtLoginController = LaunchAtLoginController()
    private let codexAppOpener = CodexAppOpener()
    private let codexDesktopAuthStore = CodexDesktopAuthStore()
    private let authFileWatcher = AuthFileWatcher()
    private let claudeUsageWatcher = AuthFileWatcher()
    private let claudeUsageSource = ClaudeCodeUsageSource()
    private var claudeUsageTask: Task<Void, Never>?

    private let headerView = HeaderMenuItemView()
    private let primaryUsageView = UsageMenuItemView()
    private let secondaryUsageView = UsageMenuItemView()
    private let sparkUsageView = CompactSupplementalUsageMenuItemView()
    private let tokenCostView = TokenCostMenuItemView()
    private let statusView = StatusMenuItemView()
    private let claudeSectionView = MenuSectionHeaderView()
    private let claudeFiveHourView = ClaudeUsageMenuItemView()
    private let claudeWeeklyView = ClaudeUsageMenuItemView()
    private let claudeTokenCostView = TokenCostMenuItemView()
    private let claudeStatusView = StatusMenuItemView()

    private let headerItem = NSMenuItem()
    private let primaryUsageItem = NSMenuItem()
    private let secondaryUsageItem = NSMenuItem()
    private let sparkUsageItem = NSMenuItem()
    private let tokenCostItem = NSMenuItem()
    private let statusItemView = NSMenuItem()
    private let claudeSectionItem = NSMenuItem()
    private let claudeFiveHourItem = NSMenuItem()
    private let claudeWeeklyItem = NSMenuItem()
    private let claudeTokenCostItem = NSMenuItem()
    private let claudeStatusItem = NSMenuItem()
    private let enableClaudeItem = NSMenuItem(title: "Enable Claude local usage", action: #selector(enableClaudeLocalUsage), keyEquivalent: "")
    private let accountsItem = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let logoutItem = NSMenuItem(title: "Log Out", action: #selector(logOut), keyEquivalent: "")
    private let openCodexItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "Usage History…", action: #selector(openUsageHistory), keyEquivalent: "")
    private let providersItem = NSMenuItem(title: "Providers", action: nil, keyEquivalent: "")
    private let codexPrimaryItem = NSMenuItem(title: "Codex", action: #selector(selectPrimary), keyEquivalent: "")
    private let claudePrimaryItem = NSMenuItem(title: "Claude Code", action: #selector(selectPrimary), keyEquivalent: "")
    private let codexToggleItem = NSMenuItem(title: "Codex", action: #selector(toggleCodex), keyEquivalent: "")
    private let claudeToggleItem = NSMenuItem(title: "Claude Code", action: #selector(toggleClaude), keyEquivalent: "")
    private let codexHeaderSeparator = NSMenuItem.separator()
    private let sectionSeparator = NSMenuItem.separator()
    private let removeAccountItem = NSMenuItem(title: "Remove Current Account…", action: #selector(removeCurrentAccount), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    private var repository: UsageRepository?
    private var tokenUsageSource: TokenUsageSource?
    private var tokenReportStore: TokenUsageReportStoring?
    private let claudeTokenSource = ClaudeCodeTokenUsageSource(indexStore: TokenUsageSessionIndexStore(
        cacheURL: AccountProfileStore.baseSupportURL().appendingPathComponent("claude-token-index.json")
    ))
    private let claudeTokenStore = TokenUsageReportCacheStore(
        cacheURL: AccountProfileStore.baseSupportURL().appendingPathComponent("claude-token-report.json")
    )
    private var claudeTokenReport: TokenUsageReport?
    private var claudeTokenTask: Task<Void, Never>?
    private var pendingClaudeTokenRefresh = false
    private var lastClaudeTokenAttempt: Date?
    private var claudeTokenFailed = false
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshReason: String?
    private var tokenReportTask: Task<Void, Never>?
    private var lastTokenReportAttempt: Date?
    private var pendingTokenReportRefresh = false
    private var tokenReportGeneration = 0
    private var claudeSnapshot: ClaudeCodeUsageSnapshot?
    private var claudeBridgeEnabled = false
    private var claudeUsageError: String?
    private var snapshot: CodexUsageSnapshot?
    private var tokenReport: TokenUsageReport?
    private var planHistory = PlanUsageHistory()
    private var planHistoryStore: PlanUsageHistoryStore?
    private var usageHistoryWindowController: UsageHistoryWindowController?
    private var refreshState: RefreshState = .idle
    private var wakeObserver: NSObjectProtocol?
    private var lastRefreshStartAt: Date?

    private var accountState: AccountProfilesState?
    private var activeProfile: AccountProfile?
    private var accountSnapshotsByProfileID: [String: CodexAccountSnapshot] = [:]
    private var pendingLoginProfileID: String?
    private var pendingCreatedProfileIDs = Set<String>()
    private var loginMonitorTask: Task<Void, Never>?

    init(accountStore: AccountProfileStore, defaults: UserDefaults = .standard) {
        self.accountStore = accountStore
        self.defaults = defaults
        defaults.register(defaults: ["codexEnabled": true, "claudeEnabled": true])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        claudeTokenReport = try? claudeTokenStore.load()
        configureStatusItem()
        configureMenu()
        installWakeObserver()
        watchClaudeUsage()
        scheduleRefreshTimer()

        do {
            if codexEnabled { try syncAccountStateFromDisk() }
        } catch {
            refreshState = .failed("Failed to load account profiles")
        }

        render()

        Task { [weak self] in
            guard let self else {
                return
            }

            if let repository = self.repository, let cached = await repository.loadCachedSnapshot() {
                self.snapshot = cached
                self.render()
            }

            self.triggerRefresh(reason: "startup")
            self.refreshTokenReportIfNeeded(force: false)
            self.refreshClaudeTokenReportIfNeeded(force: false)
            self.refreshClaudeUsage()
            self.refreshClaudeAccountUsage()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        do {
            if codexEnabled { try syncAccountStateFromDisk() }
        } catch {
            refreshState = .failed("Failed to load account profiles")
        }

        refreshClaudeUsage()
    }

    @objc private func refreshNow() {
        triggerRefresh(reason: "manual", force: true)
        refreshTokenReportIfNeeded(force: true)
        refreshClaudeTokenReportIfNeeded(force: true)
        refreshClaudeUsage()
        refreshClaudeAccountUsage(force: true)
    }

    @objc private func selectPrimary(_ sender: NSMenuItem) {
        updateProviders { defaults.set(sender === claudePrimaryItem ? Provider.claude.rawValue : Provider.codex.rawValue, forKey: "primaryProvider") }
    }

    @objc private func toggleCodex() {
        updateProviders { defaults.set(!defaults.bool(forKey: "codexEnabled"), forKey: "codexEnabled") }
    }

    @objc private func toggleClaude() {
        updateProviders { defaults.set(!defaults.bool(forKey: "claudeEnabled"), forKey: "claudeEnabled") }
    }

    private func updateProviders(_ change: () -> Void) {
        let wasCodex = codexEnabled, wasClaude = claudeEnabled
        change()
        if codexEnabled != wasCodex {
            if codexEnabled {
                triggerRefresh(reason: "provider-enabled", force: true)
                if let activeProfile { installAuthFileWatcher(for: activeProfile) }
                refreshTokenReportIfNeeded(force: true)
            } else {
                authFileWatcher.stop()
                loginMonitorTask?.cancel()
                refreshTask?.cancel()
                tokenReportTask?.cancel()
                pendingRefreshReason = nil
                pendingTokenReportRefresh = false
                refreshState = .idle
            }
        }
        if claudeEnabled != wasClaude {
            if claudeEnabled {
                watchClaudeUsage()
                refreshClaudeUsage()
                refreshClaudeAccountUsage()
                refreshClaudeTokenReportIfNeeded(force: true)
            } else {
                claudeUsageWatcher.stop()
                claudeUsageTask?.cancel()
                claudeTokenTask?.cancel()
                pendingClaudeTokenRefresh = false
            }
        }
        layoutMenu()
        render()
    }

    @objc private func enableClaudeLocalUsage() {
        do {
            guard let executableURL = Bundle.main.executableURL else { return }
            try ClaudeCodeStatusLine.install(executableURL: executableURL)
            watchClaudeUsage()
            refreshClaudeUsage()
        } catch {
            claudeUsageError = "Could not enable local Claude usage"
            render()
        }
    }

    @objc private func openUsageHistory() {
        if usageHistoryWindowController == nil {
            usageHistoryWindowController = UsageHistoryWindowController(
                onRefresh: { [weak self] in self?.refreshNow() },
                onClose: { [weak self] in self?.usageHistoryWindowController = nil }
            )
        }
        usageHistoryWindowController?.show(
            report: codexEnabled ? tokenReport : nil,
            claudeReport: claudeEnabled ? claudeTokenReport : nil,
            planHistory: planHistory,
            snapshot: snapshot,
            accountPlan: activeAccountSnapshot?.planType ?? .unknown
        )
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try launchAtLoginController.setEnabled(!launchAtLoginController.isEnabled)
            render()
        } catch {
            refreshState = .failed("Launch at login requires a bundled app")
            render()
        }
    }

    @objc private func openCodex() {
        guard let activeProfile else {
            refreshState = .failed("Missing active account profile")
            render()
            return
        }

        let shouldRestart: Bool
        do {
            shouldRestart = try codexDesktopAuthStore.prepareSystemAuth(
                for: activeProfile,
                among: accountState?.profiles ?? []
            )
        } catch {
            refreshState = .failed(error.localizedDescription)
            render()
            return
        }

        Task { [weak self] in
            do {
                try await self?.codexAppOpener.openCodex(relaunchIfRunning: shouldRestart)
            } catch {
                await MainActor.run {
                    self?.refreshState = .failed(error.localizedDescription)
                    self?.render()
                }
            }
        }
    }

    @objc private func copyDebugInfo() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(debugSummary(), forType: .string)
        headerView.toolTip = "Debug info copied"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                self?.headerView.toolTip = nil
            }
        }
    }

    @objc private func selectAccountProfile(_ sender: NSMenuItem) {
        guard refreshTask == nil,
              let profileID = sender.representedObject as? String else {
            return
        }

        do {
            let state = try accountStore.setActiveProfileID(profileID)
            updateAccountState(state)
            guard let profile = state.activeProfile() else {
                throw CodexUsageError.invalidResponse("missing active account profile")
            }

            try switchToProfile(profile, loadCachedSnapshot: true, refreshReason: "account-switch")
        } catch {
            refreshState = .failed(error.localizedDescription)
            render()
        }
    }

    @objc private func addAccount() {
        guard refreshTask == nil else {
            return
        }

        do {
            let state = try accountStore.createManagedProfile(activate: true)
            updateAccountState(state)
            guard let profile = state.activeProfile() else {
                throw CodexUsageError.invalidResponse("missing active account profile")
            }

            pendingCreatedProfileIDs.insert(profile.id)
            try switchToProfile(profile, loadCachedSnapshot: false, refreshReason: nil)
            try startLogin(for: profile)
        } catch {
            refreshState = .failed(error.localizedDescription)
            render()
        }
    }

    @objc private func signInCurrentAccount() {
        guard refreshTask == nil, let activeProfile else {
            return
        }

        do {
            try startLogin(for: activeProfile)
        } catch {
            refreshState = .failed(error.localizedDescription)
            render()
        }
    }

    @objc private func logOut() {
        guard refreshTask == nil, let activeProfile else {
            return
        }

        refreshState = .refreshing
        render()

        let environment = codexEnvironment(for: activeProfile)
        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            var shouldRefreshAfterLogout = false
            defer {
                self.refreshTask = nil
                self.render()
                if shouldRefreshAfterLogout {
                    self.triggerRefresh(reason: "logout", force: true)
                }
            }

            do {
                try await codexAppOpener.logout(environment: environment)
                self.snapshot = nil
                self.refreshState = .idle
                self.accountSnapshotsByProfileID.removeValue(forKey: activeProfile.id)
                try self.codexDesktopAuthStore.clearPersistedAuth(
                    for: activeProfile,
                    among: self.accountState?.profiles ?? []
                )
                if activeProfile.kind == .managed {
                    let state = try self.accountStore.deleteManagedProfile(id: activeProfile.id)
                    self.pendingCreatedProfileIDs.remove(activeProfile.id)
                    self.pendingLoginProfileID = self.pendingLoginProfileID == activeProfile.id ? nil : self.pendingLoginProfileID
                    self.updateAccountState(state)
                    if let profile = state.activeProfile() {
                        try self.switchToProfile(profile, loadCachedSnapshot: true, refreshReason: nil)
                    }
                } else {
                    try self.codexDesktopAuthStore.clearOwnerIfNeeded(
                        for: activeProfile,
                        among: self.accountState?.profiles ?? []
                    )
                    try self.syncAccountStateFromDisk()
                }
                shouldRefreshAfterLogout = true
            } catch {
                self.refreshState = .failed(error.localizedDescription)
            }
        }
    }

    @objc private func removeCurrentAccount() {
        guard refreshTask == nil,
              let activeProfile,
              activeProfile.kind == .managed else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Remove \(activeProfile.displayName)?"
        alert.informativeText = "This removes the saved CodexPeek account profile from this Mac. You can add it again later by signing in."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            _ = try codexDesktopAuthStore.restoreDefaultIfSystemAuthOwned(
                by: activeProfile,
                among: accountState?.profiles ?? []
            )
            let state = try accountStore.deleteManagedProfile(id: activeProfile.id)
            pendingCreatedProfileIDs.remove(activeProfile.id)
            pendingLoginProfileID = pendingLoginProfileID == activeProfile.id ? nil : pendingLoginProfileID
            updateAccountState(state)
            guard let profile = state.activeProfile() else {
                throw CodexUsageError.invalidResponse("missing active account profile")
            }

            try switchToProfile(profile, loadCachedSnapshot: true, refreshReason: "account-remove")
        } catch {
            refreshState = .failed(error.localizedDescription)
            render()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        headerItem.view = headerView
        primaryUsageItem.view = primaryUsageView
        secondaryUsageItem.view = secondaryUsageView
        sparkUsageItem.view = sparkUsageView
        tokenCostItem.view = tokenCostView
        statusItemView.view = statusView
        claudeSectionItem.view = claudeSectionView
        claudeFiveHourItem.view = claudeFiveHourView
        claudeWeeklyItem.view = claudeWeeklyView
        claudeTokenCostItem.view = claudeTokenCostView
        claudeStatusItem.view = claudeStatusView
        accountsItem.submenu = accountsMenu
        providersItem.submenu = providersMenu
        providersMenu.autoenablesItems = false
        for item in [codexPrimaryItem, claudePrimaryItem, codexToggleItem, claudeToggleItem] {
            item.target = self
        }
        providersMenu.items = [
            .sectionHeader(title: "Menu Bar Icon"), codexPrimaryItem, claudePrimaryItem,
            .separator(),
            .sectionHeader(title: "Show in Menu"), codexToggleItem, claudeToggleItem
        ]

        launchAtLoginItem.target = self
        logoutItem.target = self
        openCodexItem.target = self
        historyItem.target = self
        removeAccountItem.target = self
        quitItem.target = self
        enableClaudeItem.target = self
        headerView.onRefresh = { [weak self] in
            self?.refreshNow()
        }
        claudeSectionView.onRefresh = { [weak self] in
            self?.refreshNow()
        }
        headerView.onCopyDebugInfo = { [weak self] in
            self?.copyDebugInfo()
        }

        layoutMenu()
    }

    /// The primary provider's section leads the menu.
    private func layoutMenu() {
        let codex = [headerItem, codexHeaderSeparator, primaryUsageItem, secondaryUsageItem, sparkUsageItem, tokenCostItem, statusItemView]
        let claude = [claudeSectionItem, claudeFiveHourItem, claudeWeeklyItem, claudeTokenCostItem, claudeStatusItem, enableClaudeItem]
        let sections = primaryProvider == .codex ? codex + [sectionSeparator] + claude : claude + [sectionSeparator] + codex
        menu.items = sections + [
            .separator(), historyItem, providersItem, accountsItem,
            .separator(), launchAtLoginItem, logoutItem, openCodexItem,
            .separator(), quitItem
        ]
    }

    private func installWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshClaudeUsage()
            }
        }
    }

    private func installAuthFileWatcher(for profile: AccountProfile) {
        guard codexEnabled else { return }
        authFileWatcher.start(watching: profile.authURL) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.codexEnabled else { return }
                let previousAccount = self.activeAccountSnapshot
                let previousProfileID = self.activeProfile?.id
                do {
                    try self.syncAccountStateFromDisk()
                } catch {
                    self.refreshState = .failed("Failed to reload account profile")
                    self.render()
                    return
                }
                let accountChanged = previousAccount != self.activeAccountSnapshot || previousProfileID != self.activeProfile?.id
                if accountChanged { self.snapshot = nil }
                self.render()
            }
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRefresh(reason: "timer")
                self?.refreshTokenReportIfNeeded(force: false)
                self?.refreshClaudeTokenReportIfNeeded(force: false)
                self?.refreshClaudeUsage()
                self?.refreshClaudeAccountUsage()
            }
        }
        refreshTimer?.tolerance = Self.refreshTolerance
    }

    private func triggerRefresh(reason: String, force: Bool = false) {
        guard codexEnabled else { return }
        do {
            try syncAccountStateFromDisk()
        } catch {
            refreshState = .failed("Failed to sync account profiles")
            render()
            return
        }

        guard let repository, let activeProfile else {
            return
        }
        if refreshTask != nil {
            if force { pendingRefreshReason = reason }
            return
        }

        let now = Date()
        if !force,
           let lastRefreshStartAt,
           now.timeIntervalSince(lastRefreshStartAt) < Self.refreshInterval {
            return
        }

        lastRefreshStartAt = now
        refreshTimer?.fireDate = now.addingTimeInterval(Self.refreshInterval)
        let profileID = activeProfile.id
        refreshState = .refreshing
        render()

        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            var recoveredProfile: AccountProfile?

            defer {
                self.refreshTask = nil
                let pendingReason = self.pendingRefreshReason
                self.pendingRefreshReason = nil
                self.render()
                if let recoveredProfile {
                    try? self.switchToProfile(
                        recoveredProfile,
                        loadCachedSnapshot: true,
                        refreshReason: "profile-recovery"
                    )
                } else if let pendingReason {
                    self.triggerRefresh(reason: pendingReason, force: true)
                }
            }

            do {
                let snapshot = try await repository.refresh()
                guard !Task.isCancelled, self.codexEnabled, self.activeProfile?.id == profileID else {
                    return
                }
                if self.shouldAttemptDuplicateProfileRecovery(for: activeProfile, snapshot: snapshot),
                   let candidate = await self.recoverDuplicateProfile(from: activeProfile) {
                    self.snapshot = nil
                    self.refreshState = .idle
                    recoveredProfile = candidate
                    return
                }
                self.snapshot = snapshot
                if !snapshot.isStale, let store = self.planHistoryStore {
                    self.planHistory = store.record(snapshot)
                }
                self.refreshState = .idle
                try self.syncAccountStateFromDisk()
            } catch {
                guard !Task.isCancelled, self.codexEnabled, self.activeProfile?.id == profileID else {
                    return
                }
                if let candidate = await self.recoverDuplicateProfile(from: activeProfile) {
                    self.snapshot = nil
                    self.refreshState = .idle
                    recoveredProfile = candidate
                    return
                }
                self.refreshState = .failed(error.localizedDescription)
            }

        }
    }

    private func shouldAttemptDuplicateProfileRecovery(
        for profile: AccountProfile,
        snapshot: CodexUsageSnapshot
    ) -> Bool {
        guard profile.kind == .managed else {
            return false
        }

        return snapshot.isStale || (snapshot.primary == nil && snapshot.secondary == nil)
    }

    private func recoverDuplicateProfile(from failedProfile: AccountProfile) async -> AccountProfile? {
        guard let accountState else {
            return nil
        }

        let candidates = DuplicateProfileRecovery.candidateProfiles(
            from: accountState,
            activeProfile: failedProfile,
            snapshotsByProfileID: accountSnapshotsByProfileID
        )

        for candidate in candidates {
            guard !Task.isCancelled, codexEnabled else { return nil }
            let repository = makeRepository(for: candidate)
            guard let snapshot = try? await repository.refresh(),
                  !snapshot.isStale,
                  snapshot.primary != nil || snapshot.secondary != nil else {
                continue
            }

            guard !Task.isCancelled, codexEnabled else { return nil }
            guard let updatedState = try? accountStore.setActiveProfileID(candidate.id) else {
                return candidate
            }

            updateAccountState(updatedState)
            return updatedState.activeProfile()
        }

        return nil
    }

    private func render() {
        let isWeeklyExhausted = snapshot?.isWeeklyExhausted == true
        if primaryProvider == .codex {
            statusItem.button?.image = iconRenderer.render(
                primaryPercent: snapshot?.primary?.usedPercent,
                secondaryPercent: snapshot?.secondary?.usedPercent,
                refreshState: refreshState,
                isWeeklyExhausted: isWeeklyExhausted
            )
            statusItem.button?.toolTip = "Codex usage"
        } else {
            statusItem.button?.image = iconRenderer.render(
                primaryPercent: claudeSnapshot?.fiveHour?.usedPercent,
                secondaryPercent: claudeSnapshot?.sevenDay?.usedPercent,
                refreshState: claudeUsageTask != nil ? .refreshing : .idle,
                isWeeklyExhausted: claudeSnapshot?.sevenDay?.isExhausted == true
            )
            statusItem.button?.toolTip = "Claude Code usage"
        }

        headerView.update(snapshot: snapshot, refreshState: refreshState)

        let sessionWindow = snapshot?.sessionWindow
        let weeklyWindow = snapshot?.weeklyWindow
        let hasBothWindows = sessionWindow != nil && weeklyWindow != nil

        if hasBothWindows {
            let sessionTitle = UIFormatters.rateLimitWindowTitle(for: sessionWindow, fallback: "5-hour window")
            let weeklyTitle = UIFormatters.rateLimitWindowTitle(for: weeklyWindow, fallback: "Weekly window")
            let overrideDetail = isWeeklyExhausted ? "Weekly limit reached • 5-hour window resumes after the weekly reset" : nil

            primaryUsageView.update(
                title: sessionTitle,
                window: sessionWindow,
                isDimmed: isWeeklyExhausted,
                overrideDetail: overrideDetail
            )
            secondaryUsageView.update(title: weeklyTitle, window: weeklyWindow)
        } else {
            let singleWindow = weeklyWindow ?? sessionWindow ?? snapshot?.primary
            let title = UIFormatters.rateLimitWindowTitle(for: singleWindow, fallback: singleWindow?.isWeekly == true ? "Weekly window" : "Usage")

            primaryUsageView.update(
                title: title,
                window: singleWindow,
                isDimmed: false,
                overrideDetail: nil
            )
        }

        sparkUsageView.update(snapshot: snapshot?.spark)
        tokenCostView.update(report: tokenReport, isRefreshing: tokenReportTask != nil)
        if claudeSnapshot != nil {
            claudeFiveHourView.update(
                title: UIFormatters.rateLimitWindowTitle(for: claudeSnapshot?.fiveHour, fallback: "5-hour window"),
                window: claudeSnapshot?.fiveHour
            )
            claudeWeeklyView.update(
                title: UIFormatters.rateLimitWindowTitle(for: claudeSnapshot?.sevenDay, fallback: "Weekly window"),
                window: claudeSnapshot?.sevenDay
            )
        }
        claudeStatusView.update(message: claudeStatusMessage())
        // Whichever section leads the menu carries the refresh button; Codex's header has its own.
        claudeSectionView.update(title: "Claude Code", showsRefresh: primaryProvider == .claude, isRefreshing: claudeUsageTask != nil)
        claudeTokenCostView.update(
            report: claudeTokenReport,
            isRefreshing: claudeTokenTask != nil,
            sourceName: "Claude Code",
            failed: claudeTokenFailed
        )
        for item in [headerItem, primaryUsageItem, tokenCostItem, statusItemView, accountsItem, logoutItem, openCodexItem, removeAccountItem] {
            item.isHidden = !codexEnabled
        }
        secondaryUsageItem.isHidden = !codexEnabled || !hasBothWindows
        sparkUsageItem.isHidden = !codexEnabled || snapshot?.spark == nil
        for item in [claudeSectionItem, claudeTokenCostItem, claudeStatusItem] {
            item.isHidden = !claudeEnabled
        }
        claudeFiveHourItem.isHidden = !claudeEnabled || claudeSnapshot?.fiveHour == nil
        claudeWeeklyItem.isHidden = !claudeEnabled || claudeSnapshot?.sevenDay == nil
        enableClaudeItem.isHidden = !claudeEnabled || (claudeBridgeEnabled && claudeUsageError == nil)
        codexHeaderSeparator.isHidden = !codexEnabled
        sectionSeparator.isHidden = !codexEnabled || !claudeEnabled
        codexPrimaryItem.state = primaryProvider == .codex ? .on : .off
        claudePrimaryItem.state = primaryProvider == .claude ? .on : .off
        codexToggleItem.state = codexEnabled ? .on : .off
        claudeToggleItem.state = claudeEnabled ? .on : .off
        codexToggleItem.isEnabled = primaryProvider != .codex
        claudeToggleItem.isEnabled = primaryProvider != .claude
        statusView.update(snapshot: snapshot, refreshState: refreshState, accountStatus: accountStatusMessage())
        usageHistoryWindowController?.update(
            report: codexEnabled ? tokenReport : nil,
            claudeReport: claudeEnabled ? claudeTokenReport : nil,
            planHistory: planHistory,
            snapshot: snapshot,
            accountPlan: activeAccountSnapshot?.planType ?? .unknown
        )
        renderAccountsMenu()

        launchAtLoginItem.state = launchAtLoginController.isEnabled ? .on : .off
        logoutItem.isEnabled = refreshTask == nil && activeAccountSnapshot?.isSignedIn == true
        openCodexItem.title = "Open Codex with Selected Account"
        openCodexItem.isEnabled = activeAccountSnapshot?.isSignedIn == true
        removeAccountItem.title = "Remove Current Account…"
        removeAccountItem.isEnabled = refreshTask == nil && activeProfile?.kind == .managed
    }

    private func renderAccountsMenu() {
        accountsMenu.removeAllItems()

        guard let accountState else {
            let item = NSMenuItem(title: "No account profiles available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            accountsMenu.addItem(item)
            return
        }

        for profile in accountState.profiles {
            let item = NSMenuItem(
                title: title(for: profile),
                action: #selector(selectAccountProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == accountState.activeProfileID ? .on : .off
            item.isEnabled = refreshTask == nil
            accountsMenu.addItem(item)
        }

        accountsMenu.addItem(.separator())

        let addItem = NSMenuItem(title: "Add Account…", action: #selector(addAccount), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = refreshTask == nil
        accountsMenu.addItem(addItem)

        let signInTitle = activeAccountSnapshot?.isSignedIn == true ? "Reauthenticate Current Account…" : "Sign In Current Account…"
        let signInItem = NSMenuItem(title: signInTitle, action: #selector(signInCurrentAccount), keyEquivalent: "")
        signInItem.target = self
        signInItem.isEnabled = refreshTask == nil && activeProfile != nil
        accountsMenu.addItem(signInItem)

        let appHintItem = NSMenuItem(title: "Open Codex applies the selected account to Codex.app.", action: nil, keyEquivalent: "")
        appHintItem.isEnabled = false
        accountsMenu.addItem(appHintItem)

        if activeProfile?.kind == .managed {
            accountsMenu.addItem(.separator())
            accountsMenu.addItem(removeAccountItem)
        }
    }

    private func title(for profile: AccountProfile) -> String {
        if let snapshot = accountSnapshotsByProfileID[profile.id], snapshot.isSignedIn {
            var parts: [String]
            if profile.kind == .managed {
                parts = [profile.name?.isEmpty == false ? profile.displayName : snapshot.displayName]
            } else {
                parts = [profile.displayName, snapshot.displayName]
            }
            if snapshot.planType != .unknown {
                parts.append(snapshot.planType.displayName)
            }
            return parts.joined(separator: " • ")
        } else if pendingLoginProfileID == profile.id {
            return "\(profile.kind == .managed ? "New Account" : profile.displayName) • Finish sign-in in Terminal"
        } else if profile.kind == .managed {
            return "Signed-out Account • Not signed in"
        } else {
            return "\(profile.displayName) • Not signed in"
        }
    }

    private func syncAccountStateFromDisk() throws {
        let state = try accountStore.loadState()
        guard state.activeProfile() != nil else {
            throw CodexUsageError.invalidResponse("missing active account profile")
        }

        try codexDesktopAuthStore.reconcileSystemAuth(among: state.profiles)
        updateAccountState(state)
        try removeUnsignedManagedProfilesIfNeeded()
        try removeDuplicateManagedProfilesIfNeeded()
        guard let currentState = accountState,
              let currentProfile = currentState.activeProfile() else {
            throw CodexUsageError.invalidResponse("missing active account profile")
        }

        if activeProfile?.id != currentProfile.id || activeProfile?.homePath != currentProfile.homePath || repository == nil {
            configureActiveProfile(currentProfile)
        } else {
            activeProfile = currentProfile
        }

        if currentProfile.kind == .systemDefault,
           try codexDesktopAuthStore.shouldSyncDefaultSnapshotFromSystemAuth(among: currentState.profiles) {
            try codexDesktopAuthStore.syncDefaultSnapshotFromSystemAuth()
        }
    }

    private func updateAccountState(_ state: AccountProfilesState) {
        accountState = state
        accountSnapshotsByProfileID = Dictionary(
            uniqueKeysWithValues: state.profiles.compactMap { profile in
                let authURL = (try? codexDesktopAuthStore.accountInfoURL(for: profile, among: state.profiles)) ?? profile.authURL
                let snapshot = try? AuthJSONAccountInfoSource(authURL: authURL).loadAccountSnapshot()
                guard let snapshot else {
                    return nil
                }
                return (profile.id, snapshot)
            }
        )
    }

    private func removeDuplicateManagedProfilesIfNeeded() throws {
        guard var state = accountState else {
            return
        }

        var removedActiveProfile = false
        for profile in state.profiles where profile.kind == .managed {
            guard let snapshot = accountSnapshotsByProfileID[profile.id],
                  snapshot.isSignedIn,
                  let keeper = duplicateKeeper(for: profile, snapshot: snapshot, in: state) else {
                continue
            }

            if state.activeProfileID == profile.id {
                _ = try accountStore.setActiveProfileID(keeper.id)
                removedActiveProfile = true
            }

            _ = try codexDesktopAuthStore.restoreDefaultIfSystemAuthOwned(by: profile, among: state.profiles)
            state = try accountStore.deleteManagedProfile(id: profile.id)
            pendingCreatedProfileIDs.remove(profile.id)
            if pendingLoginProfileID == profile.id {
                pendingLoginProfileID = nil
            }
            updateAccountState(state)
        }

        if removedActiveProfile, let currentState = accountState, let profile = currentState.activeProfile() {
            snapshot = nil
            configureActiveProfile(profile)
        }
    }

    private func removeUnsignedManagedProfilesIfNeeded() throws {
        guard var state = accountState else {
            return
        }

        var removedActiveProfile = false
        for profile in state.profiles where profile.kind == .managed {
            guard pendingLoginProfileID != profile.id,
                  managedProfileIsDefinitelyUnsigned(profile) else {
                continue
            }

            if state.activeProfileID == profile.id {
                removedActiveProfile = true
            }

            try codexDesktopAuthStore.clearPersistedAuth(for: profile, among: state.profiles)
            state = try accountStore.deleteManagedProfile(id: profile.id)
            pendingCreatedProfileIDs.remove(profile.id)
            updateAccountState(state)
        }

        if removedActiveProfile, let currentState = accountState, let profile = currentState.activeProfile() {
            snapshot = nil
            configureActiveProfile(profile)
        }
    }

    private func managedProfileIsDefinitelyUnsigned(_ profile: AccountProfile) -> Bool {
        guard FileManager.default.fileExists(atPath: profile.authURL.path) else {
            return true
        }

        do {
            return try AuthJSONAccountInfoSource(authURL: profile.authURL).loadAccountSnapshot()?.isSignedIn != true
        } catch {
            return false
        }
    }

    private func duplicateKeeper(
        for profile: AccountProfile,
        snapshot: CodexAccountSnapshot,
        in state: AccountProfilesState
    ) -> AccountProfile? {
        DuplicateProfileRecovery.keeper(
            for: profile,
            snapshot: snapshot,
            in: state,
            snapshotsByProfileID: accountSnapshotsByProfileID,
            pendingCreatedProfileIDs: pendingCreatedProfileIDs
        )
    }

    private func configureActiveProfile(_ profile: AccountProfile) {
        tokenReportGeneration += 1
        tokenReportTask?.cancel()
        tokenReportTask = nil
        lastTokenReportAttempt = nil
        pendingTokenReportRefresh = false
        activeProfile = profile
        repository = makeRepository(for: profile)
        tokenUsageSource = CodexTokenUsageSource(
            sessionsRootURL: profile.sessionsURL,
            indexStore: TokenUsageSessionIndexStore(cacheURL: TokenUsageSessionIndexStore.defaultCacheURL(profileID: profile.id))
        )
        tokenReportStore = TokenUsageReportCacheStore(cacheURL: TokenUsageReportCacheStore.defaultCacheURL(profileID: profile.id))
        tokenReport = try? tokenReportStore?.load()
        planHistoryStore = PlanUsageHistoryStore(fileURL: PlanUsageHistoryStore.defaultURL(profileID: profile.id))
        planHistory = planHistoryStore?.load() ?? PlanUsageHistory()
        installAuthFileWatcher(for: profile)
    }

    private func switchToProfile(_ profile: AccountProfile, loadCachedSnapshot: Bool, refreshReason: String?) throws {
        let profiles = accountState?.profiles ?? []
        try codexDesktopAuthStore.reconcileSystemAuth(among: profiles)

        if profile.kind == .systemDefault {
            _ = try codexDesktopAuthStore.prepareSystemAuth(
                for: profile,
                among: profiles
            )
        }
        if let accountState {
            updateAccountState(accountState)
        }

        snapshot = nil
        refreshState = .idle
        configureActiveProfile(profile)
        render()

        Task { [weak self] in
            guard let self else {
                return
            }

            if loadCachedSnapshot, let repository = self.repository, let cached = await repository.loadCachedSnapshot() {
                guard self.activeProfile?.id == profile.id else {
                    return
                }
                self.snapshot = cached
                self.render()
            }

            if let refreshReason, self.activeProfile?.id == profile.id {
                self.triggerRefresh(reason: refreshReason, force: true)
            }
        }
    }

    private func makeRepository(for profile: AccountProfile) -> UsageRepository {
        UsageRepository(
            liveSource: CodexCLIProtocolClient(environment: codexEnvironment(for: profile)),
            sessionLogSource: CodexSessionLogUsageSource(sessionsRootURL: profile.sessionsURL),
            cacheStore: SnapshotCacheStore(cacheURL: SnapshotCacheStore.defaultCacheURL(profileID: profile.id)),
            accountInfoSource: AuthJSONAccountInfoSource(authURL: profile.authURL)
        )
    }

    private func refreshTokenReportIfNeeded(force: Bool) {
        guard codexEnabled, let tokenUsageSource,
              let tokenReportStore,
              let activeProfile else {
            return
        }

        if tokenReportTask != nil {
            pendingTokenReportRefresh = pendingTokenReportRefresh || force
            return
        }

        let lastAttempt = lastTokenReportAttempt ?? (tokenReport?.historyIncludesAllRetainedSessions == true ? tokenReport?.generatedAt : nil)
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.refreshInterval {
            return
        }

        lastTokenReportAttempt = Date()
        let profileID = activeProfile.id
        let generation = tokenReportGeneration

        tokenReportTask = Task { [weak self, profileID, generation, tokenUsageSource, tokenReportStore] in
            let report: TokenUsageReport?
            if Task.isCancelled {
                report = nil
            } else {
                // Sources check cancellation between files, so unticking a provider stops its scan.
                let scan = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let report = try tokenUsageSource.usageReport()
                    try Task.checkCancellation()
                    try tokenReportStore.save(report)
                    return report
                }
                report = try? await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: { scan.cancel() }
            }
            self?.finishTokenReportRefresh(profileID: profileID, generation: generation, report: Task.isCancelled ? nil : report)
        }
        render()
    }

    private func finishTokenReportRefresh(profileID: String, generation: Int, report: TokenUsageReport?) {
        guard tokenReportGeneration == generation else {
            return
        }
        tokenReportTask = nil
        if codexEnabled, activeProfile?.id == profileID, let report {
            tokenReport = report
        }
        render()
        guard pendingTokenReportRefresh, activeProfile?.id == profileID else {
            pendingTokenReportRefresh = false
            return
        }
        pendingTokenReportRefresh = false
        refreshTokenReportIfNeeded(force: true)
    }

    private func refreshClaudeTokenReportIfNeeded(force: Bool) {
        guard claudeEnabled else { return }
        guard claudeTokenTask == nil else {
            pendingClaudeTokenRefresh = pendingClaudeTokenRefresh || force
            return
        }
        let lastAttempt = lastClaudeTokenAttempt ?? (claudeTokenReport?.historyIncludesAllRetainedSessions == true ? claudeTokenReport?.generatedAt : nil)
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.refreshInterval { return }
        lastClaudeTokenAttempt = Date()
        let source = claudeTokenSource
        let store = claudeTokenStore
        claudeTokenTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.claudeTokenTask = nil
                self.render()
                if self.pendingClaudeTokenRefresh {
                    self.pendingClaudeTokenRefresh = false
                    self.refreshClaudeTokenReportIfNeeded(force: true)
                }
            }
            do {
                let scan = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    let report = try source.usageReport()
                    try Task.checkCancellation()
                    try store.save(report)
                    return report
                }
                let report = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: { scan.cancel() }
                guard !Task.isCancelled, self.claudeEnabled else { return }
                self.claudeTokenReport = report
                self.claudeTokenFailed = false
            } catch {
                guard !Task.isCancelled, self.claudeEnabled else { return }
                self.claudeTokenFailed = true
            }
        }
        render()
    }

    private func codexEnvironment(for profile: AccountProfile) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = profile.homeURL.path
        return environment
    }

    private func startLogin(for profile: AccountProfile) throws {
        try FileManager.default.createDirectory(at: profile.homeURL, withIntermediateDirectories: true)
        try codexAppOpener.launchLoginInTerminal(environment: codexEnvironment(for: profile))
        pendingLoginProfileID = profile.id
        refreshState = .idle
        try syncAccountStateFromDisk()
        render()
        monitorLogin(for: profile)
    }

    private func monitorLogin(for profile: AccountProfile) {
        loginMonitorTask?.cancel()
        loginMonitorTask = Task { [weak self] in
            guard let self else {
                return
            }

            for _ in 0..<120 {
                if Task.isCancelled {
                    return
                }

                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.codexEnabled else { return }

                do {
                    try self.syncAccountStateFromDisk()
                    if let snapshot = self.accountSnapshotsByProfileID[profile.id], snapshot.isSignedIn {
                        self.pendingLoginProfileID = nil
                        let duplicate = self.accountState.flatMap {
                            self.duplicateKeeper(for: profile, snapshot: snapshot, in: $0)
                        }

                        if let duplicate {
                            _ = try self.codexDesktopAuthStore.restoreDefaultIfSystemAuthOwned(
                                by: profile,
                                among: self.accountState?.profiles ?? []
                            )
                            _ = try self.accountStore.deleteManagedProfile(id: profile.id)
                            self.pendingCreatedProfileIDs.remove(profile.id)
                            _ = try self.accountStore.setActiveProfileID(duplicate.id)
                            try self.syncAccountStateFromDisk()
                            if let activeProfile = self.accountState?.activeProfile() {
                                try self.switchToProfile(activeProfile, loadCachedSnapshot: true, refreshReason: "duplicate-login")
                            }
                        } else {
                            self.pendingCreatedProfileIDs.remove(profile.id)
                            try self.applySignedInProfileName(profileID: profile.id, snapshot: snapshot)
                            self.render()
                        }

                        if self.activeProfile?.id == profile.id || duplicate != nil {
                            self.triggerRefresh(reason: "login", force: true)
                        }
                        return
                    }

                    self.render()
                } catch {
                    self.refreshState = .failed(error.localizedDescription)
                    self.render()
                    return
                }
            }

            if self.pendingLoginProfileID == profile.id {
                self.pendingLoginProfileID = nil
                self.render()
            }
        }
    }

    private func applySignedInProfileName(profileID: String, snapshot: CodexAccountSnapshot) throws {
        guard let state = accountState,
              let profile = state.profiles.first(where: { $0.id == profileID }),
              profile.kind == .managed,
              profile.name == nil,
              let email = snapshot.email,
              !email.isEmpty else {
            return
        }

        let updatedState = try accountStore.renameProfile(id: profileID, name: email)
        updateAccountState(updatedState)
    }

    private func accountStatusMessage() -> String? {
        guard let activeProfile else {
            return nil
        }

        if pendingLoginProfileID == activeProfile.id {
            return "Finish sign-in in Terminal"
        }

        guard activeAccountSnapshot?.isSignedIn != true else {
            return nil
        }

        return "Sign in this account from Accounts"
    }

    private var activeAccountSnapshot: CodexAccountSnapshot? {
        guard let activeProfile else {
            return nil
        }
        return accountSnapshotsByProfileID[activeProfile.id] ?? nil
    }

    private func debugSummary() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let account = snapshot?.account.email ?? snapshot?.displayAccountName ?? activeAccountSnapshot?.displayName ?? "unknown"
        let plan = snapshot?.account.planType.displayName ?? activeAccountSnapshot?.planType.displayName ?? "Unknown"
        let renewsAt = snapshot?.account.renewsAt ?? activeAccountSnapshot?.renewsAt
        let source = snapshot?.source.displayName ?? "none"
        let stale = snapshot?.isStale == true ? "yes" : "no"
        let primary = snapshot?.primary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let secondary = snapshot?.secondary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let sparkPrimary = snapshot?.spark?.primary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let sparkWeekly = snapshot?.spark?.secondary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let weeklyTokenCost = tokenReport.map { UIFormatters.costString($0.week.estimatedCostUSD) } ?? "unavailable"
        let weeklyTokenTotal = tokenReport.map { UIFormatters.compactTokenString($0.week.totalTokens) } ?? "unavailable"
        let last30DaysTokenCost = tokenReport.map { UIFormatters.costString($0.month.estimatedCostUSD) } ?? "unavailable"
        let allTimeTokenCost = tokenReport.map { UIFormatters.costString($0.allTime.estimatedCostUSD) } ?? "unavailable"
        let updatedAt = snapshot.map { UIFormatters.usageUpdatedString(from: $0.lastUpdatedAt) } ?? "never"
        let profileLabel = activeProfile?.displayName ?? "unknown"
        let profileHome = activeProfile?.homeURL.path ?? "unknown"

        return [
            "CodexPeek \(version) (\(build))",
            "Profile: \(profileLabel)",
            "Profile home: \(profileHome)",
            "Account: \(account)",
            "Plan: \(plan)",
            "Renews: \(renewsAt.map(UIFormatters.accountRenewalString(from:)) ?? "unknown")",
            "Source: \(source)",
            "Stale: \(stale)",
            "5h usage: \(primary)",
            "Weekly usage: \(secondary)",
            "Spark 5h usage: \(sparkPrimary)",
            "Spark weekly usage: \(sparkWeekly)",
            "7-day token usage: \(weeklyTokenTotal)",
            "7-day API-equivalent estimate: \(weeklyTokenCost)",
            "30-day API-equivalent estimate: \(last30DaysTokenCost)",
            "All-time API-equivalent estimate: \(allTimeTokenCost)",
            "Last updated: \(updatedAt)",
            "Claude 5h usage: \(claudeSnapshot?.fiveHour.map { "\($0.usedPercent)%" } ?? "unavailable")",
            "Claude weekly usage: \(claudeSnapshot?.sevenDay.map { "\($0.usedPercent)%" } ?? "unavailable")",
            "Claude local bridge: \(claudeBridgeEnabled ? "enabled" : "disabled")",
            "Claude stale: \(claudeSnapshot?.isStale == true ? "yes" : "no")",
            "Claude updated: \(claudeSnapshot.map { UIFormatters.usageUpdatedString(from: $0.updatedAt) } ?? "never")"
        ].joined(separator: "\n")
    }

    private func watchClaudeUsage() {
        guard claudeEnabled else { return }
        claudeUsageWatcher.start(watching: ClaudeCodeStatusLine.cacheURL) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshClaudeUsage() }
        }
    }

    private func refreshClaudeUsage() {
        guard claudeEnabled else { return }
        do {
            let cached = try ClaudeCodeStatusLine.load()
            if let cached, cached.updatedAt != claudeSnapshot?.updatedAt, !cached.isStale {
                claudeUsageError = nil
            }
            claudeSnapshot = cached
            if claudeUsageError != nil { claudeSnapshot?.isStale = true }
            claudeBridgeEnabled = try ClaudeCodeStatusLine.isInstalled()
        } catch {
            claudeSnapshot?.isStale = true
            let now = Date()
            if (claudeSnapshot?.fiveHour?.resetsAt ?? .distantFuture) <= now { claudeSnapshot?.fiveHour = nil }
            if (claudeSnapshot?.sevenDay?.resetsAt ?? .distantFuture) <= now { claudeSnapshot?.sevenDay = nil }
            claudeUsageError = "Could not read local Claude usage"
        }
        render()
    }

    private func refreshClaudeAccountUsage(force: Bool = false) {
        let due = claudeSnapshot.map {
            $0.isStale || Date().timeIntervalSince($0.updatedAt) >= Self.refreshInterval - Self.refreshTolerance
        } ?? true
        guard claudeEnabled, claudeUsageTask == nil, force || due else { return }
        // Off-phase fetches (manual, re-enabled) restart the shared wait so the next tick finds the reading due.
        refreshTimer?.fireDate = Date().addingTimeInterval(Self.refreshInterval)
        claudeUsageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.claudeUsageTask = nil
                self.render()
                if Task.isCancelled, self.claudeEnabled { self.refreshClaudeAccountUsage(force: true) }
            }
            do {
                if let fresh = try await self.claudeUsageSource.refresh(force: force) {
                    guard !Task.isCancelled, self.claudeEnabled else { return }
                    self.claudeSnapshot = fresh
                    self.claudeUsageError = nil
                }
            } catch {
                guard !Task.isCancelled, self.claudeEnabled else { return }
                self.refreshClaudeUsage()
                self.claudeSnapshot?.isStale = true
                self.claudeUsageError = error.localizedDescription
            }
        }
        render()
    }

    private func claudeStatusMessage() -> String {
        if let claudeUsageError {
            let time = claudeSnapshot.map { " • last updated \(UIFormatters.usageUpdatedString(from: $0.updatedAt))" } ?? ""
            return claudeUsageError + time
        }
        guard let claudeSnapshot else {
            return claudeUsageTask == nil ? "Claude usage unavailable • use the refresh button" : "Fetching Claude usage…"
        }
        let time = UIFormatters.usageUpdatedString(from: claudeSnapshot.updatedAt)
        return claudeSnapshot.isStale ? "Claude usage updated \(time) • stale" : "From Claude Code • updated \(time)"
    }
}
