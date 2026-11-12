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

## Step 2: Keep the panel's top edge under the menu bar icon

**Author:** keychain-builder

### Prompt Context

**Verbatim prompt:** Added scope; this replaces "don't touch layout". Markus confirmed the UI bug is the panel's POSITION. In his screenshot the MenuBarExtra panel isn't attached under the menu bar icon: it floats noticeably lower, with a gap of roughly 100 px between the menu bar and the panel's top edge. Likely cause (verify): the panel's content height shrank after it was shown. [...] Fix it so the panel's top edge always sits directly under the menu bar whatever the content height: on first open, after state changes while open, and on later opens. Prefer the simplest robust fix. If you go beyond pure SwiftUI (e.g. adjusting the hosting NSWindow), keep it small and contained. Verify the size-change scenario as well as you can without screen-recording permission (e.g. log the window frame before and after a state change), and tell me what Markus should check visually. Record it in the same new diary file and commit it separately from the Keychain fix.
**Interpretation:** Make sure the `.window` MenuBarExtra panel always hangs directly under its icon, whatever its height, and verify it without being able to see or click the real panel.
**Inferred intent:** The panel should look attached to the menu bar like a native menu bar extra, not float loose after the content changes.

### What I did
First I tried to reproduce the drift with a scratch probe app (`scratchpad/panelprobe`, outside the repo). It is a `.window` MenuBarExtra with AIUsage-like content: a `TimelineView`, sections with limit rows or a wrapping error, dividers, and a footer with a spinner and a checkbox. The probe opens its own panel by sending a synthesized mouse-down to its `NSStatusBarWindow`, then logs window frames on `didResize`, `didMove` and `didBecomeKey`. Only one run opened the panel. In that run the panel's top was 2 pt under the status item window's bottom edge (`top=2124`, `statusBottom=2126`). The top stayed at 2124 while the content shrank from 212 to 84 pt and grew back, both open and closed. So the simple "bottom-left origin stays fixed" hypothesis didn't reproduce on macOS 27.

Because the exact SwiftUI path that drops the panel couldn't be reproduced, I made the fix independent of the cause:

- `/Sources/AIUsageKit/PanelPlacement.swift`: `PanelPlacement.pinnedFrame(for:statusItems:)` is pure geometry. It picks the panel's status item: one that overlaps the panel horizontally and isn't below it, because macOS keeps a status item window per display. It then returns the frame moved vertically so the top sits `gap` (2 pt) under that item, with size and x unchanged. Drift of up to 4 pt is left alone, so the app never fights the system's own placement.
- `/Sources/AIUsage/Views/PanelWindowAnchor.swift`: an `NSViewRepresentable` whose `NSView` watches its own window for `didResize`, `didBecomeKey` and `didChangeScreen`. It also runs when it moves into the window. Each time, it re-pins the window with `setFrameOrigin`, using the frames of the app's own `NSStatusBarWindow`s. When it corrects a drift, it logs `panel repinned top=… to=… height=…` at `notice` level.
- `/Sources/AIUsage/Views/PanelView.swift`: `.background(PanelWindowAnchor())` on the panel content.
- `/Tests/AIUsageKitTests/PanelPlacementTests.swift`: 7 tests with frames taken from the probe's real measurement. They cover a panel already in place, one dropped below, one reaching into the menu bar, small drift, a right-aligned panel, no status item, and a status item on another display. I wrote them before `PanelPlacement`, but I didn't run them red separately. The first run, after I had written the type, passed.

I verified the glue with a second scratch probe (`scratchpad/anchorprobe`) that compiles the real `PanelWindowAnchor.swift` and `PanelPlacement.swift`. It uses a borderless key-capable `NSPanel` hosting the SwiftUI content and a stand-in window class `FakeStatusBarWindow`, both at about (-20000, -5000), off every display, so nothing showed on Markus's screen. I compared a plain panel with an anchored one:

