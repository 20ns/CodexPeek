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
    func refresh(force: Bool = false) async throws -> ClaudeCodeUsageSnapshot? {
        calls += 1
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

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let profile = AccountProfile(id: "fixture", homePath: root.path, kind: .systemDefault)
try Data("{}".utf8).write(to: profile.authURL)
NSApplication.shared.setActivationPolicy(.prohibited)
let controller = AppController(accountStore: AccountProfileStore(
    stateURL: root.appendingPathComponent("accounts.json"), managedProfilesRootURL: root))
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
