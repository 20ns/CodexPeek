#!/bin/zsh
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT

# Exercise the real controller callbacks, with account IO and caches isolated.
python3 - "$ROOT_DIR" "$CHECK_DIR" <<'PY'
from pathlib import Path
import re, sys
root, check = map(Path, sys.argv[1:])
source = (root / 'Sources/CodexPeek/AppController.swift').read_text()
source, count = re.subn(r'    private func syncAccountStateFromDisk\(\) throws \{.*?\n    \}\n',
                       '    private func syncAccountStateFromDisk() throws {}\n', source, count=1, flags=re.S)
assert count == 1
(check / 'AppController.swift').write_text(source.replace('private ', ''))
source = (root / 'Sources/CodexPeek/AccountProfiles.swift').read_text()
source, count = re.subn(r'    static func baseSupportURL\(\) -> URL \{.*?\n    \}',
                       '    static func baseSupportURL() -> URL { URL(fileURLWithPath: CommandLine.arguments[1]) }',
                       source, count=1, flags=re.S)
assert count == 1
(check / 'AccountProfiles.swift').write_text(source)
PY

cat > "$CHECK_DIR/main.swift" <<'SWIFT'
import AppKit
import Foundation

// Replace only account IO; exercise the real Claude controller callbacks offline.
@MainActor final class ClaudeCodeUsageSource {
    var calls = 0
    var nextSnapshot: ClaudeCodeUsageSnapshot?
    var failure = false
    var delay: Duration = .zero
    func refresh(force: Bool = false) async throws -> ClaudeCodeUsageSnapshot? {
        calls += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        if failure { throw CodexUsageError.timedOut }
        return nextSnapshot
    }
}

final class CountingSource: CodexUsageLiveSource, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    private func record() { lock.withLock { calls += 1 } }
    func fetchUsageSnapshot() async throws -> CodexUsageSnapshot {
        record()
        try await Task.sleep(for: .milliseconds(50))
        return CodexUsageSnapshot(account: .empty, primary: nil, secondary: nil,
                                  source: .live, lastUpdatedAt: Date(), isStale: false)
    }
}

