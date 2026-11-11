# Diary: AIUsage menu bar app

A native macOS menu bar app that shows current AI subscription usage percentages: Claude (weekly overall and the separate Fable weekly limit, plus any other limits the API returns) and OpenAI Codex. It generalizes the Go CLI at github.com/maragubot/claudeusage to more than one provider.

## Step 1: Requirements and data-source research

**Author:** main

### Prompt Context

**Verbatim prompt:** Build me a small Mac app that lives in my status bar that shows me current Claude/Fable usage percentage. I already have a CLI that does it at github.com/maragubot/claudeusage, but make this more general for other kinds of AI, so it also works with Codex from OpenAI. Just an icon, clicking it to view usage is fine. You're running on my Macbook Pro, so I can see things on the screen if you need it.
**Interpretation:** A menu bar utility with an icon only and a click-to-open panel listing usage per provider, with a provider abstraction so more AI services can be added.
**Inferred intent:** Glanceable usage without running a CLI, for both Claude and Codex subscriptions.

### What I did
Delegated research on both data sources. Asked Markus about stack, menu bar display, Claude data fetching, delivery and the Codex approach. Decisions:

- Swift + SwiftUI `MenuBarExtra`, icon only, no Dock icon. SwiftPM package plus a build script that assembles, signs and installs the `.app`. Xcode is installed, but `xcode-select` pointed at the Command Line Tools at the time.
- Claude: native call to `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`. The token comes from the login Keychain item `Claude Code-credentials` (JSON `claudeAiOauth.accessToken`, `expiresAt` in Unix ms). The app never refreshes it; it re-reads the Keychain on each poll.
- Codex: direct HTTP to `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <tokens.access_token>` and `ChatGPT-Account-Id: <tokens.account_id>` from `~/.codex/auth.json`. When the token is expired, the app offers a user-triggered action that lets Codex itself refresh or re-authenticate. Markus chose this over `codex app-server`.
- Public repo `maragudk/aiusage` (Markus creates it), MIT licence. Commits use the repo-local maragubot identity.

### Why
The app reads credentials owned by other tools. Refresh tokens are single-use for Codex and rotate for Claude, so the app refreshing on its own could log the owning tool out.

### What worked
A live GET to the Claude endpoint returned 200. `limits[]` carried `weekly_all` (85%) and `weekly_scoped` with `scope.model.display_name == "Fable"` (73%), plus `resets_at` and `severity`. `five_hour` was null.

### What didn't work
The Codex endpoint returned `401 {"error":{"code":"token_expired",...}}` because Codex had not run since 2026-10-29. This confirmed the URL and auth scheme, but no 200 body was seen; the shape comes from the openai/codex source.

### What I learned
`wham/usage` returns `rate_limit.primary_window` and `rate_limit.secondary_window`, each with `used_percent`, `limit_window_seconds`, `reset_after_seconds` and `reset_at` (Unix seconds), plus `additional_rate_limits[]`. This account currently has only a weekly primary window. Codex refreshes via `POST https://auth.openai.com/oauth/token`, and the refresh token is single-use.

### What was tricky
Both credentials belong to other apps, so the safe design is read-only access to them.

### What warrants review
Check that the app never writes the Keychain item or `auth.json`, and never logs tokens.

### Future work
None yet.

## Step 2: Build the app, providers, install script and docs

**Author:** builder

### Prompt Context

**Verbatim prompt:** You are building AIUsage, a native macOS menu bar app that shows AI subscription usage percentages for Claude (including the separate Fable weekly limit) and OpenAI Codex. [...] (full brief from the lead: SwiftUI `MenuBarExtra` with `.window` style, icon only, no Dock icon; a small `UsageProvider` protocol with Claude and Codex implementations that show every limit the API returns; poll every 5 minutes, refresh on panel open when older than 60 s, back off on 429/5xx; read-only credentials with a user-triggered Codex login repair; `os.Logger` outcome logging; SwiftPM library + executable + tests; `script/install` that builds, signs and installs `AIUsage.app`; README and MIT licence.)
**Interpretation:** Build the whole app end to end in this worktree, verify it live on Markus's Mac, and commit it in logical commits without pushing.
**Inferred intent:** A glanceable, boring, dependency-free utility that can never break the login of the tools whose credentials it borrows.