- After a SwiftUI content change (shrink, grow, and shrink while hidden), both kept their top. AppKit's `preferredContentSize` sizing keeps the top-left too.
- After a forced bottom-anchored shrink (`setFrame` with the same origin and a smaller height), the plain panel ended with `gap=42.0`, and the anchored one with `gap=2.0`. The log showed `panel repinned top=-5042 to=-5002`.
- After moving the panel 100 pt down while hidden, then showing it and making it key, the plain panel showed `gap=142.0` and the anchored one `gap=2.0`.

### Why
Pinning on every resize and every open covers all three cases the lead listed: first open, a state change while open, and later opens. It doesn't depend on which SwiftUI or AppKit path moves the window. It's one small view in the app target plus one pure function with tests.

### What worked
- The off-screen anchored panel stayed 2 pt under its stand-in status item through both forced drifts.
- All 7 placement tests passed; the full suite has 92 tests.

### What didn't work
- `button.performClick(nil)` on the `NSStatusBarButton` did nothing (`target=nil action=nil`), and so did `accessibilityPerformPress()` (`press=false`).
- Sending both a synthesized mouse-down and mouse-up with `window.sendEvent` hung the probe: the button's tracking loop waited for a mouse-up that never came. Queuing the mouse-up with `NSApp.postEvent(_:atStart:)` first stopped the hang, but it opened the panel in only one run out of several.
- `swiftc` of the probe with the app's anchor file failed with `error: no such module 'AIUsageKit'`. I removed the import in a scratch copy and added a stub `Log`.

### What I learned
- On this Mac, `NSApp.windows` lists three `NSStatusBarWindow`s for one status item: one at (4288, 2126) and two at (6920, 1130). That is one per display, so the anchor has to pick the one above the panel.
- `screen.visibleFrame.maxY` was 2130 while the status item's bottom was 2126, so the visible frame isn't a reliable "under the menu bar" line here. The status item window is.

### What was tricky
- I couldn't open the real panel without accessibility permission, and the in-process click tricks were unreliable. The verification therefore tests the anchor code against forced drift, not against the exact SwiftUI behaviour Markus saw.

### What warrants review
- `/Sources/AIUsage/Views/PanelWindowAnchor.swift`: it finds status item windows by the private class name `NSStatusBarWindow`. If that name ever changes, the anchor does nothing, and the panel falls back to the system's placement.
- Markus should check visually: open the panel, then click Refresh and watch the panel while the content changes height. Close and reopen it after a state change, such as Claude going from limits to an error. The panel's top edge should stay just under the icon each time. `/usr/bin/log show --predicate 'subsystem == "dk.maragu.aiusage" AND process == "AIUsage"' --last 10m | grep repinned` shows each correction, which also tells us how often the drift really happens.

### Future work
- If `panel repinned` never shows up in real use but the gap comes back, the drift comes from something the anchor doesn't observe, and it needs a new look.

## Step 3: Address the self-review and simplify

**Author:** keychain-builder

### Prompt Context

**Verbatim prompt:** Your /code-review finished, and the result came to me. Findings, condensed, with my guidance. Lean towards simplification: the root cause is gone now that we read via `security`, so much of the new concurrency machinery isn't needed. 1. FetchTimeout.swift:9/13: the hand-rolled FirstOutcome/unstructured-task race breaks structured cancellation [...] Or drop it if the Command timeout plus the URLSession timeouts already bound everything. 2. UsageStore.swift:41/113: the per-provider refreshingIDs/pendingManualIDs machinery is mostly unreachable [...] Prefer the simple global guard. 3. ClaudeCredentials.swift:11: a 10 s timeout kills `security` while a password or Keychain prompt may be on screen [...] Use a longer timeout, about 60 s [...] 4. Command.swift:24: concurrent reads can stack two Keychain prompts. Serialise Claude credential reads, at most one in flight. 5. Command.swift:54/57: a grandchild holding stdout makes readToEnd block past the timeout, and the isRunning check races with natural exit [...] 6. Command.swift:37: duplicates the process/timeout logic in CodexLoginRepair. [...] If it's a big change, note it as future work in the diary instead. Then rerun `swift test`, reinstall, verify live as before, and finish the panel-position fix if not done.
**Interpretation:** Act on the six review findings, preferring removal over more machinery, then test, reinstall and verify again.
**Inferred intent:** Keep the fix as small as the real root cause allows, but make the one remaining timeout path correct.

