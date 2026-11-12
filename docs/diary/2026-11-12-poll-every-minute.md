# Diary: Poll every minute

Markus asked to refresh once a minute instead of every 5 minutes, and to drop the refresh when the panel opens.

## Step 1: Poll every 60 seconds and remove refresh-on-open

**Author:** builder

### Prompt Context

**Verbatim prompt:** Requirement from Markus: refresh once a minute. Change the poll interval from 5 minutes to 60 seconds, for both providers. Remove the refresh-on-panel-open (the `.panelOpened` reason) and its now-dead code and tests, and re-express the backoff test with polls. Keep the backoff behaviour, the Codex login-repair re-poll and the "Updated X ago" footer. Update the README.
**Interpretation:** Change `UsageStore.pollInterval` to 60 s, delete `.panelOpened`, `panelDidOpen`, `panelRefreshAge`, `lastAttempts` and the panel's hooks, and rewrite the affected tests with polls.
**Inferred intent:** A simple fixed cadence that caps requests at one per provider per minute, without the extra panel-open path.

### What I did
In `/Sources/AIUsage/UsageStore.swift` I set `pollInterval` to 60 s and removed the `panelOpened` case, `panelRefreshAge`, `panelDidOpen()` and the staleness branch in `isDue`. `lastAttempts` was only used by that branch, so I removed it too. `isDue` no longer takes a `reason`. In `/Sources/AIUsage/Views/PanelView.swift` I removed `onAppear` and the `didBecomeKey` task, and the unused `AppKit` import. In `/Tests/AIUsageTests/UsageStoreTests.swift` I deleted the "soon after a fetch" test and rewrote the Retry-After test with polls every 60 s. I added a test for exponential backoff from 5 minutes (299 s skipped, 300 s fetches, then 599 s skipped, 600 s fetches). I updated `/README.md`.

### Why
With a 1-minute poll, a refresh on open adds nothing and would allow more than one request per minute.

### What worked
`swift test` passes (104 tests). The "Updated X ago" footer reads fine: the poll sleeps 60 s after each fetch ends, so the text shows "just now" for most of a cycle and "1m ago" just before the next. The view re-renders every 30 s, so it can show "1m ago" briefly. No change needed.

### What didn't work
Nothing failed.

### What I learned
Backoff keeps working with a 60 s poll because `isDue` checks `Backoff.allowsAttempt` on every tick, so most polls during a backoff are skipped silently.

### What was tricky
Nothing notable.

### What warrants review
`isDue` in `/Sources/AIUsage/UsageStore.swift` and the two backoff tests.

### Future work
None.

Verified after `script/install`: the log shows `refresh reason=poll providers=claude,codex` at 11:39:48, 11:40:49, 11:41:49 and 11:42:50, about every 60.4 s, with all fetches returning 200. No `panelOpened` refreshes exist any more. Light self-review of the diff found no issues.

## Step 2: Poll every 2 minutes and log rate limits

**Author:** builder

### Prompt Context

**Verbatim prompt:** Change the poll interval to 120 s, for both providers, keeping one shared interval. Update the tests that assume 60 s polls and the README sentence. When a provider gets a 429, log the Retry-After value, or that it was absent, along with the resulting backoff delay at `notice` level. Before changing anything, check the most recent Claude 429 in the logs and report what the app did afterwards.
**Interpretation:** Raise `UsageStore.pollInterval` to 120 s, add one `rate limited` log line in `apply`, and check the earlier 429 against the backoff design.
**Inferred intent:** At 60 s Claude's usage endpoint returned a 429 after about 25 minutes of 200s. Polling at 2 minutes is gentler, and the new log line shows how long the real limit window is.

### What I did
In `/Sources/AIUsage/UsageStore.swift` I set `pollInterval` to 120 s and added `logRateLimit`, called from `apply` after the backoff is recorded. It logs `rate limited provider=claude retryAfter=<seconds or none> backoff=<seconds>` at `notice`, with the backoff computed from `Backoff.notBefore`. It logs no headers other than the `Retry-After` value, and no bodies. I rewrote the Retry-After test in `/Tests/AIUsageTests/UsageStoreTests.swift` for 120 s polls (7 skipped polls, then a fetch at 1080 s) and updated `/README.md`.

### Why
Without the log line, the log shows only `category=rateLimited`, so we can't tell whether the server sent `Retry-After` or how long the app then waited.

### What worked
The earlier 429 behaved as designed. Claude got 429 at 12:04:00 (poll at 60 s). The next four polls (12:05 to 12:08) fetched only Codex. The poll at 12:09:02 fetched Claude again and got 200. That is the first poll after the 300 s minimum backoff (12:09:00.3), so the backoff was the first-failure step of the exponential schedule. We can't tell if the header was present, because the old code did not log it. If it was present, it was 300 s or less. `swift test` passes (104 tests).

### What didn't work
Nothing failed.

### What I learned
The limit cleared within about 5 minutes: a 200 came back on the first retry after the backoff. The new log line will show the value of `Retry-After` next time.

### What was tricky
I waited for the 12:09 retry before running `script/install`. Restarting the app earlier would have reset the in-memory backoff and hidden the behaviour I wanted to check.

### What warrants review
`logRateLimit` in `/Sources/AIUsage/UsageStore.swift`. It has no unit test, because the logger is not injectable.

### Future work
Read the `rate limited` lines after the next 429 to learn the real window, and consider a longer interval if 429s keep coming at 120 s.