### What I did
Laid out a Swift package (`/Package.swift`, tools 6.2, macOS 15) with three targets. `AIUsageKit` holds the model (`UsageLimit`, `Severity`, `UsageError`, `Backoff`, `UsageFormat`), the `UsageProvider` protocol plus `LoginRepair`, an `HTTPClient` protocol with a `URLSessionHTTPClient` that refuses redirects, lenient ISO 8601 parsing, and the two providers. `AIUsage` is the app: `AppDelegate` owns a `@MainActor @Observable UsageStore` so polling starts at launch, and the views live in `/Sources/AIUsage/Views`. `AIUsageKitTests` has 54 Swift Testing tests over fixtures in `/Tests/AIUsageKitTests/Fixtures`, with no real identifiers in them.

I worked red/green: wrote the severity, formatting, backoff, ISO 8601 and parser tests first, then the code; then the provider tests (with `FakeHTTPClient` and temp `auth.json` files) and a fake `codex` shell script that speaks the app-server protocol, then the providers.

For the Codex expired-token button I read the codex CLI source (sparse clone, I added `codex-rs/cli` to it). `codex login status` only loads auth (`run_login_status` in `cli/src/login.rs`) and `codex doctor` doesn't refresh either. The app server's `account/read` takes `refreshToken: true`, which calls `AuthManager::refresh_token()` (`app-server/src/request_processors/account_processor.rs`, `refresh_token_if_requested`). So `CodexLoginRepair` starts `codex app-server` (stdio, newline-delimited JSON, no `jsonrpc` field), sends `initialize`, `initialized`, then `account/read {"refreshToken":true}`, closes stdin, and re-reads `auth.json`. If the JWT is still expired, it runs `codex login` (the browser flow; plain `codex login` maps to `run_login_with_browser`) and waits up to 10 minutes. The store re-polls afterwards. Process output goes to `/dev/null`.

I checked the handshake against the real binary with an empty scratch `CODEX_HOME`, so there was nothing to refresh: `initialize` → result, a `remoteControl/status/changed` notification, `account/read` → result with keys `account, requiresOpenaiAuth, workspaceRouting`, exit 0 on stdin close.

`/script/install` runs `swift build -c release`, assembles `.build/AIUsage.app` with an Info.plist (`LSUIElement`, `dk.maragu.aiusage`, `VERSION` default 0.1.0, build number from `git rev-list --count HEAD`), signs with the first "Apple Development" identity by SHA-1 (hardened runtime) or ad hoc, verifies, `pkill`s the running copy, `ditto`s it to `/Applications` and `open`s it. `--build` stops after signing.

Wrote `/README.md` and `/LICENSE` myself: the writer sub-agent couldn't be spawned ("In-process teammates cannot spawn background agents").

### Why
Each provider is one type behind `UsageProvider`, so a third provider is one new file plus one line in `/Sources/AIUsage/AIUsageApp.swift`. Typed throws (`throws(UsageError)`) keep every failure in one enum, which drives the panel message, the log category, whether to back off and whether to keep stale data. Read-only credentials and a click-only repair follow from Step 1: both tokens belong to other tools.

### What worked
- Live: the first install logged `fetch provider=claude status=200` and `fetch ok provider=claude limits=2`, about 10 s after launch, which is consistent with Markus answering the Keychain prompt. Later installs fetched in under 0.3 s with no prompt.
- Codex first showed `fetch failed provider=codex category=loginExpired` without a network call (local JWT `exp` check). After its token became valid (see below) the app logged `fetch provider=codex status=200` and `fetch ok provider=codex limits=1`: a real 200 body parsed into a single weekly window, as Step 1 predicted.
- `lsappinfo info -only ApplicationType AIUsage` reports `type="UIElement"`; `codesign --verify --strict` passes; the signature's authority is the Apple Development certificate.
- Offscreen rendering: since I have no screen-recording or accessibility permission, I compiled the section, row and footer views with sample data into a scratch binary that renders an `NSHostingView` to PNG in `.aqua` and `.darkAqua`. Both modes look native.
- Markus confirmed via the lead that he granted the Keychain prompt and clicked "Refresh Codex login", and that it worked. So the button's app-server path (or its `codex login` fallback) succeeded live. I can't tell which path ran, because those log lines were at `info` level and are gone.
- Live Codex shape check: `/private/tmp/.../scratchpad/probe/codex_shape.py` (outside the repo) calls `wham/usage` once and prints only keys and value types (plus `limit_window_seconds`), never values. Status 200. `rate_limit.primary_window` has `used_percent`, `limit_window_seconds: 604800`, `reset_after_seconds` and `reset_at`, all ints. `secondary_window` and `additional_rate_limits` are null. Top-level keys the openai/codex model doesn't list are `user_id`, `account_id`, `email`, `code_review_rate_limit` (null here), `model_usage`, `credits` (an object), `spend_control`, `promo` and `rate_limit_reset_credits`. I added `code_review_rate_limit` to the parser as another rate-limit block named "Code review · <window>", and changed `/Tests/AIUsageKitTests/Fixtures/codex-usage.json` to have the same top-level keys as the live response, with fake values.

