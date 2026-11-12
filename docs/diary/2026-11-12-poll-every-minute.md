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
