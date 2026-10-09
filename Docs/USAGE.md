# Data and estimates

[Back to the README](../README.md)

Quota percentages and token estimates answer different questions. Quotas show how much of your subscription limit you've used. Token estimates put an API-equivalent dollar value on the usage recorded in local logs.

## Codex limits

For each refresh, CodexPeek starts:

```sh
codex app-server --listen stdio://
```

It reads the account identity, plan, and available rate-limit windows, then stops the process.

When live data is unavailable, it tries the latest local session reading, then the saved snapshot. A newer cached live reading takes precedence over an older session reading. Fallback readings appear as estimates. Local auth metadata can fill in missing account details.

### Accounts

The default account uses `~/.codex`. Managed accounts have separate Codex home directories under `~/Library/Application Support/CodexPeek`, which also holds app settings and caches. The app sets `CODEX_HOME` to the selected profile when it starts the CLI.

Selecting a managed account changes which profile CodexPeek reads. Choosing Open Codex also copies that profile's auth into the default Codex home and restarts the desktop app if needed. Selecting Default Account restores its saved auth. These actions can change the account used by other Codex clients on the Mac.

## Refresh timing

Codex limits and token estimates refresh every five minutes. Startup and explicit account switches also load usage. Manual refresh pulls immediately and restarts the five-minute wait.

Opening menus or history, waking the Mac, and auth-file writes do not trigger a Codex usage request. Token scans run off the main thread and reuse cached records for unchanged session files.

Claude account limits refresh on startup, every five minutes, and on manual refresh. The optional local bridge can supply newer readings between account requests.

## Claude Code limits

CodexPeek calls `https://api.anthropic.com/api/oauth/usage` with the signed-in Claude Code account's credentials. It checks these sources in order:

1. `CLAUDE_CODE_OAUTH_TOKEN`.
2. `.credentials.json` in the Claude config directory.
3. The macOS `Claude Code-credentials` Keychain entry.

Credentials stay in memory and go only to Anthropic. CodexPeek does not refresh tokens or change Claude's login. If authentication expires, sign in again through Claude Code.

Account requests work without a terminal status line, including Claude Code app and SDK sessions. The endpoint is not a documented public API. If Anthropic changes it, CodexPeek may need an update.

The app keeps the last valid reading when a request fails, shows its age, and reports the failure. Readings become stale after five minutes. Each expired window disappears until a new reading arrives. Missing data stays unavailable.

Rate-limited requests wait at least five minutes and respect longer server retry delays. Manual refresh does not bypass that cooldown.

### Optional status-line bridge

Choose Enable Claude local usage in the menu to install the bridge. It captures quota data supplied to [Claude Code's status line](https://code.claude.com/docs/en/statusline#rate-limit-usage) and saves it locally. The installer preserves an existing status-line command and other settings, and backs up settings before the first edit.

Terminal readings require supported subscription data and a response in the session. The bridge is optional because account requests already supply quota readings.

From a built app, you can also install it with:

```sh
.build/CodexPeek.app/Contents/MacOS/CodexPeek --setup-claude-statusline
```

Fetch account usage directly with:

```sh
.build/CodexPeek.app/Contents/MacOS/CodexPeek --refresh-claude-usage
```

The helper and `codexpeek-usage.json` live in `~/.claude`, or `CLAUDE_CONFIG_DIR` when set. The usage file contains percentages, reset times, and the observation time, without credentials.

## Token history and dollar estimates

History uses retained local logs. Codex scans include active and archived sessions. Claude scans include subagent logs. The Max chart range includes all retained detailed logs; deleted logs cannot be reconstructed.

Menu estimates use rolling 7-day and 30-day periods. Charts group usage by calendar day, so their totals can differ from the menu.

Dollar amounts use the model prices in the app. They estimate API-equivalent value, not subscription charges or actual invoices. Models without a known price keep their token counts but contribute no dollar estimate.

For the upstream rates, see [OpenAI API pricing](https://developers.openai.com/api/docs/pricing) and [Anthropic API pricing](https://platform.claude.com/docs/en/about-claude/pricing). CodexPeek's price catalog needs an app update when rates change.

Codex estimates account for cached input, Fast rates, and long-context rates where the app has a matching price.

Claude estimates separate regular input, output, cache reads, 5-minute cache writes, and 1-hour cache writes. Structured cache durations are not counted again in the aggregate. Older logs without a cache duration use the 5-minute write rate.

### Older Claude history

When `stats-cache.json` ends before the detailed logs begin, CodexPeek can add its aggregate totals to all-time usage. It labels these as approximations and uses standard rates with 5-minute cache writes.

The app excludes those totals if the date ranges overlap or the aggregate period ends within the last 30 days. Daily charts use detailed logs only. Past quota percentages cannot be reconstructed from token logs.

To backfill the local Claude token cache and compare the first scan with a cached scan:

```sh
swift run -c release CodexPeek --backfill-claude
```

Pricing and parser checks are part of `swift run CodexPeek --self-test`.
