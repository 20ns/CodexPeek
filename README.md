# CodexPeek

![CodexPeek Logo](./AppResources/AppLogo.svg)

The lightest Codex usage menu bar app for macOS.

CodexPeek is a native `AppKit` menu bar utility that shows your Codex 5-hour and weekly usage without a browser shell, Electron runtime, or persistent background helper. It is built to stay out of the way: fast to launch, low on heat, and glanceable from the menu bar.

![CodexPeek Screenshot](./Docs/Images/main.png)

CodexPeek exists because a lot of utility apps in this space take the heavier route:
- web runtimes
- embedded browser views
- always-running helper processes
- more UI framework overhead than the job actually needs

Those choices can be reasonable for feature-heavy apps, but they usually cost more RAM, more wakeups, and more background activity. CodexPeek is intentionally optimized for the opposite tradeoff: do less, stay native, and keep the footprint small.

## Performance

On my Mac, CodexPeek is materially lighter than CodexBar for the narrow job of showing Codex usage in the menu bar:

- Idle memory in `top`: about `21 MB` for CodexPeek vs about `56 MB` for CodexBar
- Rough cold launch to process start: about `47.6 ms` for CodexPeek vs about `113.4 ms` for CodexBar
- App size on disk: about `3 MB` for CodexPeek vs `68 MB` for CodexBar

CodexBar supports a broader feature set, so this is not a blanket "better app" claim. It is a focused overhead comparison for this specific use case: lightweight Codex usage visibility on macOS.

## Why CodexPeek

- Native macOS app, built with `Swift + AppKit` and a Swift Charts history view
- No Electron, no webview, no Tauri
- No always-on Codex helper process
- Reads live usage from the official local `codex app-server` protocol
- Charts daily and hourly token history by model, entirely on-device
- Tracks active and archived Codex sessions, including GPT-6.1 Sol, GPT-6 Sol, GPT-6 Luna, and Astra
- Shows Claude Code's 5-hour and weekly limits plus 7-day, 30-day and all-time API-equivalent estimates in a separate orange section
- Backfills retained Claude Code logs, including subagents, with separate prices for cache reads, 5-minute writes and 1-hour writes
- Usage History can show Codex, Claude Code or their combined API value; Max includes all retained history
- Compares today, recent weeks, cache reuse, and API-equivalent value
- Falls back gracefully to local Codex session data and cache
- Auto-detects the signed-in Codex account
- Supports launch at login

Measured locally on Apple silicon during development:
- Idle CPU: effectively `0%`
- Idle memory: about `33 MB` in the latest short `top` sample
- Codex limits and token estimates refresh every five minutes in the background. Refresh Usage pulls immediately and restarts the five-minute wait. Startup and explicit account switches also load usage. Opening menus or history, waking the Mac and auth-file writes do not pull usage.
- Claude limits refresh every five minutes from the signed-in Claude Code account, with local status-line events updating them between refreshes
- Token estimates refresh every five minutes off the main thread, reusing cached records for unchanged session files

## macOS Only

CodexPeek currently targets `macOS 14+`.

## Install

### Download a release

Once releases are published, download either:
- `CodexPeek.dmg`
- `CodexPeek.zip`

Move `CodexPeek.app` into `/Applications`, open it once, then enable `Launch at Login` from the menu if you want it to start automatically.

### Unsigned app warning

CodexPeek is currently distributed as an unsigned macOS app.

That means macOS may show a warning the first time you open it, because the app is not yet signed and notarized with an Apple Developer account. The app still runs fine, but first launch may require one extra step.

If macOS blocks the app:

1. Move `CodexPeek.app` into `/Applications`
2. Right-click the app and choose `Open`
3. Click `Open` in the confirmation dialog

If macOS still blocks it, go to `System Settings > Privacy & Security` and allow the app there, then launch it again.

### Build locally

Requirements:
- macOS 14+
- Swift 6 toolchain
- Codex CLI installed and available via `PATH`, `CODEX_CLI_PATH`, `/opt/homebrew/bin/codex`, or `/usr/local/bin/codex`

Run directly:

```bash
swift run CodexPeek
```

Build the `.app`:

```bash
./Scripts/build_app.sh
```

Build a distributable `.zip`:

```bash
./Scripts/build_release.sh
```

Build a `.dmg`:

```bash
./Scripts/build_dmg.sh
```

## How It Works

CodexPeek refreshes usage by spawning:

```bash
codex app-server --listen stdio://
```

