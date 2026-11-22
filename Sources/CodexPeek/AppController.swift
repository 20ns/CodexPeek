@preconcurrency import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppController: NSObject, NSPopoverDelegate {
    private static let refreshInterval: TimeInterval = 5 * 60
    private static let refreshTolerance: TimeInterval = 30

    private let accountStore: AccountProfileStore
    private let defaults: UserDefaults
    private var primaryProvider: PopoverProvider {
        PopoverProvider(rawValue: defaults.string(forKey: "primaryProvider") ?? "") ?? .codex
    }
    // The primary provider is always tracked; the stored flag remembers the choice for when it is secondary.
    private var codexEnabled: Bool { primaryProvider == .codex || defaults.bool(forKey: "codexEnabled") }
    private var claudeEnabled: Bool { primaryProvider == .claude || defaults.bool(forKey: "claudeEnabled") }
    private var agyEnabled: Bool { primaryProvider == .antigravity || defaults.bool(forKey: "agyEnabled") }
    private var showAccountEmail: Bool { defaults.bool(forKey: "showAccountEmail") }

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverViewModel = PopoverViewModel()
    private var popoverHostController: NSHostingController<UsagePopoverView>?
    private var outsideClickMonitor: Any?

    private let iconRenderer = StatusIconRenderer()
    private let launchAtLoginController = LaunchAtLoginController()
    private let codexAppOpener = CodexAppOpener()
    private let codexDesktopAuthStore = CodexDesktopAuthStore()
    private let authFileWatcher = AuthFileWatcher()
    private let claudeUsageWatcher = AuthFileWatcher()
    private let agyUsageWatcher = AuthFileWatcher()
    private let claudeUsageSource = ClaudeCodeUsageSource()
    private var claudeUsageTask: Task<Void, Never>?

    private var repository: UsageRepository?
    private var tokenUsageSource: TokenUsageSource?
    private var tokenReportStore: TokenUsageReportStoring?
    private let claudeTokenSource = ClaudeCodeTokenUsageSource(indexStore: TokenUsageSessionIndexStore(
        cacheURL: AccountProfileStore.baseSupportURL().appendingPathComponent("claude-token-index.json")
    ))
    private let claudeTokenStore = TokenUsageReportCacheStore(
        cacheURL: AccountProfileStore.baseSupportURL().appendingPathComponent("claude-token-report.json")
    )
    private var agyTokenSource: TokenUsageSource = AntigravityTokenUsageSource(indexStore: TokenUsageSessionIndexStore(
        cacheURL: AccountProfileStore.baseSupportURL().appendingPathComponent("antigravity-token-index.json")
    ))
    private var agyTokenStore: TokenUsageReportStoring = TokenUsageReportCacheStore(
        cacheURL: AccountProfileStore.baseSupportURL().appendingPathComponent("antigravity-token-report.json")
    )

    private var claudeTokenReport: TokenUsageReport?
    private var claudeTokenTask: Task<Void, Never>?
    private var pendingClaudeTokenRefresh = false
    private var lastClaudeTokenAttempt: Date?
    private var claudeTokenFailed = false

    private var agySnapshot: AntigravityUsageSnapshot?
    private var agyBridgeEnabled = false
    private var agyUsageError: String?
    private var agyTokenReport: TokenUsageReport?
    private var agyTokenTask: Task<Void, Never>?
    private var pendingAgyTokenRefresh = false
    private var lastAgyTokenAttempt: Date?
    private var agyTokenFailed = false

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
        defaults.register(defaults: [
            "codexEnabled": true,
            "claudeEnabled": true,
            "agyEnabled": true,
            "showAccountEmail": false
        ])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        claudeTokenReport = try? claudeTokenStore.load()
        agyTokenReport = try? agyTokenStore.load()
        configureStatusItem()
        configurePopover()
        installWakeObserver()
        watchClaudeUsage()
        watchAgyUsage()
        scheduleRefreshTimer()

        do {
            if codexEnabled { try syncAccountStateFromDisk() }
        } catch {
            refreshState = .failed("Failed to load account profiles")
        }
        // Codex off still shows its cached history; nothing scans, polls or watches Codex.
        if !codexEnabled, let profileID = try? accountStore.loadState().activeProfileID {
            tokenReport = try? TokenUsageReportCacheStore(cacheURL: TokenUsageReportCacheStore.defaultCacheURL(profileID: profileID)).load()
        }

        render()

        if let executableURL = Bundle.main.executableURL {
            Task.detached(priority: .utility) {
                ClaudeCodeStatusLine.updateHelperIfInstalled(executableURL: executableURL)
                AntigravityStatusLine.updateHelperIfInstalled(executableURL: executableURL)
            }
        }
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await PriceFeed.refreshIfStale()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }

        Task { [weak self] in
            guard let self else { return }

            if let repository = self.repository, let cached = await repository.loadCachedSnapshot() {
                self.snapshot = cached
                self.render()
            }

            self.triggerRefresh(reason: "startup")
            self.refreshTokenReportIfNeeded(force: false)
            self.refreshClaudeTokenReportIfNeeded(force: false)
            self.refreshClaudeUsage()
            self.refreshClaudeAccountUsage()
            self.refreshAgyUsage()
            self.refreshAgyTokenReportIfNeeded(force: false)
        }
    }

    func popoverWillOpen() {
        do {
            if codexEnabled { try syncAccountStateFromDisk() }
        } catch {
            refreshState = .failed("Failed to load account profiles")
        }

        refreshClaudeUsage()
        refreshAgyUsage()
        render()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
            return
        }
        guard let button = statusItem.button else { return }
        popoverWillOpen()
        updatePopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startOutsideClickMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
        stopOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                self.closePopover()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func updatePopoverSize() {
        guard let host = popoverHostController else { return }
        host.view.layoutSubtreeIfNeeded()
        let fitting = host.view.fittingSize
        if fitting.height > 80 {
            popover.contentSize = NSSize(width: UsagePopoverView.popoverWidth, height: fitting.height)
        }
    }

    @objc private func refreshNow() {
        triggerRefresh(reason: "manual", force: true)
        refreshTokenReportIfNeeded(force: true)
        refreshClaudeTokenReportIfNeeded(force: true)
        refreshClaudeUsage()
        refreshClaudeAccountUsage(force: true)
        refreshAgyUsage()
        refreshAgyTokenReportIfNeeded(force: true)
    }

    func selectPrimary(_ provider: PopoverProvider) {
        guard PopoverProvider.menuBarProviders.contains(provider) else { return }
        updateProviders { defaults.set(provider.rawValue, forKey: "primaryProvider") }
    }

    func toggleProvider(_ provider: PopoverProvider) {
        guard primaryProvider != provider else { return }
        switch provider {
        case .codex:
            updateProviders { defaults.set(!defaults.bool(forKey: "codexEnabled"), forKey: "codexEnabled") }
        case .claude:
            updateProviders { defaults.set(!defaults.bool(forKey: "claudeEnabled"), forKey: "claudeEnabled") }
        case .antigravity:
            updateProviders { defaults.set(!defaults.bool(forKey: "agyEnabled"), forKey: "agyEnabled") }
        }
    }

    private func toggleShowAccountEmail() {
        defaults.set(!showAccountEmail, forKey: "showAccountEmail")
        render()
    }

    private func updateProviders(_ change: () -> Void) {
        let wasCodex = codexEnabled, wasClaude = claudeEnabled, wasAgy = agyEnabled
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
        if agyEnabled != wasAgy {
            if agyEnabled {
                watchAgyUsage()
                refreshAgyUsage()
                refreshAgyTokenReportIfNeeded(force: true)
            } else {
                agyUsageWatcher.stop()
                agyTokenTask?.cancel()
                pendingAgyTokenRefresh = false
            }
        }
        render()
    }

    private func enableClaudeLocalUsage() {
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

    private func enableAgyStatusLine() {
        do {
            guard let executableURL = Bundle.main.executableURL else { return }
            try AntigravityStatusLine.install(executableURL: executableURL)
            agyUsageError = nil
            watchAgyUsage()
            refreshAgyUsage()
        } catch {
            agyUsageError = "Could not enable Antigravity statusline bridge"
            render()
        }
    }

    private func openAgyCLI() {
        closePopover()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"agy\""
        ]
        try? process.run()
    }

    func openUsageHistory() {
        closePopover()
        if usageHistoryWindowController == nil {
            usageHistoryWindowController = UsageHistoryWindowController(
                onRefresh: { [weak self] in self?.refreshNow() },
                onClose: { [weak self] in self?.usageHistoryWindowController = nil }
            )
        }
        usageHistoryWindowController?.show(
            report: tokenReport,
            claudeReport: claudeTokenReport,
            antigravityReport: agyTokenReport,
            planHistory: planHistory,
            snapshot: snapshot,
            accountPlan: activeAccountSnapshot?.planType ?? .unknown
        )
    }

    private func toggleLaunchAtLogin() {
        do {
            try launchAtLoginController.setEnabled(!launchAtLoginController.isEnabled)
            render()
        } catch {
            refreshState = .failed("Launch at login requires a bundled app")
            render()
        }
    }

    private func openCodex() {
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

        closePopover()
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

    private func copyDebugInfo() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(debugSummary(), forType: .string)
        popoverViewModel.copiedDebugFeedback = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            await MainActor.run {
                self?.popoverViewModel.copiedDebugFeedback = false
            }
        }
    }

    private func selectAccountProfile(id profileID: String) {
        guard refreshTask == nil else { return }
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

    private func addAccount() {
        guard refreshTask == nil else { return }
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

    private func signInCurrentAccount() {
        guard refreshTask == nil, let activeProfile else { return }
        do {
            try startLogin(for: activeProfile)
        } catch {
            refreshState = .failed(error.localizedDescription)
            render()
        }
    }

    private func logOut() {
        guard refreshTask == nil, let activeProfile else { return }

        refreshState = .refreshing
        render()

        let environment = codexEnvironment(for: activeProfile)
        refreshTask = Task { [weak self] in
            guard let self else { return }

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

    private func removeCurrentAccount() {
        guard refreshTask == nil,
              let activeProfile,
              activeProfile.kind == .managed else {
            return
        }

        let label = privacySafeProfileLabel(for: activeProfile, snapshot: activeAccountSnapshot)
        let alert = NSAlert()
        alert.messageText = "Remove \(label)?"
        alert.informativeText = "This removes the saved CodexPeek account profile from this Mac. You can add it again later by signing in."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

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

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        // Never set `toolTip` on NSStatusBarButton: in LSUIElement menu bar apps, macOS's
        // NSToolTipManager can leave the floating tooltip window stuck across all Spaces until clicked.
        button.toolTip = nil
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let host = NSHostingController(rootView: UsagePopoverView(vm: popoverViewModel))
        host.sizingOptions = [.preferredContentSize]
        popoverHostController = host
        popover.contentViewController = host

        popoverViewModel.onRefreshAll = { [weak self] in self?.refreshNow() }
        popoverViewModel.onRefreshClaude = { [weak self] in
            self?.refreshClaudeUsage()
            self?.refreshClaudeAccountUsage(force: true)
            self?.refreshClaudeTokenReportIfNeeded(force: true)
        }
        popoverViewModel.onRefreshAgy = { [weak self] in
            self?.refreshAgyUsage()
            self?.refreshAgyTokenReportIfNeeded(force: true)
        }
        popoverViewModel.onOpenHistory = { [weak self] in self?.openUsageHistory() }
        popoverViewModel.onSelectPrimary = { [weak self] in self?.selectPrimary($0) }
        popoverViewModel.onToggleProvider = { [weak self] in self?.toggleProvider($0) }
        popoverViewModel.onToggleShowEmail = { [weak self] in self?.toggleShowAccountEmail() }
        popoverViewModel.onToggleLaunchAtLogin = { [weak self] in self?.toggleLaunchAtLogin() }
        popoverViewModel.onCopyDebugInfo = { [weak self] in self?.copyDebugInfo() }
        popoverViewModel.onSelectCodexAccount = { [weak self] in self?.selectAccountProfile(id: $0) }
        popoverViewModel.onAddCodexAccount = { [weak self] in self?.addAccount() }
        popoverViewModel.onSignInCodexAccount = { [weak self] in self?.signInCurrentAccount() }
        popoverViewModel.onRemoveCodexAccount = { [weak self] in self?.removeCurrentAccount() }
        popoverViewModel.onOpenCodex = { [weak self] in self?.openCodex() }
        popoverViewModel.onLogOutCodex = { [weak self] in self?.logOut() }
        popoverViewModel.onEnableClaudeBridge = { [weak self] in self?.enableClaudeLocalUsage() }
        popoverViewModel.onEnableAgyBridge = { [weak self] in self?.enableAgyStatusLine() }
        popoverViewModel.onOpenAgyCLI = { [weak self] in self?.openAgyCLI() }
        popoverViewModel.onQuit = { [weak self] in self?.quit() }
        popoverViewModel.onPreferredSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.updatePopoverSize() }
        }
    }

    private func installWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshClaudeUsage()
                self?.refreshAgyUsage()
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
                self?.refreshAgyUsage()
                self?.refreshAgyTokenReportIfNeeded(force: false)
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

        guard let repository, let activeProfile else { return }
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
            guard let self else { return }

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
                guard !Task.isCancelled, self.codexEnabled, self.activeProfile?.id == profileID else { return }
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
                guard !Task.isCancelled, self.codexEnabled, self.activeProfile?.id == profileID else { return }
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
        guard profile.kind == .managed else { return false }
        return snapshot.isStale || (snapshot.primary == nil && snapshot.secondary == nil)
    }

    private func recoverDuplicateProfile(from failedProfile: AccountProfile) async -> AccountProfile? {
        guard let accountState else { return nil }
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
        switch primaryProvider {
        case .codex:
            statusItem.button?.image = iconRenderer.render(
                primaryPercent: snapshot?.primary?.usedPercent,
                secondaryPercent: snapshot?.secondary?.usedPercent,
                refreshState: refreshState,
                isWeeklyExhausted: isWeeklyExhausted
            )
            statusItem.button?.setAccessibilityLabel("Codex usage")
        case .claude:
            statusItem.button?.image = iconRenderer.render(
                primaryPercent: claudeSnapshot?.fiveHour?.usedPercent,
                secondaryPercent: claudeSnapshot?.sevenDay?.usedPercent,
                refreshState: claudeUsageTask != nil ? .refreshing : .idle,
                isWeeklyExhausted: claudeSnapshot?.sevenDay?.isExhausted == true
            )
            statusItem.button?.setAccessibilityLabel("Claude Code usage")
        case .antigravity:
            statusItem.button?.image = iconRenderer.render(
                primaryPercent: agySnapshot?.primaryBucket?.window.usedPercent,
                secondaryPercent: agySnapshot?.secondaryBucket?.window.usedPercent,
                refreshState: agyTokenTask != nil ? .refreshing : .idle,
                isWeeklyExhausted: agySnapshot?.secondaryBucket?.window.isExhausted == true
            )
            statusItem.button?.setAccessibilityLabel("Antigravity usage")
        }
        statusItem.button?.toolTip = nil

        let vm = popoverViewModel
        vm.primaryProvider = primaryProvider
        vm.codexEnabled = codexEnabled
        vm.claudeEnabled = claudeEnabled
        vm.agyEnabled = agyEnabled
        vm.showAccountEmail = showAccountEmail
        vm.launchAtLogin = launchAtLoginController.isEnabled

        vm.codexSnapshot = snapshot
        vm.codexTokenReport = tokenReport
        vm.codexTokenRefreshing = tokenReportTask != nil
        vm.codexRefreshState = refreshState
        vm.codexAccountStatus = accountStatusMessage()
        if let activeProfile {
            vm.codexProfileLabel = privacySafeProfileLabel(for: activeProfile, snapshot: snapshot?.account ?? activeAccountSnapshot)
        } else {
            vm.codexProfileLabel = "Codex Account"
        }
        vm.codexSignedIn = activeAccountSnapshot?.isSignedIn == true
        vm.codexCanRemoveAccount = activeProfile?.kind == .managed
        vm.codexActionsEnabled = refreshTask == nil
        vm.codexAccounts = buildAccountChoices()

        vm.claudeSnapshot = claudeSnapshot
        vm.claudeTokenReport = claudeTokenReport
        vm.claudeTokenRefreshing = claudeTokenTask != nil
        vm.claudeTokenFailed = claudeTokenFailed
        vm.claudeUsageRefreshing = claudeUsageTask != nil
        vm.claudeUsageError = claudeUsageError
        vm.claudeBridgeEnabled = claudeBridgeEnabled

        vm.agySnapshot = agySnapshot
        vm.agyBridgeEnabled = agyBridgeEnabled
        vm.agyUsageError = agyUsageError
        vm.agyTokenReport = agyTokenReport
        vm.agyModelShares = AntigravityTokenUsageSource.modelShares(from: agyTokenReport)
        vm.agyTokenRefreshing = agyTokenTask != nil
        vm.agyTokenFailed = agyTokenFailed

        vm.ensureValidTab()
        if popover.isShown {
            DispatchQueue.main.async { [weak self] in self?.updatePopoverSize() }
        }

        usageHistoryWindowController?.update(
            report: tokenReport,
            claudeReport: claudeTokenReport,
            antigravityReport: agyTokenReport,
            planHistory: planHistory,
            snapshot: snapshot,
            accountPlan: activeAccountSnapshot?.planType ?? .unknown
        )
    }

    /// Single privacy-aware label used across the Codex header, account picker, removal dialog, and debug info.
    func privacySafeProfileLabel(for profile: AccountProfile, snapshot: CodexAccountSnapshot?) -> String {
        if showAccountEmail {
            if let snapshot, snapshot.isSignedIn {
                if profile.kind == .managed, let name = profile.name, !name.isEmpty {
                    return name
                }
                return snapshot.displayName
            }
            return profile.displayName
        }

        if profile.kind == .systemDefault {
            return "Default Account"
        }
        if let name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           !name.contains("@") {
            return name
        }
        let managed = (accountState?.profiles ?? []).filter { $0.kind == .managed }
        if managed.count > 1, let idx = managed.firstIndex(where: { $0.id == profile.id }) {
            return "Managed Account \(idx + 1)"
        }
        return "Managed Account"
    }

    private func buildAccountChoices() -> [PopoverAccountChoice] {
        guard let accountState else { return [] }
        return accountState.profiles.map { profile in
            let snap = accountSnapshotsByProfileID[profile.id]
            let baseLabel = privacySafeProfileLabel(for: profile, snapshot: snap)
            let title: String
            if let snap, snap.isSignedIn {
                title = baseLabel
            } else if pendingLoginProfileID == profile.id {
                title = "\(baseLabel) · Finish sign-in"
            } else {
                title = "\(baseLabel) · Not signed in"
            }
            let plan = (snap?.planType != .unknown ? snap?.planType.displayName : nil)
            return PopoverAccountChoice(
                id: profile.id,
                title: title,
                subtitle: plan,
                isActive: profile.id == accountState.activeProfileID
            )
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
                guard let snapshot else { return nil }
                return (profile.id, snapshot)
            }
        )
    }

    private func removeDuplicateManagedProfilesIfNeeded() throws {
        guard var state = accountState else { return }

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
        guard var state = accountState else { return }

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
        guard FileManager.default.fileExists(atPath: profile.authURL.path) else { return true }
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
            _ = try codexDesktopAuthStore.prepareSystemAuth(for: profile, among: profiles)
        }
        if let accountState {
            updateAccountState(accountState)
        }

        snapshot = nil
        refreshState = .idle
        configureActiveProfile(profile)
        render()

        Task { [weak self] in
            guard let self else { return }

            if loadCachedSnapshot, let repository = self.repository, let cached = await repository.loadCachedSnapshot() {
                guard self.activeProfile?.id == profile.id else { return }
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
        guard tokenReportGeneration == generation else { return }
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

    private func refreshAgyTokenReportIfNeeded(force: Bool) {
        guard agyEnabled else { return }
        guard agyTokenTask == nil else {
            pendingAgyTokenRefresh = pendingAgyTokenRefresh || force
            return
        }
        let lastAttempt = lastAgyTokenAttempt ?? (agyTokenReport?.historyIncludesAllRetainedSessions == true ? agyTokenReport?.generatedAt : nil)
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.refreshInterval { return }
        lastAgyTokenAttempt = Date()
        let source = agyTokenSource
        let store = agyTokenStore
        agyTokenTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.agyTokenTask = nil
                self.render()
                if self.pendingAgyTokenRefresh {
                    self.pendingAgyTokenRefresh = false
                    self.refreshAgyTokenReportIfNeeded(force: true)
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
                guard !Task.isCancelled, self.agyEnabled else { return }
                self.agyTokenReport = report
                self.agyTokenFailed = false
            } catch {
                guard !Task.isCancelled, self.agyEnabled else { return }
                self.agyTokenFailed = true
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
            guard let self else { return }

            for _ in 0..<120 {
                if Task.isCancelled { return }
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
        guard let activeProfile else { return nil }
        if pendingLoginProfileID == activeProfile.id {
            return "Finish sign-in in Terminal"
        }
        guard activeAccountSnapshot?.isSignedIn != true else { return nil }
        return "Sign in this account from Accounts"
    }

    private var activeAccountSnapshot: CodexAccountSnapshot? {
        guard let activeProfile else { return nil }
        return accountSnapshotsByProfileID[activeProfile.id] ?? nil
    }

    func debugSummary() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let account = showAccountEmail
            ? (snapshot?.account.email ?? snapshot?.displayAccountName ?? activeAccountSnapshot?.displayName ?? "unknown")
            : "(hidden)"
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
        let profileLabel = activeProfile.map { privacySafeProfileLabel(for: $0, snapshot: activeAccountSnapshot) } ?? "unknown"
        let profileHome = activeProfile?.homeURL.path ?? "unknown"
        let agyWeekCost = agyTokenReport.map { UIFormatters.costString($0.week.estimatedCostUSD) } ?? "unavailable"
        let agyAllCost = agyTokenReport.map { UIFormatters.costString($0.allTime.estimatedCostUSD) } ?? "unavailable"
        let agyBuckets = agySnapshot?.activeBuckets.map { "\($0.title): \($0.window.usedPercent)%" }.joined(separator: ", ") ?? "unavailable"

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
            "Claude \(claudeSnapshot?.modelWeeklyName ?? "model") weekly usage: \(claudeSnapshot?.modelWeekly.map { "\($0.usedPercent)%" } ?? "unavailable")",
            "Claude local bridge: \(claudeBridgeEnabled ? "enabled" : "disabled")",
            "Claude stale: \(claudeSnapshot?.isStale == true ? "yes" : "no")",
            "Claude updated: \(claudeSnapshot.map { UIFormatters.usageUpdatedString(from: $0.updatedAt) } ?? "never")",
            "Antigravity quota: \(agyBuckets)",
            "Antigravity statusline bridge: \(agyBridgeEnabled ? "enabled" : "disabled")",
            "Antigravity 7-day API-equivalent estimate: \(agyWeekCost)",
            "Antigravity all-time API-equivalent estimate: \(agyAllCost)",
            "Antigravity sessions: \(agyTokenReport?.allTime.sessionCount ?? 0)"
        ].joined(separator: "\n")
    }

    private func watchClaudeUsage() {
        guard claudeEnabled else { return }
        claudeUsageWatcher.start(watching: ClaudeCodeStatusLine.cacheURL) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshClaudeUsage() }
        }
    }

    private func watchAgyUsage() {
        guard agyEnabled else { return }
        agyUsageWatcher.start(watching: AntigravityStatusLine.cacheURL) { [weak self] in
            Task { @MainActor [weak self] in self?.refreshAgyUsage() }
        }
    }

    private func refreshAgyUsage() {
        guard agyEnabled else { return }
        do {
            let cached = try AntigravityStatusLine.load()
            if let cached, cached.updatedAt != agySnapshot?.updatedAt, !cached.isStale {
                agyUsageError = nil
            }
            agySnapshot = cached
            agyBridgeEnabled = try AntigravityStatusLine.isInstalled()
        } catch {
            agySnapshot?.isStale = true
            agyUsageError = "Could not read local Antigravity usage"
        }
        render()
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
            if (claudeSnapshot?.modelWeekly?.resetsAt ?? .distantFuture) <= now { claudeSnapshot?.modelWeekly = nil }
            claudeUsageError = "Could not read local Claude usage"
        }
        render()
    }

    private func refreshClaudeAccountUsage(force: Bool = false) {
        let due = claudeSnapshot.map {
            $0.isStale || Date().timeIntervalSince($0.updatedAt) >= Self.refreshInterval - Self.refreshTolerance
        } ?? true
        guard claudeEnabled, claudeUsageTask == nil, force || due else { return }
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
}