final class PausedTokenSource: TokenUsageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    let resume = DispatchSemaphore(value: 0)
    var didStart: Bool { lock.withLock { started } }
    func usageReport() throws -> TokenUsageReport {
        lock.withLock { started = true }
        _ = resume.wait(timeout: .now() + 5)
        return .empty
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let profile = AccountProfile(id: "fixture", homePath: root.path, kind: .systemDefault)
try Data("{}".utf8).write(to: profile.authURL)
NSApplication.shared.setActivationPolicy(.prohibited)
let suiteName = "CodexPeekProviderCheck.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
let controller = AppController(accountStore: AccountProfileStore(
    stateURL: root.appendingPathComponent("accounts.json"), managedProfilesRootURL: root), defaults: defaults)
controller.configureMenu()
precondition(controller.codexEnabled && controller.claudeEnabled, "Both providers must default to enabled")
let source = CountingSource()
controller.activeProfile = profile
controller.repository = UsageRepository(
    liveSource: source, sessionLogSource: CodexSessionLogUsageSource(sessionsRootURL: profile.sessionsURL),
    cacheStore: SnapshotCacheStore(cacheURL: root.appendingPathComponent("usage.json")),
    accountInfoSource: AuthJSONAccountInfoSource(authURL: profile.authURL))
controller.scheduleRefreshTimer()
defer { controller.refreshTimer?.invalidate(); controller.authFileWatcher.stop() }
precondition(controller.refreshTimer?.timeInterval == 300, "Background timer must be five minutes")

@MainActor func settle() {
    let deadline = Date().addingTimeInterval(5)
    repeat {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    } while controller.refreshTask != nil && Date() < deadline
    precondition(controller.refreshTask == nil, "Refresh did not complete")
}

controller.refreshNow()
settle()
precondition(source.count == 1, "Manual refresh must pull immediately")

// Make the controller eligible, so its throttle cannot hide unwanted callbacks.
controller.lastRefreshStartAt = Date().addingTimeInterval(-301)
controller.menuWillOpen(NSMenu())
controller.openUsageHistory()
controller.usageHistoryWindowController?.close()
controller.installWakeObserver()
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
controller.installAuthFileWatcher(for: profile)
try Data("{\"changed\":true}".utf8).write(to: profile.authURL, options: .atomic)
RunLoop.main.run(until: Date().addingTimeInterval(1.1))
precondition(source.count == 1, "Menu, history, wake and auth writes must not pull usage")

controller.refreshTimer?.fire()
settle()
precondition(source.count == 2, "Five-minute timer must pull usage")
controller.refreshTimer?.fire()
settle()
precondition(source.count == 2, "Background pulls must respect the five-minute minimum")
controller.refreshNow()
settle()
precondition(source.count == 3, "Manual refresh must bypass the background throttle")
controller.refreshNow()
controller.refreshNow()
controller.refreshNow()
controller.refreshTimer?.fire()
settle()
precondition(source.count == 5, "Forced refreshes must coalesce while a fetch is running; timer must not queue")
let remaining = controller.refreshTimer!.fireDate.timeIntervalSinceNow
precondition((295...300).contains(remaining), "Manual refresh must restart the five-minute wait")
controller.tokenUsageSource = CodexTokenUsageSource(sessionsRootURL: profile.sessionsURL)
controller.tokenReportStore = TokenUsageReportCacheStore(cacheURL: root.appendingPathComponent("tokens.json"))
controller.refreshTokenReportIfNeeded(force: false)
let tokenDeadline = Date().addingTimeInterval(2)
while controller.tokenReportTask != nil && Date() < tokenDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
precondition(controller.tokenReportTask == nil && controller.tokenReport != nil,
             "Token refresh must start without a startup sleep")

@MainActor func settleClaude() {
    let deadline = Date().addingTimeInterval(2)
    while controller.claudeUsageTask != nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    precondition(controller.claudeUsageTask == nil, "Claude refresh did not complete")
}
settleClaude()
let observed = Date()
let payload = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":\(observed.timeIntervalSince1970 + 3600)}}}"
let fresh = try ClaudeCodeStatusLine.capture(Data(payload.utf8), now: observed)!
controller.claudeUsageSource.nextSnapshot = fresh
controller.refreshClaudeAccountUsage(force: true)
settleClaude()
precondition(controller.claudeSnapshot == fresh && controller.claudeUsageError == nil,
             "Account usage must populate Claude bars without statusline activity")
precondition(!controller.claudeFiveHourItem.isHidden && controller.claudeWeeklyItem.isHidden,
             "Received quota must be visible and unknown windows must stay unavailable")
let calls = controller.claudeUsageSource.calls
controller.menuWillOpen(NSMenu())
precondition(controller.claudeUsageSource.calls == calls, "Opening the menu must not request account usage")
controller.claudeSnapshot = try ClaudeCodeStatusLine.capture(Data(payload.utf8), now: observed.addingTimeInterval(-200))
controller.refreshClaudeAccountUsage()
precondition(controller.claudeUsageTask == nil, "A recent Claude reading must not be refetched by the timer")
controller.claudeSnapshot = try ClaudeCodeStatusLine.capture(Data(payload.utf8), now: observed.addingTimeInterval(-280))
controller.refreshClaudeAccountUsage()
settleClaude()
precondition(controller.claudeUsageSource.calls == calls + 1, "Timer tolerance must not skip a due Claude refresh")
controller.claudeUsageSource.failure = true
controller.refreshClaudeAccountUsage(force: true)
settleClaude()
precondition(controller.claudeSnapshot?.fiveHour?.usedPercent == 5 && controller.claudeSnapshot?.isStale == true,
             "An account failure must retain the last valid quota")
let failure = controller.claudeUsageError
controller.menuWillOpen(NSMenu())
precondition(failure != nil && controller.claudeUsageError == failure,
             "Opening the menu must preserve the account failure")
precondition(controller.claudeSnapshot?.isStale == true, "A failed reading must remain marked stale")

precondition(controller.menu.items.first === controller.headerItem && controller.statusItem.button?.toolTip == "Codex usage",
             "Codex must be the default primary provider")
controller.selectPrimary(controller.claudePrimaryItem)
precondition(controller.menu.items.first === controller.claudeSectionItem && controller.statusItem.button?.toolTip == "Claude Code usage",
             "The primary provider must lead the menu and own the menu-bar icon")
precondition(controller.claudePrimaryItem.state == .on && !controller.claudeToggleItem.isEnabled && controller.codexToggleItem.isEnabled,
             "The primary provider cannot be unticked")

controller.toggleCodex()
let codexCalls = source.count
controller.refreshNow()
controller.refreshTimer?.fire()
settle()
settleClaude()
precondition(source.count == codexCalls && controller.tokenReportTask == nil,
             "Disabled Codex must not fetch usage or scan tokens")
precondition(controller.headerItem.isHidden && controller.primaryUsageItem.isHidden && controller.accountsItem.isHidden,
             "Disabled Codex must hide its usage and account controls")
precondition(!controller.claudeSectionItem.isHidden && controller.sectionSeparator.isHidden,
             "Claude-only mode must keep its section without a dangling separator")
controller.refreshTimer?.fireDate = Date().addingTimeInterval(60)
controller.refreshNow()
settleClaude()
precondition(controller.refreshTimer!.fireDate.timeIntervalSinceNow > 290,
             "A Claude-only manual refresh must restart the five-minute wait")
let reopened = AppController(accountStore: controller.accountStore, defaults: UserDefaults(suiteName: suiteName)!)
precondition(reopened.primaryProvider == .claude && !reopened.codexEnabled && reopened.claudeEnabled,
             "Provider preferences must survive reopening")

controller.selectPrimary(controller.codexPrimaryItem)
settle()
precondition(source.count == codexCalls + 1 && !controller.primaryUsageItem.isHidden && controller.menu.items.first === controller.headerItem,
             "Making Codex primary must enable it, fetch immediately and move it first")
precondition(controller.claudeEnabled, "The previous primary keeps its own tick")
controller.toggleClaude()
let claudeCalls = controller.claudeUsageSource.calls
controller.refreshNow()
settle()
controller.refreshClaudeUsage()
controller.refreshClaudeAccountUsage(force: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
precondition(controller.claudeUsageSource.calls == claudeCalls && controller.claudeSectionItem.isHidden && controller.claudeFiveHourItem.isHidden,
             "Unticked Claude must stop requests and hide its section")
controller.claudeUsageSource.failure = false
controller.toggleClaude()
settleClaude()
precondition(controller.claudeUsageSource.calls == claudeCalls + 1 && !controller.claudeSectionItem.isHidden,
             "Re-enabling Claude must immediately fetch and restore Claude")

let idleDeadline = Date().addingTimeInterval(2)
while controller.tokenReportTask != nil && Date() < idleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
controller.selectPrimary(controller.claudePrimaryItem) // Codex returns to its unticked state
let paused = PausedTokenSource()
let cancelledCache = root.appendingPathComponent("cancelled-tokens.json")
controller.tokenUsageSource = paused
controller.tokenReportStore = TokenUsageReportCacheStore(cacheURL: cancelledCache)
controller.tokenReport = nil
controller.toggleCodex() // Ticking Codex starts a token scan
let scanDeadline = Date().addingTimeInterval(2)
while !paused.didStart && Date() < scanDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(paused.didStart, "Token scan did not start")
controller.toggleCodex()
paused.resume.signal()
let finishDeadline = Date().addingTimeInterval(2)
while controller.tokenReportTask != nil && Date() < finishDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(controller.tokenReportTask == nil && controller.tokenReport == nil && !FileManager.default.fileExists(atPath: cancelledCache.path),
             "Disabling during a token scan must discard its result and report-cache write")

controller.selectPrimary(controller.codexPrimaryItem)
settle()
controller.claudeUsageSource.delay = .milliseconds(100)
let beforeCancellation = controller.claudeUsageSource.calls
controller.refreshClaudeAccountUsage(force: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
controller.toggleClaude()
controller.toggleClaude()
settleClaude()
precondition(controller.claudeUsageSource.calls == beforeCancellation + 2 && controller.claudeUsageError == nil,
             "Disabling and immediately re-enabling Claude must discard cancellation errors and fetch again")
print("Refresh cadence checks passed.")
SWIFT

sources=()
while IFS= read -r file; do
  case "${file:t}" in
    main.swift|AppController.swift|AccountProfiles.swift|ClaudeCodeUsageSource.swift|SelfTestRunner.swift) continue ;;
  esac
  sources+=("$file")
done < <(rg --files "$ROOT_DIR/Sources/CodexPeek" -g '*.swift')
swiftc -swift-version 6 "${sources[@]}" "$CHECK_DIR/AppController.swift" "$CHECK_DIR/AccountProfiles.swift" \
  "$CHECK_DIR/main.swift" -framework AppKit -framework ServiceManagement -o "$CHECK_DIR/check"
CLAUDE_CONFIG_DIR="$CHECK_DIR/claude" "$CHECK_DIR/check" "$CHECK_DIR"