### What I did
I ran the `code-review` skill at high effort over the Keychain diff. Its result went to the lead, who passed on six findings. My changes for each:

1. I dropped `/Sources/AIUsageKit/Usage/FetchTimeout.swift`, its tests and the `UsageError.timedOut` case. Every fetch is now bounded without it: the Keychain read by `Command`'s timeout, and HTTP by the session's 20 s request and 30 s resource timeouts.
2. I restored the original global `isRefreshing` guard and `needsManualRefresh` in `/Sources/AIUsage/UsageStore.swift`. The only changes left in that file are the `notice`-level `refresh` line and a doc comment that says why the guard can't get stuck now.
3. `ClaudeCredentials.readTimeout` is now 60 s, so a person can answer a Keychain or unlock prompt before the app kills `security`. The README says 60 seconds.
4. New `/Sources/AIUsageKit/Process/SingleFlight.swift`: it allows at most one operation in flight, and callers that arrive meanwhile share its result. `ClaudeProvider`'s default `init` wraps the Keychain read in one. The global guard already serialises refreshes, so this is a second safeguard against two stacked prompts.
5. I rewrote `/Sources/AIUsageKit/Process/Command.swift` around events instead of a blocking `readToEnd()`. stdout comes through `readabilityHandler`, the exit through `terminationHandler`, and the deadline from a sleeping task. All three feed one `AsyncStream`. A run counts as exited when the exit event arrives before the deadline. Its output is then everything read before end of file, or before the deadline if a background child keeps stdout open. Otherwise the result is `.timedOut`: the process gets `Process.terminate()`, then SIGKILL after a 1 s grace if `process.isRunning` is still true. No thread blocks, so the dedicated dispatch queue is gone too.
6. Moving `CodexLoginRepair` onto `Command` is left as future work. Its app-server path is an interactive stdin/stdout conversation that `Command` can't serve, so its exit and terminate helpers would stay anyway. Moving only `runLogin` would also need an `environment` parameter, and it would change a click-only path that I can't verify live without running `codex login`.

I wrote the new tests first. The build then failed with `cannot find 'SingleFlight' in scope`, so I never ran the new `Command` tests against the old implementation on their own. They cover: a fast command returns without waiting for its timeout; a command whose background child holds stdout returns its output at the deadline; a timed-out command with such a child still returns on time; and two `SingleFlight` tests.

### Why
Reading through `security` removed the root cause, the unbounded `SecItemCopyMatching` wait. What's left only has to make the one subprocess reliably bounded and keep prompts from stacking.

### What worked
- `swift test`: 92 tests in 13 suites pass with no warnings. I ran `CommandTests` and `SingleFlightTests` five more times, and all passed.
- After `script/install` the app logged `refresh reason=poll providers=claude,codex`, then `fetch ok provider=codex limits=1` and `fetch ok provider=claude limits=2` at 09:09:32, 290 ms after launch. No SecurityAgent was running.

### What didn't work
Nothing failed in this step.

### What I learned
- An `AsyncStream` can be iterated again after the first loop has exited; `Command`'s kill path does this to wait for the exit after SIGTERM.
- Foundation's `Process` closes the parent's copy of the stdout pipe's write end. stdout therefore reaches end of file as soon as the command exits, unless a child still holds it. The "doesn't wait for the timeout" test checks this.

### What was tricky
- Deciding success versus timeout by the order of events, not by `isRunning`. That removed the race in which a command that had just exited was reported as timed out and its output was lost.

### What warrants review
- `/Sources/AIUsageKit/Process/Command.swift`: the event loop's two exit conditions, and SIGKILL by `processIdentifier` guarded by `isRunning`. Foundation has no SIGKILL API.
- `/Sources/AIUsageKit/Claude/ClaudeProvider.swift`: the `SingleFlight` wrapper in the default `init`.

### Future work
- Move `CodexLoginRepair.runLogin` onto `Command`, with an `environment` parameter, once there is a safe way to test it live.
- Claude Code's next token refresh, when the item's `mdat` changes from 2026-11-12 00:46:15Z, is the real-world test of the `security` read.

