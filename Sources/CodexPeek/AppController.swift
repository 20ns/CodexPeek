@preconcurrency import AppKit
import Foundation

@MainActor
final class AppController: NSObject, NSMenuDelegate {
    private static let refreshInterval: TimeInterval = 60
    private static let refreshTolerance: TimeInterval = 5
    private static let minimumRefreshSpacing: TimeInterval = 10

    private let repository: UsageRepository
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let iconRenderer = StatusIconRenderer()
    private let launchAtLoginController = LaunchAtLoginController()
    private let codexAppOpener = CodexAppOpener()
    private let authFileWatcher = AuthFileWatcher()

    private let headerView = HeaderMenuItemView()
    private let primaryUsageView = UsageMenuItemView()
    private let secondaryUsageView = UsageMenuItemView()
    private let statusView = StatusMenuItemView()

    private let headerItem = NSMenuItem()
    private let primaryUsageItem = NSMenuItem()
    private let secondaryUsageItem = NSMenuItem()
    private let statusItemView = NSMenuItem()
    private let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
    private let copyDebugInfoItem = NSMenuItem(title: "Copy Debug Info", action: #selector(copyDebugInfo), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let logoutItem = NSMenuItem(title: "Log Out", action: #selector(logOut), keyEquivalent: "")
    private let openCodexItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var snapshot: CodexUsageSnapshot?
    private var refreshState: RefreshState = .idle
    private var wakeObserver: NSObjectProtocol?
    private var lastRefreshStartAt: Date?
    private var lastRenderModel: RenderModel?

    init(repository: UsageRepository) {
        self.repository = repository
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        configureStatusItem()
        configureMenu()
        installWakeObserver()
        installAuthFileWatcher()
        scheduleRefreshTimer()
        render()

        Task { [weak self] in
            guard let self else {
                return
            }

            if let cached = await repository.loadCachedSnapshot() {
                self.snapshot = cached
                self.render()
            }

            self.triggerRefresh(reason: "startup")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
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
        codexAppOpener.openCodex()
    }

    @objc private func copyDebugInfo() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(debugSummary(), forType: .string)
    }

    @objc private func logOut() {
        guard refreshTask == nil else {
            return
        }

        refreshState = .refreshing
        render()

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
                try await codexAppOpener.logout()
                self.snapshot = nil
                self.refreshState = .idle
                shouldRefreshAfterLogout = true
            } catch {
                self.refreshState = .failed(error.localizedDescription)
            }
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
        statusItemView.view = statusView

        refreshItem.target = self
        copyDebugInfoItem.target = self
        launchAtLoginItem.target = self
        logoutItem.target = self
        openCodexItem.target = self
        quitItem.target = self

        menu.addItem(headerItem)
        menu.addItem(.separator())
        menu.addItem(primaryUsageItem)
        menu.addItem(secondaryUsageItem)
        menu.addItem(statusItemView)
        menu.addItem(.separator())
        menu.addItem(refreshItem)
        menu.addItem(copyDebugInfoItem)
        menu.addItem(launchAtLoginItem)
        menu.addItem(logoutItem)
        menu.addItem(openCodexItem)
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

    private func installAuthFileWatcher() {
        authFileWatcher.start { [weak self] in
            Task { @MainActor [weak self] in
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
        guard refreshTask == nil else {
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

            defer {
                self.refreshTask = nil
                self.render()
            }

            do {
                let snapshot = try await repository.refresh()
                self.snapshot = snapshot
                self.refreshState = .idle
            } catch {
                self.refreshState = .failed(error.localizedDescription)
            }

            self.statusItem.button?.toolTip = "Codex usage (\(reason) refresh)"
        }
    }

    private func render() {
        let renderModel = RenderModel(
            snapshot: snapshot,
            refreshState: refreshState,
            launchAtLoginEnabled: launchAtLoginController.isEnabled,
            refreshEnabled: refreshTask == nil
        )

        guard renderModel != lastRenderModel else {
            return
        }
        lastRenderModel = renderModel

        let primaryPercent = snapshot?.primary?.usedPercent
        let secondaryPercent = snapshot?.secondary?.usedPercent
        statusItem.button?.image = iconRenderer.render(
            primaryPercent: primaryPercent,
            secondaryPercent: secondaryPercent,
            refreshState: refreshState
        )

        headerView.update(snapshot: snapshot, refreshState: refreshState)
        primaryUsageView.update(title: "5-hour window", window: snapshot?.primary)
        secondaryUsageView.update(title: "Weekly window", window: snapshot?.secondary)
        statusView.update(snapshot: snapshot, refreshState: refreshState)
        launchAtLoginItem.state = launchAtLoginController.isEnabled ? .on : .off
        refreshItem.isEnabled = refreshTask == nil
        copyDebugInfoItem.isEnabled = true
        logoutItem.isEnabled = refreshTask == nil
    }

    private func debugSummary() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let account = snapshot?.account.email ?? snapshot?.displayAccountName ?? "unknown"
        let plan = snapshot?.account.planType.displayName ?? "Unknown"
        let source = snapshot?.source.rawValue ?? "none"
        let stale = snapshot?.isStale == true ? "yes" : "no"
        let primary = snapshot?.primary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let secondary = snapshot?.secondary.map { "\($0.usedPercent)%" } ?? "unavailable"
        let updatedAt = snapshot.map { UIFormatters.usageUpdatedString(from: $0.lastUpdatedAt) } ?? "never"

        return [
            "CodexPeek \(version) (\(build))",
            "Account: \(account)",
            "Plan: \(plan)",
            "Source: \(source)",
            "Stale: \(stale)",
            "5h usage: \(primary)",
            "Weekly usage: \(secondary)",
            "Last updated: \(updatedAt)"
        ].joined(separator: "\n")
    }
}

private struct RenderModel: Equatable {
    let snapshot: CodexUsageSnapshot?
    let refreshState: RefreshState
    let launchAtLoginEnabled: Bool
    let refreshEnabled: Bool
}
