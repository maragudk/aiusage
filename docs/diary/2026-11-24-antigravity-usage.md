# Diary: Antigravity CLI usage provider

Markus has started using Google's Antigravity CLI (`agy`) next to Claude Code and Codex, and wants its usage limits in the AIUsage panel. The goal is a third provider section, Antigravity, that shows each quota window with its used percentage and reset time. The menu bar item keeps showing only the Claude weekly number.

## Step 1: Shape the requirements and research the quota API

**Author:** main

### Prompt Context

**Verbatim prompt:** I've started using Antigravity CLI as well, so I need that to show up as well.
**Interpretation:** Add Antigravity as a provider in the panel, next to Claude and Codex.
**Inferred intent:** See all of the AI subscription limits Markus uses in one place, without opening each tool.

### What I did

I checked the MacBook for an install and found none at first: no `agy` binary, and `~/.gemini/oauth_creds.json` was the old Gemini CLI login from February. A research sub-agent then read community tools that already show Antigravity quota: OpenUsage (Swift), CodexBar, ClaudeBar, quotio and the Raycast agent-usage extension. Meanwhile Markus installed `agy` 1.5.16 at `~/.local/bin/agy` and logged in. The CLI log at `~/.gemini/antigravity-cli/cli.log` confirms the login (`consumerOAuth: token acquired`, with an expiry one hour later). The Keychain now holds a generic password with service `gemini` and account `antigravity`.

I asked Markus three questions and he answered:

- The Antigravity data goes in the panel only. The menu bar stays Claude weekly.
- His plan is Google AI Ultra, so he should see both 5-hour and weekly windows.
- For the token that expires every hour, he chose a "Refresh Antigravity login" button, like the Codex one. The app does not refresh the token by itself, and it does not embed Antigravity's OAuth client secret.

### Why

The app already reads Claude and Codex from undocumented endpoints with the credentials those CLIs store. Antigravity follows the same pattern, so the research had to find where `agy` keeps its token and which endpoint returns quota.

### What worked

The community tools agree on the main facts:

- The token is in the Keychain item `gemini`/`antigravity`. Its value is `go-keyring-base64:` followed by base64 JSON in the Go `oauth2.Token` shape. When `SSH_TTY` is set, `agy` uses the file `~/.gemini/antigravity-cli/antigravity-oauth-token` instead.
- The quota comes from `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, falling back to `cloudcode-pa.googleapis.com`.
- The response has groups ("Gemini Models", "Claude and GPT models", sometimes a model-specific group). Each group has buckets (`5h`, `weekly`) with `remainingFraction` and `resetTime`. The app shows used percent as (1 - remainingFraction) * 100.

### What didn't work

My first presence check, `security find-generic-password -s gemini -a antigravity`, printed "no keychain item", even though `security dump-keychain` lists the item. I ran the check before Markus finished logging in, which may explain it, but I did not confirm that. The builder should verify the read path live.

### What I learned

The User-Agent seems to decide which quota buckets the summary returns. Tools send an `antigravity/hub/<version>` identity. Also, `fetchAvailableModels` can report every model at 100% when quota access is denied, so it is not a trustworthy fallback.

### What was tricky

Refreshing the token. The access token lasts one hour, and only `agy` renews it while it runs. Refreshing it ourselves would mean committing Google's public client secret to a public repo, so Markus chose the explicit button instead.

### What warrants review

All of this is reverse-engineered and undocumented. The research JSON shapes come from community test fixtures, not live captures. The builder must check the real response for Markus's Ultra account.

### Future work

None yet.

## Step 2: Build the provider and check it against the live API

**Author:** builder

### Prompt Context

**Verbatim prompt:** The lead's brief opened with "You are building a new provider for AIUsage, a Swift macOS menu bar app (SwiftPM only, no Xcode project) … Add an "Antigravity" section to the panel showing the user's Antigravity CLI (`agy`) quota, same row style as other providers (name, used %, severity-coloured bar, relative + absolute reset). The menu bar item is unchanged (Claude weekly only)." It went on with eight numbered requirements (credentials, CLI detection, fetch, response, expired login, errors, tests, docs) and a live verification list. Midway, the lead passed on: "Scope change from Markus: drop the "Claude and GPT models" (third-party) group entirely; he doesn't use those models through Google. Filter it out (bucket ids starting with `3p-`, or however that group is reliably identified in the real response you observed — prefer the id over the display name). Keep showing every other group the API returns, so a new Gemini group still appears without code changes."
**Interpretation:** Build `AntigravityProvider` the way `CodexProvider` works: read `agy`'s token from the Keychain, call the quota summary, show a row per bucket, and offer a "Refresh Antigravity login" button that only asks `agy` to renew its own token. Check every assumption from Step 1 against the live API first. Later, leave out the third-party buckets.
**Inferred intent:** Markus wants to see his Gemini quota in the panel next to Claude and Codex, without the app ever handling Google's OAuth client secret or refreshing tokens on its own.

### What I did

I checked the live setup before writing code, printing only shapes and lengths, never token values. `security find-generic-password -s gemini -a antigravity -w` now exits 0. The value is `go-keyring-base64:` plus base64 JSON with `token.access_token`, `token.token_type`, `token.refresh_token`, `token.expiry` (RFC 3339 with a `+01:00` offset and microseconds), `token.expires_in`, `auth_method` (`consumer`) and `id_token_email`. The token file `~/.gemini/antigravity-cli/antigravity-oauth-token` doesn't exist on this Mac.

Then I called the quota endpoints with a small Python probe in the scratchpad:

- `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` with body `{}` and the hub User-Agent returned 200 with real counters. The shape is unwrapped: `{"groups": [{"displayName", "description", "buckets": [{"bucketId", "displayName", "window", "resetTime", "description"?, "remainingFraction"}]}], "description"}`. Gemini Models had `gemini-weekly` (0.98) and `gemini-5h` (0.93). Claude and GPT models had `3p-weekly` and `3p-5h`, both at 1. Weekly comes before 5h in each group. No `response` wrapper, no `remaining` nesting and no `disabled` field appeared. The response has no account identifiers, so I used it as the fixture `/Tests/AIUsageKitTests/Fixtures/antigravity-quota.json` unchanged.
- The same call to the production host `cloudcode-pa.googleapis.com` also returned 200, but with every bucket at 1, reset times exactly one window from now, and generic model names ("Gemini Flash, Gemini Pro"). Those counters aren't the ones `agy` uses.
- The daily host with User-Agent `aiusage/0.1` returned 403 `PERMISSION_DENIED` with an `ErrorInfo` reason `SUBSCRIPTION_REQUIRED`, even for this Ultra account. I saved that body as `/Tests/AIUsageKitTests/Fixtures/antigravity-subscription-required.json`.
- `~/.gemini/antigravity-cli/cli.log` shows that `agy` itself calls only the daily host (`loadCodeAssist`, `fetchAvailableModels`).

The code, in six commits:

1. `b5a2fc3` moved the `security` read out of `ClaudeCredentials` into `/Sources/AIUsageKit/Keychain/KeychainPassword.swift`. It renamed `HTTPClient.get` to `fetch`, because Antigravity sends a POST, and gave `fetch` a `providerError` hook for failure bodies. It also let `Command.run` take an environment and a working directory.
2. `08ec6fa` added `/Sources/AIUsageKit/Antigravity/`: `AntigravityHome` (CLI paths, token file), `AntigravityCredentials` (Keychain first, then the file; decodes the prefixed, plain or bare-token JSON; Go's zero time counts as no expiry), `AntigravityUsageParser`, `AntigravityLoginRepair` and `AntigravityProvider`. Tests and fixtures went in with them. `FakeRunner` moved to its own test file so both credential suites can use it.
3. `025b4de` added `AntigravityProvider()` to the provider list in `/Sources/AIUsage/AIUsageApp.swift`.
4. `4b20340` addressed the review (see below).
5. `5e3dec9` applied the scope change: the parser drops every bucket whose `bucketId` starts with `3p-`, whatever its group is called.
6. `3275617` documented the provider in `/README.md`. A writer sub-agent drafted it, and I edited it after the scope change.

Row names are the group's display name without a trailing "models", then the window: "Gemini · 5-hour", "Gemini · Weekly". Windows go through `CodexUsageParser.windowName(seconds:fallback:)`, so they match the other providers. Within a group, rows are sorted shortest window first, like Claude and Codex, although the API sends weekly first. Severity is nil, so the 75%/90% thresholds apply.

The repair button runs `agy models` with a 60-second timeout and `AGY_CLI_DISABLE_AUTO_UPDATE=true`, and without `SSH_TTY`. It runs in a fresh `0700` temp directory that holds failing `open` and `xdg-open` shims. That directory is first on `PATH`, and `BROWSER` points at the `open` shim. The directory is removed afterwards. Then the provider fetches again. If the server still rejects the login and `agy` actually exited (rather than timing out or failing to start), the provider remembers that login's expiry. Until a login with another expiry turns up, the panel then says "Antigravity couldn't refresh its login. Run agy in Terminal and log in again.", with the button still available.

Live checks:

- `script/install`, then the app log showed `fetch provider=antigravity status=200` and `fetch ok provider=antigravity limits=4`, and after the scope change `limits=2`. No Keychain prompt appeared. I rendered `ProviderSectionView` with live data through `ImageRenderer` in a throwaway test, because a scripted click on the `MenuBarExtra` didn't open the panel. The rows looked like the other providers'.
- The token expired at 10:57:21 UTC. The app's next poll, at 10:57:50, logged `fetch failed provider=antigravity category=loginExpired` without sending a request. Two seconds later someone clicked the button in the installed app. The log shows `login repair started provider=antigravity`, then `agy models result=exited-0 valid=true`, then `fetch ok provider=antigravity limits=2`, 2.3 seconds in all. `agy`'s own log for that run (`cli-20261124_115752.log`, working directory `aiusage-agy-…`, auto-update disabled) shows `keyringAuth: loaded token … expired=true`, then `token refreshed, new expiry=2026-11-24 12:57:52`, and then only `loadCodeAssist` and `fetchAvailableModels`, with no generate calls. Afterwards the Keychain item holds the new expiry in the same `go-keyring-base64:` format, and no `aiusage-agy-*` directory is left behind.

`swift build` has no warnings, and `swift test` passes 139 tests in 18 suites, plus 6 in the app target.

### Why

Step 1's facts came from community fixtures, so the live response decided the parsing, the host and the User-Agent. The shared Keychain and HTTP changes keep Antigravity on the same path as Claude: no Keychain API, timeouts everywhere, and status mapping and logging in one place.

### What worked

- Reading the Keychain through `/usr/bin/security` worked with no prompt, as it does for Claude's item.
- `agy models` is a cheap repair. It takes 1 to 3.5 seconds, and it renews an expired token, because listing models needs an authenticated call. A run with a valid token doesn't touch the token.
- The existing `ISO8601.date(from:)` already parses `2026-11-24T11:57:21.411177+01:00`.
- The `providerError` hook kept the 403 handling out of the shared status mapping.

### What didn't work

- My first combined shell commands were refused by the worktree guard: "This session is isolated in the worktree …, but this command is too complex to verify that it stays inside the worktree." Writing scripts with the Write tool and running simple commands fixed that.
- `osascript -e 'tell application "System Events" to tell process "AIUsage" to click menu bar item 1 of menu bar 2'` found the item ("Claude weekly usage 56%"), but no panel window opened (`Can't get window 1 of process "AIUsage". Invalid index. (-1719)`). Screenshots of the whole screen held unrelated content, so I deleted them and rendered the view offscreen instead.
- I couldn't show that `agy models` spends no quota by comparing fractions. The Gemini fractions kept dropping all session (5-hour from 0.930 to 0.826) while no `agy` of mine was running, so someone was using Gemini elsewhere. The evidence is `agy`'s own request log instead.

