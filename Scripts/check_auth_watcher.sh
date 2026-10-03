#!/bin/zsh
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
cat > "$CHECK_DIR/main.swift" <<'SWIFT'
import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let auth = root.appendingPathComponent("auth.json")
let notifications = DispatchSemaphore(value: 0)
let watcher = AuthFileWatcher()
try Data("first".utf8).write(to: auth)
watcher.start(watching: auth) { notifications.signal() }
defer { watcher.stop() }

func check(_ expected: Bool, _ message: String) {
    RunLoop.main.run(until: Date().addingTimeInterval(1.1))
    precondition((notifications.wait(timeout: .now()) == .success) == expected, message)
    precondition(notifications.wait(timeout: .now()) == .timedOut, "Duplicate notification")
}

try Data("usage".utf8).write(to: root.appendingPathComponent("usage.json"), options: .atomic)
check(false, "Unrelated writes must not refresh")
try Data("first".utf8).write(to: auth, options: .atomic)
check(false, "Identical auth must not refresh")
try Data("second".utf8).write(to: auth, options: .atomic)
check(true, "Atomic auth replacement must refresh")
try FileManager.default.removeItem(at: auth)
check(true, "Logout must refresh")
try Data("third".utf8).write(to: auth, options: .atomic)
check(true, "Login must refresh")
print("Auth watcher checks passed.")
SWIFT
swiftc "$ROOT_DIR/Sources/CodexPeek/AuthFileWatcher.swift" "$CHECK_DIR/main.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
