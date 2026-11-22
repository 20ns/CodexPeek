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

// Replace only network IO; exercise the real Claude & Codex & Gemini controller callbacks offline.
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
controller.configureStatusItem()
controller.configurePopover()
precondition(controller.codexEnabled && controller.claudeEnabled && controller.agyEnabled, "All three providers must default to enabled")
precondition(!controller.showAccountEmail, "Account email must be hidden by default")
precondition(controller.statusItem.button?.toolTip == nil, "Status bar button must not set a sticky toolTip")

// Privacy check: a managed profile named with an email must not leak when showAccountEmail == false.
let managedEmailProfile = AccountProfile(id: "managed-1", name: "hidden@example.com", homePath: root.path, kind: .managed)
let signedInSnap = CodexAccountSnapshot(email: "hidden@example.com", authMode: .chatgpt, planType: .plus)
controller.activeProfile = managedEmailProfile
controller.accountState = AccountProfilesState(profiles: [profile, managedEmailProfile], activeProfileID: managedEmailProfile.id)
controller.accountSnapshotsByProfileID = [managedEmailProfile.id: signedInSnap]
let safeLabel = controller.privacySafeProfileLabel(for: managedEmailProfile, snapshot: signedInSnap)
precondition(!safeLabel.contains("hidden@example.com"), "Hidden profile label must not leak email")
let redactedDebug = controller.debugSummary()
precondition(!redactedDebug.contains("hidden@example.com"), "Debug summary must not leak managed profile email when hidden")
let hiddenChoices = controller.buildAccountChoices()
precondition(hiddenChoices.allSatisfy { !$0.title.contains("hidden@example.com") }, "Account choices must not leak email when hidden")

let source = CountingSource()
controller.activeProfile = profile
controller.accountState = AccountProfilesState(profiles: [profile], activeProfileID: profile.id)
controller.accountSnapshotsByProfileID = [:]
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
precondition(controller.statusItem.button?.toolTip == nil, "Render must never re-introduce a sticky status bar toolTip")

// Make the controller eligible, so its throttle cannot hide unwanted callbacks.
controller.lastRefreshStartAt = Date().addingTimeInterval(-301)
controller.popoverWillOpen()
controller.updatePopoverSize()
controller.closePopover()
precondition(controller.outsideClickMonitor == nil, "Closing popover must remove global outside-click monitor")
controller.openUsageHistory()
controller.usageHistoryWindowController?.close()
controller.installWakeObserver()
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
controller.installAuthFileWatcher(for: profile)
try Data("{\"changed\":true}".utf8).write(to: profile.authURL, options: .atomic)
RunLoop.main.run(until: Date().addingTimeInterval(1.1))
precondition(source.count == 1, "Popover, history, wake and auth writes must not pull usage")

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
let calls = controller.claudeUsageSource.calls
controller.popoverWillOpen()
precondition(controller.claudeUsageSource.calls == calls, "Opening the popover must not request account usage")
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
controller.popoverWillOpen()
precondition(failure != nil && controller.claudeUsageError == failure,
             "Opening the popover must preserve the account failure")
precondition(controller.claudeSnapshot?.isStale == true, "A failed reading must remain marked stale")

controller.selectPrimary(.claude)
precondition(controller.primaryProvider == .claude && controller.statusItem.button?.toolTip == nil,
             "Primary provider selection must work without sticky toolTip")

controller.toggleProvider(.codex)
let codexCalls = source.count
controller.refreshNow()
controller.refreshTimer?.fire()
settle()
settleClaude()
precondition(source.count == codexCalls && controller.tokenReportTask == nil,
             "Disabled Codex must not fetch usage or scan tokens")
controller.refreshTimer?.fireDate = Date().addingTimeInterval(60)
controller.refreshNow()
settleClaude()
precondition(controller.refreshTimer!.fireDate.timeIntervalSinceNow > 290,
             "A Claude-only manual refresh must restart the five-minute wait")

let reopened = AppController(accountStore: controller.accountStore, defaults: UserDefaults(suiteName: suiteName)!)
precondition(reopened.primaryProvider == .claude && !reopened.codexEnabled && reopened.claudeEnabled && reopened.agyEnabled,
             "Provider preferences must survive reopening")

controller.selectPrimary(.codex)
settle()
precondition(source.count == codexCalls + 1, "Making Codex primary must enable and fetch immediately")
precondition(controller.claudeEnabled, "The previous primary keeps its own tick")

controller.toggleProvider(.claude)
let claudeCalls = controller.claudeUsageSource.calls
controller.refreshNow()
settle()
controller.refreshClaudeUsage()
controller.refreshClaudeAccountUsage(force: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
precondition(controller.claudeUsageSource.calls == claudeCalls,
             "Unticked Claude must stop requests")
controller.claudeUsageSource.failure = false
controller.toggleProvider(.claude)
settleClaude()
precondition(controller.claudeUsageSource.calls == claudeCalls + 1,
             "Re-enabling Claude must immediately fetch and restore Claude")

let idleDeadline = Date().addingTimeInterval(2)
while controller.tokenReportTask != nil && Date() < idleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
controller.selectPrimary(.claude)
let paused = PausedTokenSource()
let cancelledCache = root.appendingPathComponent("cancelled-tokens.json")
controller.tokenUsageSource = paused
controller.tokenReportStore = TokenUsageReportCacheStore(cacheURL: cancelledCache)
controller.tokenReport = nil
controller.toggleProvider(.codex)
let scanDeadline = Date().addingTimeInterval(2)
while !paused.didStart && Date() < scanDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(paused.didStart, "Token scan did not start")
controller.toggleProvider(.codex)
paused.resume.signal()
let finishDeadline = Date().addingTimeInterval(2)
while controller.tokenReportTask != nil && Date() < finishDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(controller.tokenReportTask == nil && controller.tokenReport == nil && !FileManager.default.fileExists(atPath: cancelledCache.path),
             "Disabling during a token scan must discard its result and report-cache write")

// Verify Antigravity local token scan cancellation on disable
let pausedAgy = PausedTokenSource()
let cancelledAgyCache = root.appendingPathComponent("cancelled-agy.json")
controller.agyTokenSource = pausedAgy
controller.agyTokenStore = TokenUsageReportCacheStore(cacheURL: cancelledAgyCache)
controller.agyTokenReport = nil
controller.toggleProvider(.antigravity) // disable
controller.toggleProvider(.antigravity) // enable -> starts scan
let agyScanDeadline = Date().addingTimeInterval(2)
while !pausedAgy.didStart && Date() < agyScanDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(pausedAgy.didStart, "Antigravity token scan did not start")
controller.toggleProvider(.antigravity) // disable mid-scan
pausedAgy.resume.signal()
let agyFinishDeadline = Date().addingTimeInterval(2)
while controller.agyTokenTask != nil && Date() < agyFinishDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
precondition(controller.agyTokenTask == nil && controller.agyTokenReport == nil && !FileManager.default.fileExists(atPath: cancelledAgyCache.path),
             "Disabling Antigravity during a scan must discard its result and cache write")

controller.selectPrimary(.codex)
settle()
controller.claudeUsageSource.delay = .milliseconds(100)
let beforeCancellation = controller.claudeUsageSource.calls
controller.refreshClaudeAccountUsage(force: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
controller.toggleProvider(.claude)
controller.toggleProvider(.claude)
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
CLAUDE_CONFIG_DIR="$CHECK_DIR/claude" AGY_CONFIG_DIR="$CHECK_DIR/agy" AGY_BRAIN_ROOTS="$CHECK_DIR/agy-brain" "$CHECK_DIR/check" "$CHECK_DIR"
