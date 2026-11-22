<p align="center">
  <img src="AppResources/AppLogo.svg" alt="CodexPeek icon" width="88">
</p>

<h1 align="center">CodexPeek</h1>

<p align="center">Codex, Claude Code and Antigravity usage in your macOS menu bar.</p>

<p align="center">
  macOS 14+ · Swift 6<br>
  <a href="#install">Install</a> ·
  <a href="Docs/USAGE.md">Data and estimates</a> ·
  <a href="https://github.com/20ns/CodexPeek/issues">Report a bug</a>
</p>

<p align="center">
  <a href="https://github.com/20ns/CodexPeek/actions/workflows/ci.yml"><img src="https://github.com/20ns/CodexPeek/actions/workflows/ci.yml/badge.svg" alt="Build and self-tests"></a>
</p>

CodexPeek shows your 5-hour and weekly limits, how much you've used, and when they reset. Open Usage History for token counts and API-equivalent cost estimates by model.

The menu is SwiftUI in a native menu-bar popover. The history window uses Swift Charts. There are no package dependencies, and the Codex helper runs only when the app needs it.

<p align="center">
  <img src="Docs/Images/main.png" alt="CodexPeek All view showing 5-hour and weekly usage for Codex, Claude Code and Antigravity, with plan badges and API-equivalent cost estimates" width="346">
  <img src="Docs/Images/codex.png" alt="CodexPeek Codex tab showing the account, 5-hour and weekly windows with reset times and pace, and 7-day, 30-day and all-time estimates" width="346">
</p>

## What you can see

- Codex 5-hour and weekly usage, reset countdowns, and Spark limits when available.
- Claude Code 5-hour and weekly usage, your plan, and per-model weekly limits such as Fable's.
- Antigravity 5-hour and weekly quota for Gemini and Claude / GPT models, the separate Gemini Argon limit, and your Google AI plan.
- Weekly usage for each service in the tabs at the top, and an All view with every service together.
- A primary service of your choice in the menu-bar icon, with the others optional.
- A pace mark on weekly bars: usage short of the mark means you can burn faster before the reset.
- Daily and hourly token history by model, including retained archived Codex sessions and Claude subagent logs.
- Codex, Claude Code, Antigravity, or combined history, with API-equivalent estimates for the last 7 days, 30 days, and all retained logs.
- The active Codex account and plan, with account switching from the menu.

Usage refreshes every five minutes. Use the refresh button at the top right of the menu to pull everything immediately. Launch at Login is available in the app menu.

Dollar amounts estimate what the recorded tokens would cost at API rates. They are not your subscription bill. Missing logs and unknown model prices can leave gaps.

## Install

Build from source for now. There are no published downloads on the [releases page](https://github.com/20ns/CodexPeek/releases) yet.

You'll need macOS 14 or later and a Swift 6 toolchain. Each service needs its own sign-in: the Codex CLI for Codex, a Claude Code account for Claude, and the Antigravity CLI (`agy`) for Antigravity quota.

```sh
git clone https://github.com/20ns/CodexPeek.git
cd CodexPeek
./Scripts/build_app.sh
open .build/CodexPeek.app
```

To use Launch at Login, move `CodexPeek.app` from `.build` into `/Applications` and open it there.

The app finds `codex` on `PATH` and in common Homebrew and user install directories. For another location, set `CODEX_CLI_PATH` when launching it:

```sh
CODEX_CLI_PATH=/path/to/codex .build/CodexPeek.app/Contents/MacOS/CodexPeek
```

The build scripts produce an unsigned app. If macOS blocks it, allow it in System Settings > Privacy & Security, then open it again. Signed and notarized releases are still planned.

## Where the data comes from

Codex limits come from the local `codex app-server` protocol. The app starts a process for each refresh and stops it afterward. If that fails, it uses local session data or a saved snapshot and marks the result as an estimate.

Claude limits come from Anthropic's usage endpoint using your existing Claude Code credentials. An optional status-line bridge can update readings between refreshes. The endpoint is not a documented public API, so changes to it may require an app update.

Antigravity limits come from the `agy` CLI's local `/usage` command, which uses no tokens. CodexPeek runs it only after local Antigravity activity, a quota reset, or an hour has passed, so it stays current when you use Antigravity through the app or ACP.

Token history and cost estimates come from local session logs, including Antigravity app, CLI and ACP transcripts. CodexPeek parses them on your Mac and caches unchanged files between scans.

See [data and estimates](Docs/USAGE.md) for account behavior, credential handling, refresh timing, pricing caveats, and the Claude status-line setup.

## Development

Run the app without packaging it:

```sh
swift run CodexPeek
```

Run the built-in checks:

```sh
swift run CodexPeek --self-test
./Scripts/check_auth_watcher.sh
./Scripts/check_refresh_cadence.sh
```

Builds go to `.build/CodexPeek.app`. To package a ZIP or DMG:

```sh
./Scripts/build_release.sh
./Scripts/build_dmg.sh
```

These write `dist/CodexPeek.zip` and `dist/CodexPeek.dmg`. Both scripts run the self-tests before packaging. See the [release checklist](Docs/RELEASE.md) for publishing steps.

| Path | Contents |
| --- | --- |
| [Sources/CodexPeek](Sources/CodexPeek) | App, usage readers, history, and self-tests |
| [AppResources](AppResources) | App metadata and icon |
| [Scripts](Scripts) | Builds and regression checks |

## Contributing

Bug reports and pull requests are welcome. Include your macOS version, how you installed CodexPeek, and the steps that reproduce the problem. Remove account details and tokens from anything you share.

Keep changes small. Reuse the native controls and existing helpers, avoid new dependencies where possible, and run the checks above before opening a PR.
