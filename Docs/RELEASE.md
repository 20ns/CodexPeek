# Release Notes

## 1.0.7

- Refresh usage on one five-minute timer. Manual refresh pulls immediately and restarts the wait; opening menus or history, waking and auth-file writes do not pull usage.
- Filter directory events to actual auth-content changes and coalesce refresh requests that overlap an active fetch.
- Backfill cache-aware Claude Code API-equivalent estimates from retained local logs.
- Add Codex, Claude Code and combined history views with all retained history in Max.
- Replace Claude OAuth polling with documented local status-line quota readings, including stale and expired-window states.

## 1.0.6

- Add current Codex model prices, including GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, Cyber, and Daybreak.
- Correct GPT-5.6 Sol pricing and account for long-context and Astra Ultrafast rates.
- Keep archived chats in token history and rebuild older indexes from session logs.
- Refresh token history every five minutes and fix queued refreshes.
- Add a separate orange Claude Code section with independent refresh, connection, and stale-data states.
- Clamp unusually large usage percentages without integer overflow.

## Packaging

Build local release artifacts:

```bash
./Scripts/build_release.sh
./Scripts/build_dmg.sh
```

Outputs:
- `dist/CodexPeek.zip`
- `dist/CodexPeek.dmg`

## Unsigned Public Release

Current releases are unsigned and not notarized.

That means users may see the standard macOS "unidentified developer" warning on first launch. Public release notes and the README should tell users to:

1. Move `CodexPeek.app` into `/Applications`
2. Right-click `CodexPeek.app`
3. Choose `Open`
4. Confirm `Open`

If needed, they can also allow the app in `System Settings > Privacy & Security`.

## Public Release Checklist

- Run `swift run CodexPeek --self-test`
- Build `.zip` and `.dmg`
- Confirm the `/Applications` install launches correctly
- Verify launch-at-login from the installed copy
- Confirm the unsigned first-launch instructions in the README are accurate
- Update README screenshots if needed
- Tag and publish a GitHub release

## Signing / Notarization

This repo currently builds unsigned local artifacts. For a smoother public macOS install flow later, the next step is Apple code signing and notarization.