It then reads:
- account identity
- plan type
- 5-hour usage window
- weekly usage window

If live refresh fails, it falls back in this order:
1. latest local Codex session log usage event
2. last saved snapshot cache

Token history refreshes every five minutes and on manual refresh. Cost estimates use the [OpenAI API pricing table](https://developers.openai.com/api/docs/pricing), including Fast and long-context rates. These are API-equivalent estimates, not subscription charges. Models without a known rate remain unpriced.

Claude quota bars read the signed-in Claude Code account's usage endpoint on startup, every five minutes and when you choose Refresh Usage. This also works with Claude Code app and SDK sessions that do not render a terminal status line. Credentials are read from `CLAUDE_CODE_OAUTH_TOKEN`, the configured `.credentials.json` or the macOS `Claude Code-credentials` Keychain entry. Tokens stay in memory and are sent only to Anthropic. The app does not refresh tokens or change Claude's login. If authentication expires, sign in again through Claude Code.

The optional [Claude Code status-line bridge](https://code.claude.com/docs/en/statusline#rate-limit-usage) can update quota readings between account refreshes. Choose `Enable Claude local usage` to install it. The installer preserves an existing status-line command and other settings, and backs up settings before the first edit. Terminal readings require supported subscription data and a response in the session.

The app retains the last valid reading when a request fails, shows its age and reports the failure. It marks readings stale after five minutes and removes each window after its reset until another reading arrives. Missing data remains unavailable. Rate-limited requests wait at least five minutes and respect longer server retry delays. Token cost estimates use retained local logs independently.

To enable the optional bridge from a built app:

```sh
.build/CodexPeek.app/Contents/MacOS/CodexPeek --setup-claude-statusline
```

To fetch and verify account usage:

```sh
.build/CodexPeek.app/Contents/MacOS/CodexPeek --refresh-claude-usage
```

The helper and `codexpeek-usage.json` live in `~/.claude`, or `CLAUDE_CONFIG_DIR` when set. The usage file contains only percentages, reset times and the observation time. The account endpoint is also used by Claude Code but is not a documented public API, so changes to it may require an app update.

Account identity also falls back to local `~/.codex/auth.json` metadata so the signed-in label remains useful even when usage data is stale.

## Development

Run the built-in self-tests:

```bash
swift run CodexPeek --self-test
```

Project structure:
- [`Sources/CodexPeek`](./Sources/CodexPeek): native app source
- [`Scripts/build_app.sh`](./Scripts/build_app.sh): build a local `.app`
- [`Scripts/build_release.sh`](./Scripts/build_release.sh): build a release `.zip`
- [`Scripts/build_dmg.sh`](./Scripts/build_dmg.sh): build a release `.dmg`
- [`AppResources`](./AppResources): app metadata and icon assets

## Roadmap

- Signed and notarized public releases
- Better onboarding for first launch
- Release screenshots
- Optional update channel / auto-update strategy

## Why macOS warns on first launch

Unsigned apps trigger Gatekeeper warnings because Apple cannot verify the developer identity or notarization status. That warning is expected for the current public builds and does not mean CodexPeek is broken.

The long-term plan is to ship signed and notarized releases. Until then, GitHub releases will include unsigned `.zip` and `.dmg` artifacts with the install steps above.

## Contributing

Issues and PRs are welcome. Keep changes aligned with the project’s core goal:

`lowest-overhead Codex usage visibility on macOS`

### Claude token estimates

Claude estimates use [Anthropic API list prices](https://platform.claude.com/docs/en/about-claude/pricing), checked on 3 October 2026. They reflect API-equivalent value, not subscription charges. Cache read and cache creation tokens are separate from regular input; structured cache durations are not counted again in the aggregate. Legacy logs without cache duration use the 5-minute write rate. Models without a known price retain their token counts and are excluded from dollar estimates. When the older `stats-cache.json` ends before all detailed logs begin, its aggregate totals are added to all-time usage with a labeled approximation using standard rates and five-minute cache writes. They are excluded if the date ranges overlap or the aggregate period ends within the last 30 days. Daily charts use detailed logs only. Deleted logs and past quota percentages cannot be reconstructed.

To backfill the local Claude cache and compare the first and cached scan:

```sh
swift run -c release CodexPeek --backfill-claude
```

Run `Scripts/check_auth_watcher.sh` and `Scripts/check_refresh_cadence.sh` for watcher and refresh regression checks. Pricing and parser checks are included in `swift run CodexPeek --self-test`.