## Step 4: Show the Claude weekly percentage in the menu bar

**Author:** keychain-builder

### Prompt Context

**Verbatim prompt:** Can you make the app icon the weekly claude usage percentage? [...] The menu bar item shows Claude's overall weekly percentage as text, e.g. `86%`, INSTEAD of the gauge SF Symbol. Use the limit the Claude provider maps from `weekly_all` (named "Weekly"), not Fable or other scoped limits. [...] Fallback: show the existing gauge icon when there is no current value [...]. Keep the panel's top edge pinned under the menu bar item. [...] Accessibility: give the item an accessibility label such as "Claude weekly usage 86%". [...] Tests for the selection and fallback logic as a pure function. [...] Mid-task change from Markus: drop the percent sign. The menu bar shows just the number, e.g. `86`. Keep the accessibility label with the percentage.
**Interpretation:** Replace the icon with the rounded weekly number, picked by a stable identifier. Fall back to the icon whenever the panel wouldn't show the value as current. Keep the panel pinned when the item changes width.
**Inferred intent:** A glanceable number in the bar, with no way for it to show stale or wrong data.

### What I did
- `UsageLimit` has a new `role: Role?` with one case, `.overallWeekly`. Limit IDs were `"0-weekly_all-"` or the fallback `"seven_day"`, with the index in them, and the only other marker was the display name, so there was no stable identifier. `ClaudeUsageParser` sets the role from the API `kind == "weekly_all"`, and for the legacy `seven_day` fallback. A scoped limit or a lookalike named "Weekly" gets nil.
- `/Sources/AIUsageKit/Usage/MenuBarUsage.swift`: the pure function `weeklyPercent(limits:error:) -> Int?`. It returns nil when the section has any error, because the panel dims its rows then, and the number follows the panel. Otherwise it returns the rounded percent of the first `.overallWeekly` limit, using `UsageFormat.clampedInt`, which is the panel's rounding.
- `UsageStore.menuBarPercent` applies it to the visible Claude section. A missing, loading or error section gives nil.
- `/Sources/AIUsage/Views/MenuBarLabel.swift` is the new `MenuBarExtra` label. It shows the number, or the old gauge `Label` when nil.
- The anchor now also reacts to `didMoveNotification`.
- README: the "only an icon" sentence is replaced.
- Tests: `MenuBarUsageTests` (7), two role tests in `ClaudeUsageParserTests`, and one `PanelPlacementTests` case with icon widths from 24 to 58 pt. The suite has 102 tests and passes.

I wrote the implementation and tests in one go, so I never saw the new tests fail first.

### Why
A template image, not `Text`, because of what a probe showed (below). The `didMove` observer is cheap insurance: the pin stays correct if the system moves an open panel after the item's width changes. It can't loop, because the second call finds the frame already pinned.

### What worked
`scratchpad/labelprobe/probe.swift` is a real `MenuBarExtra` with the same kind of label, and it dumped the `NSStatusBarButton` after each change:

- Icon: image is a template, accessibility title "Gauge With Dots And Needle At 33 Percent", window width 32.
- `Text("86").monospacedDigit()`: the button has `title='86'`, no image, font `.AppleSystemUIFont 13`, and the `.accessibilityLabel` was not applied (accessibility title `86`). The SwiftUI font and label modifiers are lost.
- `Image(nsImage:)` with a template image: the button has the image, and its accessibility title is the image's `accessibilityDescription`, "Claude weekly usage 86%". Window widths were 25 for "9", 33 for "86", and 32 again for the icon.

I rendered the same drawing code to a PNG at 4x (`scratchpad/labelprobe/render.png`) for 9, 10, 86, 88 and 100. The digits sit centred in an 18 pt box, and 10, 86 and 88 all have width 17. After `script/install` the log shows `fetch ok provider=claude limits=2` at launch.

### What didn't work
- `Text(...).monospacedDigit().accessibilityLabel(...)` in the label, as the lead's note suggested. See above: it ends up as a plain title.
- I tried to find the live status item's window with `CGWindowListCopyWindowInfo` by owner name and PID, and it returned nothing, so I couldn't confirm from outside that the installed app shows the number.

