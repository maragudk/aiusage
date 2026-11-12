# Diary: Fix the Claude "Token expired" and stuck "Updating…" bug

After about a day of running, AIUsage showed "Token expired, open Claude Code to refresh" for Claude, even though Claude Code was logged in and working. The footer stayed on "Updating…" with a spinner, while Codex kept working. This diary covers finding the root cause and making the Claude credential read and the refresh loop robust.

## Step 1: Find the root cause and read the credentials through `security`

**Author:** keychain-builder

### Prompt Context

**Verbatim prompt:** Bug-fix round on AIUsage, a Swift/SwiftUI macOS menu bar app that shows Claude and Codex subscription usage. [...] Symptom (from Markus, live): The app ran fine for about a day. Now: The Claude section shows "Token expired, open Claude Code to refresh", but Claude Code is logged in and working. The footer is stuck on "Updating..." with a spinner. Codex still works (20%). [...] Leading hypothesis (verify, don't assume): When Claude Code rewrites the item [...] the item's ACL / trusted-app list may be reset. [...] Requirements: 1. Find and confirm the root cause. [...] 2. Make the Claude credential read robust to Claude Code rewriting the item. Preferred approach: read via `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` as a subprocess [...] with a timeout of about 10 s, and close stdin. [...] 3. Correct error mapping. [...] 4. Refresh must never stay stuck. [...] 5. Fix logging [...] 6. Tests [...] 7. Reinstall with `script/install` and verify live [...] 8. Update the README [...] 9. Self-review, diary, and commit (git skill).
**Interpretation:** Prove why the Claude read broke, then replace the direct Keychain API read with a timed `security` subprocess. Map each failure to an accurate message, and make sure no provider can hang the refresh loop.
**Inferred intent:** The app must keep working after Claude Code refreshes its token, without Keychain prompts, and must never sit in a stuck state again.

### What I did
I worked out the root cause from live evidence, using read-only commands only:

- `/usr/bin/log show --last 30h --predicate 'subsystem == "dk.maragu.aiusage"'` showed that logging worked. The last lines were `fetch failed provider=claude category=loginExpired` at 17:15 and 17:23 yesterday, then `fetch ok provider=codex` at 17:28:18, and then nothing for 15 hours. The lead's `--last 12h` query was empty only because the app had logged nothing since then.
- Neither `loginExpired` line had a `fetch provider=claude status=` line before it. So both came from the local `expiresAt` check, not from HTTP 401. At that time the token really had expired, because Claude Code hadn't refreshed it yet.
- `sample 38153` showed the `dk.maragu.aiusage.keychain` queue thread blocked in `SecItemCopyMatching` → `SecKeychainItemCopyContent` → `ClientSession::decrypt` → `mach_msg`. In other words, it was waiting for securityd.
- SecurityAgent (pid 39424) had started at 17:28:17, the same second as that refresh. securityd logged `ACL partition mismatch: client teamid:45KZY97W64 ACL ("apple-tool:")` and then `displaying keychain prompt for /Applications/AIUsage.app(38153)`. Nobody saw the prompt in time, so the read blocked for 15 hours.
- `security dump-keychain -a` (attributes and ACLs, no `-d`, so no secret data) on the item showed that the trusted-apps list still holds `/Applications/AIUsage.app` and `/usr/bin/security`. The `partition_id` entry, however, held only `apple-tool:`. `cdat` was still 2026-05-06, so Claude Code updates the item in place with the `security` tool. That update resets the partition list and drops the `teamid:45KZY97W64` entry that "Always Allow" had added. Because the app is still in the app list but not in the partition list, macOS prompts again.

So the "Token expired" text was stale but true when it was set. The stuck "Updating…" came from the hung Keychain read: the global `isRefreshing` guard then dropped every later refresh, for both providers. Codex's "20%" was from 17:28.

The fix:

- `/Sources/AIUsageKit/Process/Command.swift`: `Command.run` runs a short command on a dedicated concurrent `DispatchQueue`, never on the cooperative pool or the main actor. Stdin is `/dev/null` and stderr is discarded. It reads stdout to EOF and enforces a timeout: SIGTERM, then SIGKILL after 1 s. It returns `CommandResult` (`.exited(status:output:)`, `.timedOut` or `.launchFailed`). `Command.Runner` is the injectable signature.
- `/Sources/AIUsageKit/Claude/ClaudeCredentials.swift`: `readFromKeychain(account:run:)` runs `/usr/bin/security find-generic-password -s "Claude Code-credentials" -a <user> -w` with a 10 s timeout. If the item isn't found, it retries without `-a`. It maps exit 0 to the password (trailing newline stripped, hex output decoded), 44 (`errSecItemNotFound`) to `notLoggedIn`, and 51 and 128 (auth failed or cancelled) to `keychainDenied`. Any other status maps to `keychainReadFailed(status:)`, a timeout to `keychainTimedOut`, and a launch failure to `keychainToolFailed`. The `Security` import and `SecItemCopyMatching` are gone.
- `/Sources/AIUsageKit/Claude/ClaudeProvider.swift`: the reader is now `async`, and the old dedicated keychain queue is gone. Nothing is cached; every fetch re-reads the item.
- `/Sources/AIUsageKit/Usage/UsageError.swift`: added `keychainReadFailed(status:)` (which replaces `keychain(status:)`), `keychainTimedOut`, `keychainToolFailed` and `timedOut`, each with its own message and category. The two timeouts back off; all four keep the last data. `loginExpired` is still raised only by the local `expiresAt` check and by HTTP 401.
- `/Sources/AIUsageKit/Usage/FetchTimeout.swift`: `UsageProvider.fetchLimits(timeout:)` returns a `Result`. It returns `.timedOut` at the deadline even when the fetch ignores cancellation, because it resumes a continuation on the first outcome instead of awaiting the child. The fetch is then cancelled.
- `/Sources/AIUsage/UsageStore.swift`: the global `isRefreshing` flag is replaced by `refreshingIDs`, so each provider has at most one fetch in flight and a slow one doesn't block the others. `isRefreshing` is now computed from it. Each fetch has a 60 s backstop timeout (`fetchTimeout`). A manual refresh of a provider that is in flight is remembered in `pendingManualIDs` and runs for just that provider when its fetch ends. The `refresh reason=` line now logs at `notice`, so it persists.
- `/README.md`: rewrote "Keychain access" to explain the `security` read and why the app doesn't use the Keychain API. It also covers the 10 s prompt timeout, Deny, and when "Token expired" appears. The log command now uses `/usr/bin/log`, with notes about the zsh builtin and about test runs logging under the same subsystem.

Tests came first: `/Tests/AIUsageKitTests/ClaudeCredentialsTests.swift` (a fake runner, so no real Keychain access), `/Tests/AIUsageKitTests/CommandTests.swift` (real `/bin/sh` and `/bin/cat` only) and `/Tests/AIUsageKitTests/FetchTimeoutTests.swift`. I also added one more case to `/Tests/AIUsageKitTests/ClaudeProviderTests.swift`. They failed to compile first (`type 'UsageError' has no member 'timedOut'`), then passed: 85 tests in 12 suites.

### Why
`/usr/bin/security` sits inside the `apple-tool:` partition and is in the item's app list. Claude Code itself writes through `security`, so every rewrite keeps that tool trusted. No grant to AIUsage is needed, and the app never touches the ACL. Each read is bounded by its own timeout and by the store's timeout, so a hidden prompt can no longer freeze refreshes.

### What worked
- After `script/install`, the new app logged `refresh reason=poll providers=claude,codex`, then `fetch provider=claude status=200` and `fetch ok provider=claude limits=2` at 08:49:45.757. That was 270 ms after launch, with no prompt. `fetch ok provider=codex limits=1` followed.
- A second `dump-keychain -a` afterwards showed that the item's partition list was still only `apple-tool:`. The app reads the item without any AIUsage-specific grant, and it changed nothing.
- `security find-generic-password -s "aiusage-nonexistent-probe-item" -w` exits 44, which confirms the exit-status mapping for a missing item.

### What didn't work
- A Python heredoc that edited two Swift files was refused: `This session is isolated in the worktree ... but this command is too complex to verify that it stays inside the worktree. Refusing to run it`. I switched to the Write and Edit tools.
- `#expect(try result.get().map(\.name) == ["Weekly"])` in a non-throwing test gave `errors thrown from here are not handled`; the test now `throws`.
- The first `security dump-keychain -a` with a 15 s kill timer cut off before it reached the item. The full dump takes about 14 s.

### What I learned
- Since Sierra, the legacy Keychain checks two things: the item's trusted-app list and its partition list. "Always Allow" adds the app's `teamid:` to the partition list, and `security add-generic-password -U` (or whatever update path Claude Code uses) sets the list back to `apple-tool:`. An app can be shown as "(OK)" in the app list and still get prompted.
- `security` exits with the low byte of the `OSStatus`: -25300 → 44, -25293 → 51, -128 → 128.
- During the reinstall, the old SecurityAgent dialog was still alive. Its log shows text-cursor activity at 08:37 and 08:49, and a button action at 08:49:46.59. securityd then logged `adding XARA partition 'teamid:45KZY97W64' to list`. The post-install dump showed no change to the Claude item, probably because the requesting process had already been killed. The new app's successful read came one second before that click.

### What was tricky
- A task group can't time out a child that ignores cancellation, because leaving the group waits for every child. `fetchLimits(timeout:)` therefore resumes a continuation from whichever comes first, the fetch task or a timer task, and drops the loser.
- Per-provider in-flight tracking needed care with manual refreshes. A pending manual refresh must rerun only the provider that was busy. Otherwise a rerun would refetch the provider that had just finished.

### What warrants review
- `/Sources/AIUsageKit/Process/Command.swift`: the watchdog and SIGKILL logic, and reading stdout to EOF. A grandchild that inherits stdout would keep the read open. `security` doesn't fork, and the store's 60 s timeout is the backstop.
- `/Sources/AIUsageKit/Usage/FetchTimeout.swift`: `FirstOutcome` resumes the continuation exactly once.
- `/Sources/AIUsage/UsageStore.swift`: `refreshingIDs` and `pendingManualIDs`.
- Live: `/usr/bin/log show --predicate 'subsystem == "dk.maragu.aiusage" AND process == "AIUsage"' --last 10m`.

### Future work
- The real proof comes after Claude Code's next token refresh, when `mdat` changes: the app should keep logging `fetch ok provider=claude` with no prompt.
- The footer text "Updated just now" wasn't checked on screen, because I can't open the menu bar panel. It is derived from `lastSuccess`, which the `fetch ok` lines confirm.