### What didn't work
- `swift test` first failed with `UsageFormatTests.swift:9:5: error: the compiler is unable to type-check this expression in reasonable time` on a `@Test(arguments:)` tuple literal; annotating `as [(TimeInterval, String)]` fixed it.
- `setLocalizedDateFormatFromTemplate("EEEdMMMjmm")` with `en_GB` gave `Wed 19 Nov at 12:00`. I now format the day and the time separately and join them.
- `String(parts[1]).replacing(...)`: `Data(base64Encoded:)` gave `no exact matches in call to initializer` with a `Substring`.
- In a task group closure, `do { try await provider.fetchLimits() } catch { .failure(error) }` gave `cannot convert value of type 'any Error' to expected argument type 'UsageError'`; it needs `do throws(UsageError)`.
- The linear `ProgressView` ignored `.tint` in the render (all bars grey). Replaced it with `UsageBar`, a capsule drawn by a tiny `Layout`, so colour no longer depends on window state.
- `info`-level logs vanish from `log show` after a few minutes (they aren't persisted), so `fetch ok` lines from the first launch were gone when I looked again. Outcomes now log at `notice`.
- `osascript ... click menu bar item 1 of menu bar 2` gave `osascript is not allowed assistive access. (-1719)` and `screencapture` gave `could not create image from display`, so I couldn't open or capture the real panel.
- A compound shell command containing `git init` was refused by the worktree guard. It was a mistake anyway, since the worktree already is a repo.

### What I learned
- The Codex app server is a clean, non-interactive way to make Codex refresh its own token: `account/read` with `refreshToken: true`. It also exits when stdin closes.
- `AuthManager::auth()` refreshes proactively when `last_refresh` is more than 8 days old (`TOKEN_REFRESH_INTERVAL`), so almost any Codex command that touches auth may rotate the token. That's why I didn't run any codex command against the real `~/.codex` during verification.
- The new SwiftPM build system puts products in `.build/out/Products/<Config>`, and `swift build --show-bin-path` reports that path.

### What was tricky
- At 12:10:16 local, `~/.codex/auth.json` was refreshed (`last_refresh` 2026-11-11T11:10:16Z). My handshake probe ran at 12:06 against the scratch `CODEX_HOME` and had exited, and the tests only run fake scripts. Markus later confirmed that he clicked the button in the 12:09 build. As a result, I saw the expired-login state live only at first launch (`category=loginExpired`); tests cover it beyond that.
- `isRefreshing` guards overlapping refreshes. A manual refresh that arrives during a poll (for example, the re-poll after a repair) sets `needsManualRefresh` and runs right after, so it isn't lost.

### What warrants review
- `/Sources/AIUsageKit/Codex/CodexLoginRepair.swift`: process lifetime, the watchdog tasks, and that nothing reads or logs process output beyond the JSON-RPC `id`.
- `/Sources/AIUsageKit/HTTP/HTTPClient.swift`: no redirects, no cookies or cache, and logs contain only provider, status and category.
- That nothing writes the Keychain or `auth.json`: `grep -rn 'SecItemAdd\|SecItemUpdate\|write(to' Sources` should show no credential writes.
- Live check: `log show --predicate 'subsystem == "dk.maragu.aiusage"' --last 10m` after `script/install`.

### Future work
- The Keychain "Always Allow" may be lost if Claude Code ever deletes and re-creates its Keychain item rather than updating it. If prompts keep coming back, this is the first thing to check.
- `is_active` on Claude limits is parsed by the API but not shown. It might mark the binding limit.