### What I learned
- A `MenuBarExtra` label's `Text` becomes the button's plain title. Use an image for control of font or accessibility.
- Status item windows change width with the label (25 to 33 to 32 pt in the probe), but their y and height don't. The pin only looks at y and at horizontal overlap with the 300 pt panel, so width changes don't affect it. The placement test covers that.

### What was tricky
- The weight and size of the digits: `NSFont.menuBarFont(ofSize: 0)` gives 13 pt, and I used its size with `monospacedDigitSystemFont` at regular weight. Whether that matches neighbouring items at the pixel level needs a human look.

### What warrants review
- `/Sources/AIUsage/Views/MenuBarLabel.swift`: the hand-drawn template image. It draws black text in a drawing handler, so it re-renders at the display's scale.
- `/Sources/AIUsage/UsageStore.swift`: `menuBarPercent` matches the section id `"claude"`.

### Future work
- Markus's visual check (see the report).

### Self-review
I ran `/code-review` at medium effort over the diff. It gave seven findings. What I did:

- Fixed: `didMoveNotification` re-enters `pinTop` through `setFrameOrigin`. It stops today because the second call finds the frame in place, but a window that the system clamps could loop. `AnchorView` now has an `isPinning` flag.
- Fixed: the image height is fixed at 18 pt, so a larger menu bar font could clip. It is now `max(18, ascender - descender)`.
- Kept: "any error shows the icon, so a transient error makes the number flip to the icon". That is Markus's rule: the number shows only when the panel shows the value as current, and the panel dims last-known data. It's a product choice to revisit if the flicker is annoying.
- Kept: the doubt that VoiceOver gets the image's `accessibilityDescription`. The probe showed the status item button's accessibility title is exactly "Claude weekly usage 86%".
- Not changed: caching the image per number (cheap to build), a test of the label (a view; the logic is in the tested pure function), the hard-coded `"claude"` id (same as the rest of the app's provider ids), and a fallback if the API renames `weekly_all` (speculative; the icon is the safe failure).

## Step 5: Make the menu bar text always two characters

**Author:** label-builder

### Prompt Context

**Verbatim prompt:** The menu bar text is always exactly two characters, so its width never changes. 0-9 is zero-padded, 10-99 is unchanged, 100 or more shows `XX`. Put this formatting in a pure, tested function in AIUsageKit. The accessibility description keeps the real number. Make sure `XX` renders at the same width as two digits, or as close as the font allows, and say what you found.
**Interpretation:** Add `MenuBarUsage.label(for:)`, use it in the view, and fix the image width so `XX` can't make the item wider.

### What changed
- `/Sources/AIUsageKit/Usage/MenuBarUsage.swift`: `label(for:)`. A negative value (which `clampedInt` can return) shows `00`.
- `/Sources/AIUsage/Views/MenuBarLabel.swift`: draws the label. The image width comes from `"00"`, and the text is centred in it.
- `/Tests/AIUsageKitTests/MenuBarUsageTests.swift`: 0, 1, 9, 10, 86, 99, 100, 101, 120, huge and negative values, plus rounding through `weeklyPercent`.
- `/README.md`: the menu bar sentence.

### What I found
`monospacedDigitSystemFont` at 13 pt makes all digits 8.11 pt wide, so any two digits are 16.22 pt. `X` is not a digit and is 8.75 pt, so `XX` is 17.49 pt, 1.27 pt wider (after `ceil`, 18 vs 17 pt). Sizing the image from the text would have made the item jump by 1 pt at 100%. The image is now always the width of `00`, and `XX` is centred in it, so it overhangs by about 0.25 pt per side. That is inside the glyphs' side bearings, so it shouldn't clip, but I haven't looked at it at pixel level.

### Self-review
Light, as asked. I wrote the function and tests together, so I never saw the tests fail first. The accessibility description still uses the real number, e.g. "Claude weekly usage 100%". `swift test`: 104 tests pass. After `script/install` the log shows `fetch ok provider=claude limits=2`.
