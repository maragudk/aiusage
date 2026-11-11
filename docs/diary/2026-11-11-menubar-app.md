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
- Public repo `markuswustenberg/aiusage`, MIT licence.

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
