# Fix plan: code review of `main` (2026-10-09)

Status: implemented (PRs #9–#14; the plan itself is #8). The one leak left
under "Found during implementation" is planned in `design/followup-fixes.md`.

Source: a whole-repo review of `main` at `c72fefe`. Build and tests were green
at that commit (169 tests, 0 failures, 11 skipped). Each finding below has an
ID (**H** = high, **M** = medium, **L** = low). Part 1 explains the problem and
the intended fix. Part 2 is the phased checklist the implementing agent works
through.

Line numbers are as of `c72fefe` and will drift. Find code by the symbol
named, not by the line.

---

## Rules for the implementing agent

- **One phase = one branch = one PR**, based on `main`. Start a phase only
  after the previous phase's PR is merged, then branch from the fresh `main`.
  If you are told to proceed without waiting, stack each branch on the
  previous one and set the PR base to it.
- Branch names and PR titles are listed per phase.
- **Every push to `main` republishes the `latest` release** (`release.yml`).
  Each PR must therefore leave the app fully working by itself. Do not land
  half a fix.
- Before opening each PR:
  - `swift build -c release` must succeed.
  - `env -u HERDR_SOCKET_PATH swift test` must be green. Herdr exports
    `HERDR_SOCKET_PATH` into every pane, and some socket tests skip when it is
    set.
  - Tick this phase's boxes **in this file, in the same PR**.
  - Add a short "Notes" list under the phase for anything that deviates from
    this plan or was decided along the way.
- Match the surrounding style. Doc comments explain *why*, as in
  `BridgeController.swift` and `SSHTunnel.swift`. Read `docs/hacking.md`
  before touching `WLDevice`. Only Phase 6 (L3) does, and only its `deinit`.
- **Scope.** Fix what is listed and nothing else. If you find a new problem,
  add it to "Found during implementation" at the end of this file instead of
  fixing it in the same PR.
- **Findings may be wrong.** If one does not reproduce, or the proposed fix
  turns out to be the wrong shape, do not force it. Record what you found
  under the phase's Notes, adjust or skip, and say so in the PR description.
- **What you cannot check.** This environment has no pad and no Accessibility
  grant, so you cannot click the menu bar or press keys. Never claim a UI
  check you did not do. List those checks under "User checks" in the PR
  description. Headless checks (process inspection, `lsof`, tests on the
  emulator) are fine and expected.
- Running the debug app writes to the `WLMicroManager` defaults domain. That
  is separate from the installed app's `cc.worklouder.micromanager`, so it is
  safe. Always kill any process you launch.
- Items marked **verify** are assumptions. Record the result in the phase
  notes.

---

## Part 1 — Findings and intended fixes

### H1. The bridge does not start until the menu panel is first opened

**Where:** `Sources/WLMicroManager/MicroManagerApp.swift`, the `.task` on
`MenuPanelView` inside `MenuBarExtra`.

**Problem:** All the wiring and the launch bootstrap live in that `.task`:

- stack, land, voice and tune callbacks, the key intercept and
  `onTargetChange`
- `delegate.bridge = bridge`
- `useEmulator`, then `setTarget`, then `start()`

The content of a `MenuBarExtra` is only built when the panel first opens. So
after launch or login the pad stays dark until the user clicks the icon. The
"login-item launch resumes" promise in the comment is not kept. This was
confirmed headless: `WL_EMULATE=1 .build/debug/WLMicroManager` held no Unix
socket at all after about 9 s, with `bridgeEnabled` unset (which defaults to
on). The same was already noted at the end of `design/remote-herdr-todo.md`
Phase 4.

**Fix:**

1. Make `AppDelegate` `@MainActor` and give it ownership of the bridge:
   `let bridge = BridgeController()`.
2. Move the wiring into a private method on `AppDelegate`, such as
   `wire()`, and call it from `applicationDidFinishLaunching`. Then start a
   `Task` there that runs the bootstrap in the same order as today:
   `useEmulator(BridgeSettings.emulate)`, then
   `setTarget(BridgeSettings.resolvedTarget())`, then
   `start()` if `BridgeSettings.enabled && !bridge.isRunning`.
3. In `MicroManagerApp`:
   - drop `@StateObject private var bridge`
   - inject `delegate.bridge` with `.environmentObject(...)`
   - move the label into a small `MenuBarLabel: View` with
     `@ObservedObject var bridge: BridgeController`, so it still re-renders
     on state changes (the `App` struct cannot observe a delegate's object)
   - remove the `.task`
4. Closure captures: the bridge and the panel singletons all live as long as
   the app. Capture `bridge` strongly through a local `let`, or use
   `[unowned self]` on the delegate, and drop the `[weak bridge]` captures.
   This also clears the six `ImplicitStrongCapture` warnings (part of L10).
   Add one comment explaining why the strong captures are fine.
5. `applicationWillTerminate` keeps calling `bridge.shutdownTunnel()`. It no
   longer needs the `weak var bridge`.

Behaviour that must not change:

- The emulator window is still only shown by the panel's toggle, not at
  launch.
- `MenuPanelView`'s `.onAppear` / `reloadRemotes()` stays as it is.

**Verify headless:**

```sh
swift build --product WLMicroManager
WL_EMULATE=1 .build/debug/WLMicroManager >/dev/null 2>&1 & PID=$!
sleep 6; lsof -p $PID -a -U | wc -l; kill $PID
```

This needs a local Herdr running. Before the fix the count is 0. After it,
the count is at least 1 (the lifecycle stream). If no local Herdr is
available, say so in the notes and rely on code review.

**User check:** after `./scripts/bundle.sh --install`, the pad lights without
opening the menu; opening the panel shows the live state; quit leaves no ssh
running for a remote target.

### H2. Land can push branches the user never confirmed

**Where:** `Sources/WLMicroManager/LandPanel.swift`, `land()`.

**Problem:** The confirmation screen lists `plan`. But `land()` re-reads
`landPlan` after every land and lands whatever comes first, up to 20 times.
If an agent creates or applies a branch while the confirmation is up, or
during the land, that branch is also landed and pushed without consent. This
breaks the file's own rule that landing is not easily reversible, so nothing
may be landed that was not agreed to.

**Fix:** Keep re-reading the plan, since each land rebases what is left, but
only ever land confirmed branches, and stop rather than skip when an
unconfirmed one is in the way. Skipping could land out of order.

1. Add a pure decision function to `GitButler` in WLKit, so it can be tested:

   ```swift
   public enum LandStep: Equatable, Sendable {
       case land(String)
       case done
       case stop(String)   // message for the panel
   }
   public static func nextLandStep(
       plan: [String], confirmed: [String], landed: Set<String>
   ) -> LandStep
   ```

   It applies these rules in order:

   1. `plan` is empty → `.done`.
   2. `plan.first` is in `landed` → `.stop("`X` is still in the workspace after landing it; stopping here.")`.
      This is the existing check, moved here.
   3. Every confirmed branch is in `landed` → `.done`. New, unconfirmed
      branches are left alone, silently.
   4. `plan.first` is not in `confirmed` →
      `.stop("`X` was not in the confirmed plan; stopping before it. Not landed: a, b.")`,
      listing the confirmed branches not yet landed.
   5. Otherwise → `.land(plan.first!)`.

2. In `LandPanelController.land()`, copy `self.plan` into a local
   `confirmed` **before the first `await`**, because `close()` clears it.
   Drive the loop with `nextLandStep`. Keep `maxLands` as the outer bound.
   Append `.stop` messages with `PanelHTML.note`.

**Tests** (`GitButlerLandPlanTests`, or a new `GitButlerLandStepTests`):

- the normal bottom-up sequence
- a new branch appears at the bottom of a confirmed stack → `.stop`, naming
  the confirmed branches not yet landed
- a new branch appears only after every confirmed one has landed → `.done`
- a branch is still present after landing it → `.stop`
- an empty plan → `.done`

### M1. Data race in `HerdrClient.request` can double-resume a continuation

**Where:** `Sources/WLKit/HerdrClient.swift`, `request(_:params:timeout:)`.

**Problem:** The `finished` flag is read and written from three places with
no lock:

- the socket's read queue (`onLine` / `onClosed`)
- a `DispatchQueue.global()` timeout
- the caller's thread (an open failure)

If a reply and the timeout coincide, both pass the guard. The continuation
is then resumed twice, which is a fatal error. `SSHTunnel.probe` already
does this correctly with an `NSLock`.

**Fix:** Use the `probe` pattern. Take the lock, check `finished` and set it,
then release the lock. Only after that call `conn.close()` and resume, and
only for the first caller. The generation check stays.

**Tests:**

- Add a test to `HerdrSocketPathTests` (or a new `HerdrClientRequestTests`)
  using `FakeHerdrServer`: a request with `timeout: 0.2` gets an immediate
  reply, then the test waits 0.4 s. It must not crash, and the result must
  be the reply.
- **verify** with Thread Sanitizer:
  `env -u HERDR_SOCKET_PATH swift test --sanitize=thread --filter HerdrSocketPathTests`.
  Record whether TSan flags `request` before the fix (expected: yes, because
  the timeout's read has no happens-before edge with the reply's write) and
  that it is clean after. If TSan cannot run here, note it.

### M2. `SocketConnection` can read from a recycled file descriptor

**Where:** `Sources/WLKit/HerdrClient.swift`, `SocketConnection.close()` and
`readLoop()`.

**Problem:** `readLoop` copies `fd` under the lock, then calls `read()`
outside it. `close()` on another thread can close that fd in between. A new
socket opened in that window can get the same number, and the old loop then
reads the new connection's bytes. The app opens a short-lived connection per
request plus one per status stream, so fd numbers are reused constantly.

**Fix:** Only the read loop closes the fd.

- `close()`: under the lock, return if already `closed`; otherwise set
  `closed = true` and take `fd`. Outside the lock, call
  `shutdown(fd, SHUT_RDWR)`. This wakes the blocked `read()`, which returns
  0. Do **not** call `Darwin.close` here.
- `readLoop()`: on exit, under the lock, take `fd` and set it to -1.
  Outside the lock, call `Darwin.close`. Then call `onClosed` if
  `close()` was not called.
- `write()`: guard on `!closed && fd >= 0`.
- The failure paths in `open()` already close their own handle. Leave them.
- `close()` called from inside `onLine`, which happens on the read queue
  (`request`'s `finish` does this), must still work: the shutdown makes the
  next `read()` return 0.

**Tests:**

- Add a multi-connection fake server to the test target: it accepts in a
  loop and answers each line with
  `{"id":<same id>,"result":{"token":<params.token>}}`.
- Fire 200 concurrent `HerdrClient.request("echo", params: ["token": i])` and
  assert that every reply carries its own `i`. Crosstalk would show up as a
  mismatched token.
- Also run the TSan command from M1 over the new test.

### M3. Fast dial turns can interleave slash commands

**Where:** `Sources/WLMicroManager/TuneController.swift`, `handleDial` and
`handleJoystick`.

**Problem:** Each dial detent or joystick deflection starts its own `Task`.
`send(command:to:)` is two separate requests (`sendText`, then `sendKeys
["enter"]`). Two tasks in flight can produce
`/effort high/effort xhigh⏎` followed by a stray `⏎`.

**Fix:**

1. Add a tiny `@MainActor final class SerialTaskQueue` to WLKit, in its own
   file. `enqueue(_ work: @escaping @MainActor () async -> Void)` chains
   each new `Task` after the previous one (`await previous?.value`).
2. `TuneController` owns one queue, and both `handleDial` and
   `handleJoystick` enqueue on it, so dial and joystick commands to a pane
   stay ordered relative to each other.
3. Do not coalesce detents. Each detent is one step on the ladder, and the
   index bookkeeping relies on that.

**Tests:** `SerialTaskQueueTests`. Enqueue work items with different sleeps
and assert they complete in enqueue order and never overlap (a counter of
items in flight never exceeds 1).

### M4. `but status --json` parsing breaks on any stderr output

**Where:** `Sources/WLKit/GitButler.swift`, `landPlan` and `launch`.

**Problem:** `launch` sends stdout and stderr to one pipe, and `landPlan`
parses the combined text as JSON. A single warning on stderr, such as an
update notice or a deprecation, makes Land fail with "`but status --json`
returned something unexpected."

**Fix:**

1. Give `launch` a `separateStderr: Bool` parameter. When it is true, wire
   stdout and stderr to separate pipes and drain stderr **concurrently** (a
   global queue plus a `DispatchGroup`), so a chatty stderr cannot deadlock
   the stdout read.
2. Add `errorText: String` to `StatusOutput`. It is empty when the streams
   are merged.
3. `landPlan` uses `color: false, separateStderr: true` and parses stdout
   only. On failure, the thrown message is the trimmed stderr, falling back
   to stdout.
4. `status` and `land`, which are shown to the user, keep the merged single
   pipe. The comment there explains why.
5. Testing seam: make `launch` internal (not private), and add an internal
   `landPlan(in:binary:timeout:)` that the public `landPlan(in:timeout:)`
   calls with `locateBinary()`.

**Tests:** write temporary executable shell scripts in a temp dir (chmod
755):

- one prints `warning: x` to stderr and `{"stacks":[]}` to stdout →
  `landPlan` returns `[]`
- one prints an error to stderr and exits 1 → the thrown message contains
  that error

### L1. A slow `agent.list` can paint over a newer one

**Where:** `BridgeController.refresh()`.

**Problem:** Several refreshes can be in flight at once: the poll, the
debounced events and the tunnel state changes. Whichever finishes **last**
wins, even if it was issued first, so stale agents can show until the next
poll (2.5 s). This is more likely over an SSH tunnel.

**Fix:** Add `refreshIssued` and `refreshApplied` counters. Take
`let seq = refreshIssued + 1` before the fetch. After the fetch, return
unless `seq > refreshApplied`, then set `refreshApplied = seq` and continue.
Apply this only to the success path. The error path keeps its existing
guards.

**Test:** in `BridgeReentrancyTests`, extend `Gate` (or add a sibling) so
each held call can be released on its own. Start the bridge, gate
`listAgents`, start two `forceRepaint()` calls, release the second with
`[B]` and then the first with `[A]`, and assert that `bridge.agents == [B]`.

### L2. A cancelled reopen task can clear its successor

**Where:** `BridgeController.scheduleReopen()`.

**Problem:** After `stop()`, the cancelled task wakes up from
`Task.sleep`. It does not check for cancellation, so if the bridge is
running again it calls `openDevice()` once more. It then sets
`reopenTask = nil` unconditionally, which can drop the handle of the new
task that a later `start()` created.

**Fix:**

- After the sleep: `guard !Task.isCancelled, let self, self.isRunning else { return }`.
- At the end, clear `reopenTask` only if the task was not cancelled. A
  cancelled task's slot already belongs to `stop()`.

No test: there is no seam that makes `openDevice` fail on the emulator. Note
that in the PR, and do not add a seam just for this.

### L3. `WLDevice` does not disconnect on deinit

**Where:** `Sources/WLKit/WLDevice.swift`, `deinit`.

**Problem:** The input and removal callbacks are registered with an
**unretained** `self`. A connected device that is released without
`disconnect` leaves IOKit calling into freed memory, including the freed
`inputBuffer`.

**Fix:** `deinit { disconnect(reason: nil); inputBuffer.deallocate() }`.
The deallocation must come after the disconnect.

### L4. The panel's on/off switch toggles instead of setting

**Where:** `MenuPanelView.header`, the `Toggle` binding's `set`.

**Problem:** It persists `on` but calls `bridge.toggle()`. If the displayed
state is stale, the click does the opposite of what the switch shows.

**Fix:** `if on { await bridge.start() } else { await bridge.stop() }`.

### L5. Remotes are reloaded when *any* window becomes key

**Where:** `MenuPanelView`, `.onReceive(NSWindow.didBecomeKeyNotification)`.

**Problem:** It fires for every window in the app, such as the emulator
window, and re-reads `config.json` each time. The likely worst case is a
re-applied remote that restarts the tunnel.

**Fix:** Capture the panel's own window with a minimal `NSViewRepresentable`
that reports `view.window`, and ignore notifications whose `object` is not
that window. Keep `.onAppear`.

### L6. Tune state survives a target switch

**Where:** `TuneController`: `claudeEffortIndex`, `claudeModelIndex` and the
codex picker state.

**Problem:** These are keyed by pane id, and pane ids are only unique per
Herdr server. After a switch, a pane on the new server can inherit another
pane's ladder position.

**Fix:** Add `TuneController.resetForTargetChange()`. It clears the
dictionaries and the picker state and hides `TunePanelController`. Call it
from the `bridge.onTargetChange` wiring that Phase 1 moved into
`AppDelegate`.

### L7. A rejected subscription is treated as ready

**Where:** `HerdrEventStream.start()`, the first-line handling.

**Problem:** The first line is taken as the acknowledgement even when it is
`{"error":…}`. The stream then sits forever with no events. Separately,
`stopped` and `ready` are touched from the main thread and from the socket
queue without synchronization.

**Fix:**

- If the first line has an `error`, mark the stream stopped and close the
  connection. Then dispatch `onClosed(HerdrError.api(message))` to main.
  `onReady` is never called. The bridge's existing lifecycle retry (2 s)
  and the poll cover recovery; do not change the bridge.
- Guard `stopped` and `ready` with an `NSLock`, as `SocketConnection` does.

**Test:** `FakeHerdrServer` answers the subscribe with
`{"id":"wl_sub","error":{"message":"nope"}}`. Assert that `onClosed` is
called with `.api("nope")` and that `onReady` is never called.

### L8. `askLoginShell` has no timeout

**Where:** `GitButler.askLoginShell()`.

**Problem:** A login shell whose profile blocks (a prompt, a hung network
mount) stalls the `but` lookup, and with it Stack and Land, forever.

**Fix:** The same watchdog as `launch`: terminate after 10 s and return
`nil`. `nil` is already not cached, so the next press retries.

### L9. Outdated keymap error message

**Where:** `BridgeController.ensureKeymap()`.

**Problem:** It says "bound to KV_OAI_AG00..AG06". The app now binds AG00
through AG12 on the keys, plus AG13 to AG18 on the dial and joystick.

**Fix:** Use a range-free message, for example: "Not every key, the dial and
the joystick are bound to their KV_OAI_AG* codes, so some keys will stay
dark and some presses will do nothing. Turn on keymap management or rebind
them."

### L10. Compiler warnings

A clean build at `c72fefe` has these warnings:

- six `ImplicitStrongCapture` warnings in `MicroManagerApp.swift`. Phase 1
  (H1) removes these.
- one `SendableClosureCaptures` warning in `WLDevice+Async.swift:19`
  (`self` captured in `DispatchQueue.main.async`).

**Fix for the second:** `WLDevice` is confined to the main queue. Every
callback is already dispatched there, and `callAsync` hops there. Declare
`extension WLDevice: @unchecked Sendable {}` with a comment stating that
confinement, next to the class's existing note on callbacks.

**Check:** a clean build (`swift build --build-path <tmp dir>`) shows zero
warnings.

---

## Part 2 — Phased ToDo

### Phase 1 — Start the bridge at launch (H1)

Branch `fix/review-1-launch` · PR title `fix: start the bridge at launch, not on first panel open`

- [x] `AppDelegate` is `@MainActor` and owns `let bridge = BridgeController()`.
- [x] Wiring moved from the `.task` into `AppDelegate`, called from
      `applicationDidFinishLaunching`, followed by the bootstrap `Task`
      (emulator, then target, then start-if-enabled, in that order).
- [x] `MicroManagerApp`: no `@StateObject`; `.environmentObject(delegate.bridge)`;
      label extracted to `MenuBarLabel` with `@ObservedObject`; `.task` removed.
- [x] No `[weak bridge]` captures left; zero `ImplicitStrongCapture` warnings.
- [x] Headless check from H1 done; before/after socket counts recorded in
      Notes.
- [x] PR lists the user checks from H1.
- [x] Remove the "Manual check so far" paragraph at the end of
      `design/remote-herdr-todo.md` Phase 4, or point it at this phase.
- [x] `swift build -c release` and `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- Headless check with a local Herdr running, `WL_EMULATE=1`, 6 s after
  launch, counting `lsof -p $PID -a -U` rows without the header: **0** Unix
  sockets before the fix, **4** after (the lifecycle stream plus the
  per-pane status streams). The `WLMicroManager` defaults domain was empty,
  so this ran with the default target (This Mac) and `bridgeEnabled` unset.
  Note that the plan's `lsof … | wc -l` counts lsof's header line too.
- Clean build (`--build-path` in a temp dir): the six `ImplicitStrongCapture`
  warnings are gone; the only warning left is L10's `SendableClosureCaptures`
  in `WLDevice+Async.swift`, which Phase 6 handles.
- The wiring lives in `AppDelegate.wire()`, which takes `let bridge =
  self.bridge` and captures it strongly. `tune.bindings` no longer needs its
  `?? KeyBindings()` fallback.
- `applicationWillTerminate` dropped its `MainActor.assumeIsolated`: the
  delegate is `@MainActor` now.
- `MenuBarLabel` is `private` in `MicroManagerApp.swift`, next to the `App`
  that uses it.
- Also updated the `.task` bullet in `CLAUDE.md`'s "Things that are easy to
  get wrong", which described the old behaviour as current. The historical
  mentions of `.task` in `design/remote-herdr.md` and the Phase 3 log of
  `design/remote-herdr-todo.md` are left as written.

### Phase 2 — Land only what was confirmed (H2)

Branch `fix/review-2-land-scope` · PR title `fix: land only the branches the user confirmed`

- [x] `GitButler.LandStep` and `GitButler.nextLandStep(plan:confirmed:landed:)`
      with the five rules in H2.
- [x] `LandPanelController.land()` captures `confirmed` before the first
      `await` and loops on `nextLandStep`; `.stop` messages go to the panel;
      `maxLands` kept.
- [x] Tests for all five cases listed in H2.
- [x] `swift build -c release` and `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- The tests are a new `GitButlerLandStepTests`, one per case in H2. The
  messages are exactly the two in H2; "Not landed" lists plain branch names
  joined with ", ".
- With an empty `confirmed`, rule 3 answers `.done`. `land()` never gets
  there (the confirmation needs a non-empty plan), and doing nothing is the
  safe answer anyway.
- A confirmed branch that vanished from the plan without us landing it (say,
  landed from elsewhere) still counts as "not landed". If only unconfirmed
  branches are left in front, rule 4 stops and names it, which is accurate.
- **Out of plan, at the user's request:** the app left the pad lit after
  Quit. `applicationWillTerminate` only called `shutdownTunnel()`, and no
  `Task` gets to run after it returns, so `stop()` could not have helped.
  Fixed in the same PR with a synchronous `BridgeController.shutdown()`. It
  tears down the Herdr side (including the tunnel), sends the same two
  blanking calls as `stop()`, closes the device, and leaves the persisted
  on/off alone. Each call still waits for its reply, as every other call
  does, by spinning the main run loop in default mode with a 0.5 s bound per
  call. That works when `terminate` comes from event handling, as Quit and
  the logout Apple event do. Inside a main-queue job, the reply (delivered
  via `DispatchQueue.main.async`) cannot arrive, so each call waits out its
  bound. The writes themselves are synchronous (`IOHIDDeviceSetReport`), so
  the pad still goes dark, just up to 1 s later. Test:
  `BridgeReentrancyTests.testShutdownDarkensThePadBeforeReturning` is
  synchronous for exactly that reason. It checks that the emulator is dark
  when `shutdown()` returns and that no call timed out (< 0.5 s; it takes
  ~12 ms). `allLightsOff()` and `shutdown()` now share `lightsOffCalls`.
  `CLAUDE.md` names `shutdown()` as the quit hook.
- **From the PR review:** the run-loop spin also runs main-queue work queued
  before the quit. A repaint already waiting on `callAsync`'s main-queue hop
  could send its lit `threads` call between the two blanking calls (or its
  `rgbConfig` after them), leaving keys lit after exit. `shutdown()` now
  calls `WLDevice.seal()` before blanking: `call` refuses everything (as
  `notConnected`) until the next `connect()`, and `callBlocking` goes through
  `callThroughSeal`. The seal sits in front of the emulator path too, so the
  emulator catches the race. On top of that, `shutdown()` clears
  `deviceConnected` first and `apply()` re-checks `isRunning &&
  deviceConnected` before its second call. Test:
  `BridgeReentrancyTests.testShutdownWinsOverAQueuedRepaint`, with 0–3
  run-loop passes before `shutdown()`. Without the seal it fails for 1–3
  passes; the seal alone makes it pass. The "never two messages in flight"
  claim in the doc comment was not strictly true (a repaint's reply may still
  be outstanding), so it now says only that the blanking calls go one at a
  time.

### Phase 3 — Herdr socket concurrency (M1, M2, L7)

Branch `fix/review-3-herdr-socket` · PR title `fix: race-free herdr requests and socket teardown`

- [x] M1: `request` guards `finished` with a lock (same pattern as
      `SSHTunnel.probe`).
- [x] M1 test: a late timeout after a reply is harmless.
- [x] M2: `close()` only shuts the socket down; `readLoop` alone closes the fd;
      `write()` checks `closed`.
- [x] M2 test: 200 concurrent echo requests against a multi-connection fake
      server, each getting its own token back.
- [x] L7: an error acknowledgement closes the stream with `HerdrError.api`
      and never calls `onReady`; `stopped`/`ready` lock-protected.
- [x] L7 test with `FakeHerdrServer`.
- [x] **verify** TSan run (`--sanitize=thread`) over the socket tests,
      before and after; results in Notes.
- [x] `SSHTunnelTests` and `BridgeReentrancyTests` still pass (both use
      `SocketConnection`, directly or through the bridge).
- [x] `swift build -c release` and `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- **TSan, before the fix** (`--sanitize=thread` over `HerdrClientRequestTests`,
  `HerdrEventStreamTests` and `HerdrSocketPathTests`): one data race, exactly
  the one M1 predicted — the timeout's read of `finished` on a global queue
  against the reply's write on the socket's queue, in `request`. The
  `stopped`/`ready` accesses of L7 were not flagged: in these tests only the
  socket's queue touches them after `start()`. **After:** zero warnings over
  the same tests plus `SSHTunnelTests`.
- **M2 did not reproduce before the fix**: the echo tests passed five runs out
  of five, and TSan does not see it either (every `fd` access was already
  under the lock; the bug is the number going stale between the unlock and
  `read()`). The window is a few instructions wide. The tests stay as
  regression guards.
- **M2 deviation:** `close()` calls `shutdown` *under* the lock, not outside
  it. Outside, the read loop could end on its own (the peer closed) between
  `close()` reading `fd` and the shutdown, close the fd, and let the number
  be reused, so the shutdown would hit someone else's socket. The loop gives
  up `fd` under the same lock before closing it, so a number `close()` sees
  under the lock is still ours. `shutdown` does not block.
- The read loop now reads `fd` once, before its loop: nobody else closes it,
  so the number stays valid until the loop closes it itself.
- **M2 test additions:** besides the 200 echo requests, a second test sends
  400, half of which the server never answers (0.05 s timeout), so timeouts
  close connections from a global queue while other requests open sockets —
  the path that could actually recycle a number under a blocked loop. Both
  tests keep at most 64 requests in flight: the fake server answers on one
  thread, macOS caps the listen backlog at 128, and a Unix socket refuses a
  connect outright (`ECONNREFUSED`) when the backlog is full. Under TSan, a
  thread-per-client server overflowed it with 200 at once.
- `FakeHerdrServer` moved out of `HerdrSocketPathTests.swift` into a shared
  `FakeHerdrServers.swift` (no longer `private`), next to the new
  `EchoHerdrServer`. The M1 and M2 tests are a new `HerdrClientRequestTests`;
  the L7 test (plus a control: an accepted subscription is ready and delivers
  the next line as an event) is a new `HerdrEventStreamTests`.
- The L7 test counts `onReady` calls instead of using an inverted
  expectation: a fulfilled inverted expectation ended
  `fulfillment(of:timeout:)` early without reporting a failure.
- L7 checks the acknowledgement for an `error` object the same way `request`
  does (`[String: Any]` with an optional `message`, else "api error").
- Headless: `WL_EMULATE=1 .build/debug/WLMicroManager` against a local Herdr
  held 4 Unix sockets at both 6 s and 11 s after launch (as in Phase 1), so
  polling does not leak connections. `LiveHerdrTests` (5) pass against the
  local Herdr.

### Phase 4 — Ordered dial and joystick commands (M3, L6)

Branch `fix/review-4-tune-order` · PR title `fix: send dial and joystick commands in order`

- [x] `WLKit/SerialTaskQueue.swift` plus `SerialTaskQueueTests` (order, no
      overlap).
- [x] `TuneController.handleDial` and `handleJoystick` enqueue on one shared
      queue.
- [x] L6: `TuneController.resetForTargetChange()`, called from
      `onTargetChange` in `AppDelegate`.
- [x] `swift build -c release` and `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- `SerialTaskQueue.enqueue` returns the item's `Task` (`@discardableResult`),
  so the tests can await the last item instead of sleeping. The queue keeps
  only the tail; each item awaits its predecessor, and a finished task has
  already released what it captured, so the chain does not grow.
- `SerialTaskQueueTests` has two tests: six items with mixed sleeps, the
  longest first, finish in enqueue order with at most one in flight, and the
  queue keeps ordering after it has drained. Checked that both fail with the
  chaining removed (items finish out of order, six in flight at once).
- `CLAUDE.md`'s WLKit list now names `SerialTaskQueue`.
- **L6 addition:** `resetForTargetChange()` also bumps a `generation`. An
  item already past `focusedPane()` when the target changes (its reply
  landed just before the switch, the continuation runs after the reset)
  would otherwise write its index under the old server's pane id, or reopen
  the model panel. `dial` and `joystick` check the generation right after
  `focusedPane()`, and the Codex picker path checks it again after its send,
  since it writes the picker state only then. The Claude paths write their
  index before sending, with no `await` in between, so one check covers
  them. `onTargetChange` runs before `teardownHerdr()` with no `await`
  between, so no queued item can start in that gap.
- **Review follow-up (PR #12):** that only covered work already running.
  The queue adds a wait the bare `Task`s never had, and a backlog builds
  whenever items are slow (several round trips per detent over the tunnel,
  or 5 s timeouts on a stalled link). An item still queued at a target
  change started after the switch, took the bumped generation as its own
  and sent `/effort …` to the new target's focused pane. `handleDial` and
  `handleJoystick` now take the generation when they enqueue and pass it
  down; `dial` and `joystick` check it before `focusedPane()` (no
  `agent.list` against the new target, no "Nothing has focus" error) and
  again after it, as before. `TuneController` is in the app target and
  calls `HerdrClient` and `TunePanelController.shared` directly, so the
  test drives the rule rather than the controller:
  `SerialTaskQueueTests.testItemQueuedBeforeAGenerationBumpDropsItself`
  blocks one item, enqueues a second, bumps the generation while the first
  is blocked, and checks that the second does nothing while an item
  enqueued after the bump runs.
- The Codex steering branch was restructured to send its key first and then
  update state, so the generation check sits in one place; the keys sent and
  the state changes per direction are the same as before.
- Not checked here (no pad, no Accessibility grant): fast dial turns and
  joystick deflections against a live Claude / Codex pane, and the model
  panel closing on a target switch. These are listed as user checks in the
  PR.

### Phase 5 — `but` output handling (M4, L8)

Branch `fix/review-5-but-output` · PR title `fix: keep but's stderr out of the land plan JSON`

- [x] `launch(…, separateStderr:)` with stderr drained concurrently;
      `StatusOutput.errorText`.
- [x] `landPlan` parses stdout only; the failure message prefers stderr;
      internal `landPlan(in:binary:timeout:)` seam.
- [x] `status` and `land` unchanged (merged output, colour forced).
- [x] Tests with temporary script binaries (stderr warning plus valid JSON;
      failure with stderr).
- [x] L8: `askLoginShell` watchdog (10 s, returns nil).
- [x] `LiveGitButlerTests` still pass or skip as before.
- [x] `swift build -c release` and `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- The tests are a new `GitButlerOutputTests`, with `/bin/sh` scripts written
  to a temp dir standing in for `but` and for the login shell. Besides the
  two in M4: a failure with nothing on stderr falls back to stdout; 200 KB of
  stderr before any stdout (more than a pipe buffers) still parses, in well
  under the timeout; merged output keeps both streams in order with an empty
  `errorText`. Mutation-checked: with merged streams in `landPlan` the
  warning and stderr tests fail, and with stderr read after stdout instead of
  concurrently the 200 KB test fails (the watchdog kills the script after 5 s).
- `launch` is internal and takes `separateStderr` without a default. A
  private `run(_ binary:_:in:color:separateStderr:timeout:)` does the
  dispatch for both the public `run` (whose signature is unchanged; it stays
  merged) and the `landPlan` seam. `StatusOutput.errorText` defaults to `""`.
- If a failed `but status --json` says nothing on either stream, the message
  is still empty, as before. Left alone (scope).
- **L8 deviation:** not the same watchdog as `launch`. Verified here:
  `Process.terminate()` also takes down the shell's child in its process
  group (a `sleep` under `sh` was gone right after), so a profile blocked in
  an ordinary child is covered either way. But a child in a group of its own
  (`set -m; sleep 5 & wait`) survives, keeps the stdout pipe open, and
  terminate-then-read-to-EOF still blocked for the child's full lifetime. The
  same goes for a shell stuck in the kernel on a hung mount, the plan's own
  example, which does not die until the call returns. So `askLoginShell`
  reads on a global queue and waits on a `DispatchGroup` for at most 10 s; on
  timeout it terminates the shell and returns `nil` without waiting for the
  reader, which is left to finish when the pipe closes. The shell also gets
  `/dev/null` as stdin, so a profile that prompts reads EOF instead of
  waiting. Seam: internal `askLoginShell(_ shell:timeout:)`. Tests: a fake
  shell's answer is used; the `set -m` shell gives up within 3 s at a 0.5 s
  timeout (mutation-checked: with the terminate-then-read watchdog it took
  5.4 s and failed).
- `launch` keeps its terminate-then-read watchdog, so a `but` child that left
  the process group could still hold it past the timeout. Not changed here
  (scope); `but` is not known to do that.
- With `but` 0.22.3 installed (found in `~/.local/bin` by the search list,
  not `PATH`), `LiveGitButlerTests` pass (3/3). Full suite: 192 tests,
  0 failures, 2 skipped. The only build warning left is L10's, for Phase 6.
- `but` 0.22.3 on a failed `status --json` (a repo without `but setup`)
  prints a JSON error object on stdout and
  `Error: Setup required: … - run \`but setup\` …` on stderr, so the panel
  now shows the stderr sentence rather than the JSON plus that sentence.
- Live land check, headless, with a temporary test (not committed) driving
  the same loop as `LandPanelController.land()` (`landPlan` →
  `nextLandStep` → `land`, then `status`) in a throwaway workspace: a stack
  `bottom` ← `top` plus an independent `other`, pushing to a local bare
  remote. The real JSON parsed to `["other", "bottom", "top"]`. With `other`
  left out of `confirmed`, the first step stopped before it and named
  `bottom, top` (Phase 2). With all three confirmed, they landed one by one
  as the plan was re-read (`["bottom", "top"]`, then `["top"]`, then `[]` →
  `.done`), and the remote's `main` ended up `base → c → a → b`. A land that
  failed (a remote URL `but` could not reach) came back `succeeded == false`
  with git's error in the merged `text`, as the panel shows it. Not checked:
  the Land panel itself and the land key (no pad, no Accessibility grant).

### Phase 6 — Bridge, device and panel polish (L1, L2, L3, L4, L5, L9, L10)

Branch `fix/review-6-polish` · PR title `fix: bridge and panel robustness`

- [x] L1: refresh sequencing, plus the out-of-order test in
      `BridgeReentrancyTests`.
- [x] L2: the reopen task checks cancellation after its sleep and only clears
      its own slot.
- [x] L3: `WLDevice.deinit` disconnects before deallocating the buffer.
- [x] L4: the panel switch calls `start()`/`stop()` according to `on`.
- [x] L5: key-window reloads limited to the panel's own window.
- [x] L9: range-free keymap error message.
- [x] L10: `WLDevice` declared `@unchecked Sendable` with a confinement
      comment; a clean build has zero warnings.
- [x] `swift build -c release` and `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- **L1:** the sequence check sits after the `if linkUp` block, so it also
  covers a refresh that read nothing because the link was down. That empty
  pad is newer than a read still in flight from before the drop, and the
  success path (unlike the error path) never re-checks `linkUp`, so without
  this the late read would repaint the old agents. `lastError` is cleared
  only by a read that is actually applied, so a stale success cannot wipe a
  newer error. The error path is unchanged, as planned.
- **L1 test:** `Gate` now numbers calls in arrival order and can release one
  by number (`release(call:with:)`); `release(_:)` still releases them all.
  The test builds its own bridge with a one-hour `pollInterval`, so no poll
  can take a call number between the two `forceRepaint()`s. Mutation-checked:
  without the `seq > refreshApplied` guard it fails with the older agent
  showing.
- **L2:** the slot is cleared from a `defer`, only when the task was not
  cancelled, so the early `return`s are covered too. No test, as planned
  (no seam makes `openDevice` fail on the emulator).
- **L3:** no test: the leak needs a real IOKit device. A report already
  queued to main when the device is released is not a problem: the callback
  runs on the main run loop (as `deinit` does) and the queued block holds
  `me` strongly, so `deinit` cannot run while one is pending.
- **L4:** `BridgeController.toggle()` has no callers left. Kept (scope).
- **L5:** `WindowReader` reports `view.window` from `viewDidMoveToWindow`.
  The window is kept weakly in a small class instead of `@State`, so
  recording it never triggers a view update (it can arrive mid-update).
  Before the first report the panel's window is unknown and notifications
  are ignored; `.onAppear` covers that first opening.
- **L10:** a clean build (`swift build --build-path <tmp>`) has zero
  warnings. Checked the other way round too: with the conformance removed,
  the `SendableClosureCaptures` warning at `WLDevice+Async.swift:19` is back.
- Full suite: 193 tests, 0 failures, 2 skipped. `WL_EMULATE=1` debug app
  (with `HERDR_SOCKET_PATH` unset) ran for 8 s headless without trouble and
  was killed. Not checked (no Accessibility grant, no pad): clicking the
  panel switch, and that opening the emulator window no longer re-reads
  `remotes` while opening the menu panel still does.

### Done

- [x] All six PRs merged; set this file's status to "implemented (PRs #…)".

---

## Found during implementation

(Problems discovered while working through the phases go here, not into the
current PR.)

- **Pad stayed lit after Quit** (found by the user while Phase 2 was in
  progress). Fixed in the Phase 2 PR at the user's request; see Phase 2's
  Notes.
- **Every Herdr request leaks its `SocketConnection`** (found during Phase 3,
  not fixed there). In `HerdrClient.request`, `conn.onLine` and
  `conn.onClosed` capture `finish`, which captures `conn` strongly, and
  nothing ever clears the callbacks; `SSHTunnel.probe` has the same shape.
  `leaks` on `WL_EMULATE=1 .build/debug/WLMicroManager` after 12 s against a
  local Herdr: `ROOT CYCLE: <SocketConnection …>` (about 2.6 KB each, with its
  dispatch queue), one per request. The fd itself is closed. The poll alone
  makes a request every 2.5 s, so the app grows by roughly 90 MB a day.
  Likely fix: have the read loop drop `onLine`/`onClosed` when it exits, or
  capture `conn` weakly in `finish`. **Not fixed by this plan.** Planned as
  F1 in `design/followup-fixes.md`, which also rules out the weak capture
  (nothing else would retain `conn`) and covers the `open()` failure path.
