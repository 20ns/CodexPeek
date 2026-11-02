# Release Notes

## 1.0.11

- Redesign Usage History: translucent glass look that follows light and dark mode, Combined by default, stacked bars by service, full model names, month labels on long ranges, and no stuck loading states when one service has no data.
- Polish the menu: percentage-first rows, a translucent bar track, and a clearer pace tick.
- With Codex off, nothing Codex-related runs; its cached history still appears in Usage History.
- Much faster, leaner scans: logs stream instead of loading whole, dates parse with a reused formatter, and the session index is a compact binary plist kept in memory. A first Codex scan of compressed logs drops from about 7 minutes to under 40 seconds, and Claude's 5-minute scan from about 280 MB to about 130 MB.
- History content builds off the main thread, so switching views never stutters.

## 1.0.10

- Add a pace mark to weekly bars showing where an even burn would be before the reset.
- Put a refresh button at the top right of the menu whichever service leads it, and drop the separate Refresh Usage item.

## 1.0.9

- Choose a primary service (Codex or Claude Code) for the menu-bar icon and top of the menu, and tick or untick the other.
- Count Codex's compressed `.jsonl.zst` session logs in token history when the `zstd` CLI is installed.
- Fix Claude Sonnet 5.5 cache-read pricing, add Claude Haiku 5.5 with its 100K-prompt tier, add GPT-6.1 Terra, and correct Fast pricing for GPT-5.3 Codex, GPT-5.4 Nano and GPT-5.6 Cyber.
- Stop timer tolerance from skipping a Claude quota refresh, which could leave readings up to 10 minutes old.
- Prefer valid Claude Code credentials and report expired or under-scoped logins.

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
