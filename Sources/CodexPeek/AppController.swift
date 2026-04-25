@preconcurrency import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 60
    private static let refreshTolerance: TimeInterval = 5
    private static let minimumRefreshSpacing: TimeInterval = 10

    private let accountStore: AccountProfileStore
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let accountsMenu = NSMenu(title: "Accounts")
    private let iconRenderer = StatusIconRenderer()
    private let launchAtLoginController = LaunchAtLoginController()
    private let codexAppOpener = CodexAppOpener()
    private let codexDesktopAuthStore = CodexDesktopAuthStore()
    private let authFileWatcher = AuthFileWatcher()

    private let headerView = HeaderMenuItemView()
    private let primaryUsageView = UsageMenuItemView()
    private let secondaryUsageView = UsageMenuItemView()
    private let sparkUsageView = CompactSupplementalUsageMenuItemView()
    private let statusView = StatusMenuItemView()

    private let headerItem = NSMenuItem()
    private let primaryUsageItem = NSMenuItem()
    private let secondaryUsageItem = NSMenuItem()
    private let sparkUsageItem = NSMenuItem()
    private let statusItemView = NSMenuItem()
    private let accountsItem = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
    private let copyDebugInfoItem = NSMenuItem(title: "Copy Debug Info", action: #selector(copyDebugInfo), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let logoutItem = NSMenuItem(title: "Log Out", action: #selector(logOut), keyEquivalent: "")
    private let openCodexItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
    private let removeAccountItem = NSMenuItem(title: "Remove Current Account…", action: #selector(removeCurrentAccount), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    private var repository: UsageRepository?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var snapshot: CodexUsageSnapshot?
    private var refreshState: RefreshState = .idle
    private var wakeObserver: NSObjectProtocol?
    private var lastRefreshStartAt: Date?

    private var accountState: AccountProfilesState?
    private var activeProfile: AccountProfile?
    private var accountSnapshotsByProfileID: [String: CodexAccountSnapshot] = [:]
    private var pendingLoginProfileID: String?
    private var loginMonitorTask: Task<Void, Never>?

    init(accountStore: AccountProfileStore) {
        self.accountStore = accountStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        configureStatusItem()
        configureMenu()
        installWakeObserver()
        scheduleRefreshTimer()

        do {
            try codexDesktopAuthStore.bootstrapDefaultSnapshotIfNeeded()
            try syncAccountStateFromDisk()
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
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        do {
            try syncAccountStateFromDisk()
        } catch {
            refreshState = .failed("Failed to load account profiles")
        }

        render()
        triggerRefresh(reason: "menu")
    }

    @objc private func refreshNow() {
        triggerRefresh(reason: "manual", force: true)
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
                if activeProfile.kind == .managed {
                    _ = try self.codexDesktopAuthStore.restoreDefaultIfSystemAuthOwned(
                        by: activeProfile,
                        among: self.accountState?.profiles ?? []
                    )
                } else {
                    try self.codexDesktopAuthStore.clearOwnerIfNeeded(
                        for: activeProfile,
                        among: self.accountState?.profiles ?? []
                    )
                }
                try self.syncAccountStateFromDisk()
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
        statusItem.button?.toolTip = "Codex usage"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        headerItem.view = headerView
        primaryUsageItem.view = primaryUsageView
        secondaryUsageItem.view = secondaryUsageView
        sparkUsageItem.view = sparkUsageView
        statusItemView.view = statusView
        accountsItem.submenu = accountsMenu

        refreshItem.target = self
        copyDebugInfoItem.target = self
        launchAtLoginItem.target = self
        logoutItem.target = self
        openCodexItem.target = self
        removeAccountItem.target = self
        quitItem.target = self

        menu.addItem(headerItem)
        menu.addItem(.separator())
        menu.addItem(primaryUsageItem)
        menu.addItem(secondaryUsageItem)
        menu.addItem(sparkUsageItem)
        menu.addItem(statusItemView)
        menu.addItem(.separator())
        menu.addItem(accountsItem)
        menu.addItem(.separator())
        menu.addItem(refreshItem)
        menu.addItem(copyDebugInfoItem)
        menu.addItem(launchAtLoginItem)
        menu.addItem(logoutItem)
        menu.addItem(openCodexItem)
        menu.addItem(removeAccountItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    private func installWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRefresh(reason: "wake")
            }
        }
    }

    private func installAuthFileWatcher(for profile: AccountProfile) {
        authFileWatcher.start(watching: profile.homeURL) { [weak self] in
            Task { @MainActor [weak self] in
                do {
                    try self?.syncAccountStateFromDisk()
                } catch {
                    self?.refreshState = .failed("Failed to reload account profile")
                }
                self?.triggerRefresh(reason: "auth-change", force: true)
            }
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRefresh(reason: "timer")
            }
        }
        refreshTimer?.tolerance = Self.refreshTolerance
    }

    private func triggerRefresh(reason: String, force: Bool = false) {
        do {
            try syncAccountStateFromDisk()
        } catch {
            refreshState = .failed("Failed to sync account profiles")
            render()
            return
        }

        guard refreshTask == nil, let repository, let activeProfile else {
            return
        }

        if !force,
           let lastRefreshStartAt,
           Date().timeIntervalSince(lastRefreshStartAt) < Self.minimumRefreshSpacing {
            return
        }

        lastRefreshStartAt = Date()
        refreshState = .refreshing
        render()

        refreshTask = Task { [weak self] in
            guard let self else {
                return
            }

            var recoveredProfile: AccountProfile?

            defer {
                self.refreshTask = nil
                self.render()
                if let recoveredProfile {
                    try? self.switchToProfile(
                        recoveredProfile,
                        loadCachedSnapshot: true,
                        refreshReason: "profile-recovery"
                    )
                }
            }

            do {
                let snapshot = try await repository.refresh()
                if self.shouldAttemptDuplicateProfileRecovery(for: activeProfile, snapshot: snapshot),
                   let candidate = await self.recoverDuplicateProfile(from: activeProfile) {
                    self.snapshot = nil
                    self.refreshState = .idle
                    recoveredProfile = candidate
                    return
                }
                self.snapshot = snapshot
                self.refreshState = .idle
                try self.syncAccountStateFromDisk()
            } catch {
                if let candidate = await self.recoverDuplicateProfile(from: activeProfile) {
                    self.snapshot = nil
                    self.refreshState = .idle
                    recoveredProfile = candidate
                    return
                }
                self.refreshState = .failed(error.localizedDescription)
            }

            self.statusItem.button?.toolTip = "Codex usage (\(reason) refresh)"
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
            let repository = makeRepository(for: candidate)
            guard let snapshot = try? await repository.refresh(),
                  !snapshot.isStale,
                  snapshot.primary != nil || snapshot.secondary != nil else {
                continue
            }

            guard let updatedState = try? accountStore.setActiveProfileID(candidate.id) else {
                return candidate
            }

            updateAccountState(updatedState)
            return updatedState.activeProfile()
        }

        return nil
    }

    private func render() {
        let primaryPercent = snapshot?.primary?.usedPercent
        let secondaryPercent = snapshot?.secondary?.usedPercent
        let isWeeklyExhausted = snapshot?.isWeeklyExhausted == true
        statusItem.button?.image = iconRenderer.render(
            primaryPercent: primaryPercent,
            secondaryPercent: secondaryPercent,
            refreshState: refreshState,
            isWeeklyExhausted: isWeeklyExhausted
        )

        headerView.update(snapshot: snapshot, refreshState: refreshState)
        primaryUsageView.update(
            title: "5-hour window",
            window: snapshot?.primary,
            isDimmed: isWeeklyExhausted,
            overrideDetail: isWeeklyExhausted ? "Weekly limit reached • 5-hour window resumes after the weekly reset" : nil
        )
        secondaryUsageView.update(title: "Weekly window", window: snapshot?.secondary)
        sparkUsageView.update(snapshot: snapshot?.spark)
        sparkUsageItem.isHidden = snapshot?.spark == nil
        statusView.update(snapshot: snapshot, refreshState: refreshState, accountStatus: accountStatusMessage())
        renderAccountsMenu()

        launchAtLoginItem.state = launchAtLoginController.isEnabled ? .on : .off
        refreshItem.isEnabled = refreshTask == nil
        copyDebugInfoItem.isEnabled = true
        logoutItem.isEnabled = refreshTask == nil && activeAccountSnapshot?.isSignedIn == true
        openCodexItem.title = "Open Codex with Selected Account"
        openCodexItem.isEnabled = activeAccountSnapshot?.isSignedIn == true
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
    }

    private func title(for profile: AccountProfile) -> String {
        var parts = [profile.displayName]

        if let snapshot = accountSnapshotsByProfileID[profile.id], snapshot.isSignedIn {
            parts.append(snapshot.displayName)
            if snapshot.planType != .unknown {
                parts.append(snapshot.planType.displayName)
            }
            if isDuplicateSignIn(profileID: profile.id, snapshot: snapshot) {
                parts.append("Duplicate sign-in")
            }
        } else if pendingLoginProfileID == profile.id {
            parts.append("Finish sign-in in Terminal")
        } else {
            parts.append("Not signed in")
        }

        return parts.joined(separator: " • ")
    }

    private func isDuplicateSignIn(profileID: String, snapshot: CodexAccountSnapshot) -> Bool {
        accountSnapshotsByProfileID.contains { entry in
            let (otherProfileID, otherSnapshot) = entry
            guard otherProfileID != profileID else {
                return false
            }

            return otherSnapshot.isSignedIn
                && otherSnapshot.authMode == snapshot.authMode
                && otherSnapshot.email == snapshot.email
                && otherSnapshot.planType == snapshot.planType
        }
    }

    private func syncAccountStateFromDisk() throws {
        let state = try accountStore.loadState()
        guard let profile = state.activeProfile() else {
            throw CodexUsageError.invalidResponse("missing active account profile")
        }

        try codexDesktopAuthStore.reconcileSystemAuth(among: state.profiles)
        updateAccountState(state)

        if activeProfile?.id != profile.id || activeProfile?.homePath != profile.homePath || repository == nil {
            configureActiveProfile(profile)
        } else {
            activeProfile = profile
        }

        if profile.kind == .systemDefault,
           try codexDesktopAuthStore.shouldSyncDefaultSnapshotFromSystemAuth(among: state.profiles) {
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

    private func configureActiveProfile(_ profile: AccountProfile) {
        activeProfile = profile
        repository = makeRepository(for: profile)
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

                do {
                    try self.syncAccountStateFromDisk()
                    if let snapshot = self.accountSnapshotsByProfileID[profile.id], snapshot.isSignedIn {
                        self.pendingLoginProfileID = nil
                        try self.applySignedInProfileName(profileID: profile.id, snapshot: snapshot)
                        self.render()
                        if self.activeProfile?.id == profile.id {
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
        let source = snapshot?.source.rawValue ?? "none"
        let stale = snapshot?.isStale == true ? "yes" : "no"
        let primary = snapshot?.primary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let secondary = snapshot?.secondary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let sparkPrimary = snapshot?.spark?.primary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let sparkWeekly = snapshot?.spark?.secondary.map { "\($0.usedPercent)%" } ?? "unavailable"
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
            "Last updated: \(updatedAt)"
        ].joined(separator: "\n")
    }
}