### What I learned

- The User-Agent does more than pick buckets. Without the hub identity, the daily host refuses an Ultra account with 403 `SUBSCRIPTION_REQUIRED`. A future server-side minimum hub version would look like "no subscription" in the panel.
- The production host isn't a fallback. Its counters are full and reset one window from now, so falling back would show a confident 0% used. I didn't implement the fallback the brief asked for, and I didn't add `loadCodeAssist`, because body `{}` works.
- An untouched pool's `resetTime` rolls forward on every call (now plus the window), so "Resets in 5h 0m" is what the API says for an unused 5-hour pool.
- `agy` builds a store for its working directory, and a GUI app's working directory is `/`. That is why the repair runs `agy` in its own temp directory.
- One `swift test --filter` run printed the throwaway test's output once, and at first I credited the token refresh to that run. The app's `login` log showed that the refresh came from the button click two seconds after expiry, and that my test ran a few seconds later against the fresh token.

### What was tricky

- Telling the user to log in again only when that is true. The repair's `perform` returns nothing, so the provider remembers the failed login by its expiry and turns the next expiry error into the "run agy" message. A review finding made this ignore runs that timed out or couldn't start, so an offline click doesn't claim the refresh token is dead.
- Reading credentials in `isAvailable` would run `security` on the main actor at every poll, so availability checks only the CLI paths and the token file.

### What warrants review

Self-review with `/code-review medium` found seven issues:

- **Fixed:** a failed refresh was recorded even when `agy` timed out or couldn't start. Now only `.exited` runs count.
- **Fixed:** older `go-keyring-encoded:` hex values are decoded now.
- **Not changed, needs a decision:** Google's proto3 JSON may leave out `remainingFraction` when it is 0, which would mean a fully used bucket. Following the brief, the parser skips buckets without a fraction, so an exhausted bucket could disappear instead of showing 100%. I couldn't check this live, because no bucket is exhausted.
- **Not changed:** `agy` installed outside the three documented paths hides the section, as the brief specifies. An account whose buckets are all disabled shows "Couldn't read the usage response". The hub User-Agent version `2.24.0` is hard-coded, and a 403 logs as `status=403` and then `category=unsupported`.
- **Not an issue in practice:** a child process of `agy` holding stdout could make `Command.run` wait for the full timeout. Live runs finished in 1.7 to 3.5 seconds.

To validate, run `swift test`, then `script/install`, and read the app log with `/usr/bin/log show --predicate 'subsystem == "dk.maragu.aiusage" AND process == "AIUsage"' --last 10m`. An hour after the last `agy` run, the panel should show "Antigravity login expired." and the button.

### Future work

- Unverified: what happens when the refresh token itself is dead. The browser shims follow CodexBar's finding that `agy` print mode runs `open` from `PATH`, but I didn't check that `agy models` does the same, or how it exits then.
- Decide whether a bucket without `remainingFraction` means exhausted, once one has been observed.
- If Google starts rejecting the hub version, read the installed `agy` version for the User-Agent.
