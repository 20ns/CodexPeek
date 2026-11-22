# Agent notes

CodexPeek is a SwiftPM macOS menu-bar app (macOS 14+). Sources are in `Sources/CodexPeek`, and the tests are the built-in self-test.

## Install every change on this Mac

After any bug fix or new feature, install the new build into `/Applications` and relaunch it, so the app on this Mac always runs the latest code. Don't wait to be asked. Install only after the self-test passes.

```bash
swift run CodexPeek --self-test
./Scripts/build_app.sh
osascript -e 'quit app "CodexPeek"' 2>/dev/null || pkill -x CodexPeek || true
while pgrep -x CodexPeek >/dev/null; do sleep 0.2; done
rm -rf /Applications/CodexPeek.app && ditto .build/CodexPeek.app /Applications/CodexPeek.app
open /Applications/CodexPeek.app
```

## Shipping

- Bump `CFBundleShortVersionString` and `CFBundleVersion` in `AppResources/Info.plist`, and add a short entry to `Docs/RELEASE.md`.
- Commit messages follow the existing style, e.g. "Fix X, add Y, ship 1.0.15".
