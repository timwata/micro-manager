# Fix plan: follow-up review of `main` (2026-10-10)

Status: Phase 1 implemented; Phase 2 planned.

Source: a whole-repo review of `main` at `b303213` (after all six PRs of
`design/review-fixes.md` were merged). Build and tests were green at that
commit (193 tests, 0 failures, 2 skipped; zero build warnings). Each finding
has an ID (**F1**…). Part 1 explains the problem and the intended fix. Part 2
is the phased checklist the implementing agent works through.

The "another app is also driving this pad" warning that never clears is a
finding of this review too, but it is a feature-sized change with its own
plan: `design/pad-contention.md`.

Line numbers are as of `b303213` and will drift. Find code by the symbol
named, not by the line.

---

## Rules for the implementing agent

- **One phase = one branch = one PR**, based on `main`. Start a phase only
  after the previous phase's PR is merged, then branch from the fresh `main`.
  If you are told to proceed without waiting, stack each branch on the
  previous one and set the PR base to it.
- Branch names and PR titles are listed per phase.
- **Order with `design/pad-contention.md`.** Both plans touch `WLDevice` and
  `BridgeController`. The recommended overall order is: this plan's Phase 1 →
  contention Phase 1 → this plan's Phase 2 → contention Phases 2 and 3. Any
  order works if each PR is rebased on a fresh `main`.
- **Every push to `main` republishes the `latest` release** (`release.yml`).
  Each PR must leave the app fully working by itself.
- Before opening each PR:
  - `swift build -c release` must succeed with zero warnings (check with a
    clean `--build-path` in a temp dir).
  - `env -u HERDR_SOCKET_PATH swift test` must be green. Herdr exports
    `HERDR_SOCKET_PATH` into every pane, and some socket tests skip when it
    is set.
  - Tick this phase's boxes **in this file, in the same PR**.
  - Add a short "Notes" list under the phase for anything that deviates from
    this plan or was decided along the way.
- Match the surrounding style. Doc comments explain *why*, as in
  `BridgeController.swift` and `SSHTunnel.swift`. All code, comments and
  docs are in English. Read `docs/hacking.md` before touching `WLDevice` or
  `KeymapManager`.
- **Scope.** Fix what is listed and nothing else. If you find a new problem,
  add it to "Found during implementation" at the end of this file instead of
  fixing it in the same PR.
- **Findings may be wrong.** If one does not reproduce, or the proposed fix
  turns out to be the wrong shape, do not force it. Record what you found
  under the phase's Notes, adjust or skip, and say so in the PR description.
- **Mutation-check every new test**: break the fix on purpose, confirm the
  test fails (or, for F2, that the test process dies), restore, and record it
  in Notes.
- **What you cannot check.** If the session has no pad or no Accessibility
  grant, never claim a UI or hardware check you did not do. List those under
  "User checks" in the PR description. Headless checks (process inspection,
  `lsof`, `leaks`, `ioreg`, tests on the emulator) are fine and expected.
- Running the debug app writes to the `WLMicroManager` defaults domain, which
  is separate from the installed app's. Always kill any process you launch.
- Items marked **verify** are assumptions. Record the result in the phase
  notes.

---

## Part 1 — Findings and intended fixes

### F1 (medium). Every Herdr request leaks its `SocketConnection`

**Where:** `Sources/WLKit/HerdrClient.swift`, `HerdrClient.request` and
`SocketConnection`; `Sources/WLKit/SSHTunnel.swift`, `SSHTunnel.probe`.

**Problem:** first recorded under "Found during implementation" in
`design/review-fixes.md` (Phase 3) and not fixed since. In `request`,
`conn.onLine` and `conn.onClosed` capture `finish`, and `finish` captures
`conn` strongly. Nothing ever clears the two callbacks, so every connection
is kept alive by its own callbacks: a root cycle of about 2.6 KB plus its
dispatch queue per request. The fd itself is closed. The poll alone makes a
request every 2.5 s (plus focus, tab, tune and panel requests), so the app
grows by roughly 90 MB a day. `SSHTunnel.probe` has the same shape (a probe
every 0.2 s while a tunnel waits for its Herdr).

There is a second path the original note missed: when `open()` fails (no
Herdr running locally, a tunnel not up yet), no read loop is ever started, so
nothing could clear the callbacks even after the fix below. That path runs
on every poll while the local Herdr is down.

**Fix:** break the cycle inside `SocketConnection`, so both callers are fixed
at once:

1. `readLoop()`: in its `defer`, after `onClosed` has been called (or
   skipped), set `onLine = nil` and `onClosed = nil`. The callbacks are set
   before `open()` and only read on the read queue afterwards, so clearing
   them there is safe.
2. `open()`: on every failure path, clear `onLine` and `onClosed` before
   throwing. The caller still holds its own `finish` and reports the error
   through it.

Do **not** capture `conn` weakly in `finish` instead. The read loop holds the
connection only through `[weak self]`, so a weak capture would leave nothing
retaining `conn`, and it would be freed before the reply arrived.

`HerdrEventStream` already captures `[weak self, weak conn]` and is not part
of the cycle; leave it alone.

**Tests** (a new `SocketConnectionLifetimeTests`):

- A connection whose `onLine` captures it strongly (the shape `finish` has),
  opened against `FakeHerdrServer`, answered, and closed from inside
  `onLine`, is freed once the test drops its own reference: hold it with a
  `weak var` and poll for nil with a short deadline (1 s).
- The same for a connection whose `open()` fails (a socket path that does
  not exist): freed after the failure, with no read loop involved.
- The same for a connection the peer closes (the server closes without
  replying): freed after `onClosed`.

**Verify headless** (as in `design/review-fixes.md` Phase 3): run
`WL_EMULATE=1 .build/debug/WLMicroManager` against a local Herdr for about
15 s, then `leaks <pid>`. Before the fix it reports `ROOT CYCLE:
<SocketConnection …>` entries; after it, none. If no local Herdr is
available, run it without one: that exercises the `open()` failure path,
which must show no `SocketConnection` leak either. Record both counts.

### F2 (low, but crashes). A write to a closed Herdr socket raises `SIGPIPE`

**Where:** `Sources/WLKit/HerdrClient.swift`, `SocketConnection.open()` and
`write(_:)`.

**Problem:** nothing in the app ignores `SIGPIPE`, and `SocketConnection`
does not set `SO_NOSIGPIPE`. If the peer has closed the connection when
`write` runs, the kernel sends `SIGPIPE` and the default action kills the
whole app. The window is narrow: the request is written right after
`connect`. But it is real: Herdr shutting down or restarting with
connections still in its backlog, or ssh accepting a forwarded connection
and dropping it at once because nothing listens at the remote path. The
second case is exactly what `SSHTunnel`'s readiness probe does every 0.2 s
while it waits for a remote Herdr.

**Fix:** in `open()`, right after `socket()` succeeds, set `SO_NOSIGPIPE` on
the handle (`setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &one, …)`). A
write to a closed peer then fails with `EPIPE`, which `write`'s `n <= 0`
check already turns into giving up. Do not change the process-wide signal
disposition: a library should not, and the per-socket option covers every
connection the app makes.

**Test:** a fake server (add it to `FakeHerdrServers.swift`) that accepts a
connection and closes it at once without reading. The test opens a
`SocketConnection` to it and writes a payload far larger than a Unix socket
buffer (1 MB), so the write is still blocked when the peer closes and is
bound to hit `EPIPE`. Pass: `write` returns and the test process survives.
Without the fix the test runner dies with `SIGPIPE`; do that mutation check
in a separate `--filter` run and record it.

### F3 (low). The keymap is rewritten to flash on every start when it cannot be fully applied

**Where:** `Sources/WLKit/KeymapManager.swift`, `apply(_:)`.

**Problem:** `apply` writes `withAgentKeymap(config)` whenever
`isAgentKeymapApplied(config)` is false, then re-reads and throws
`notAccepted` if the result still is not applied. But `withAgentKeymap`
silently skips what it cannot place, while `isAgentKeymapApplied` requires
it:

- a key position outside the keymap's rows or columns;
- an `encoders` entry with fewer than two slots;
- a joystick whose `sectors` lack one of the four cardinal sectors.

For such a layout, `apply` writes flash, fails, and does the same again on
the next `start()` and on every reopen after a disconnect (a Bluetooth pad
reconnects after every sleep). The stock layout is not affected; a layout
edited in Work Louder's Input app could be.

**Fix:** decide before writing. In `apply`, compute
`next = try withAgentKeymap(config)`. If `isAgentKeymapApplied(next)` is
false, throw a new `Failure.cannotApply` **without** calling `fs.write`. Its
message says that the device keymap's layout has no slot for every agent
binding, so nothing was written, and that the keys, the dial and the
joystick need their default positions back in Input. Keep `notAccepted` for
a write the firmware did not take.

**Tests** (`KeymapManagerTests`):

- Pure: for each of the three layouts above (built from
  `PadEmulator.stockKeymap()` with one part removed),
  `isAgentKeymapApplied(withAgentKeymap(config))` is false.
- Device: on a `WLDevice` with a `PadEmulator`, write such a layout with
  `fs.write`, then call `KeymapManager.apply`. It throws `.cannotApply`, and
  the emulator saw no `fs.write` after the test's own. Count the writes with
  whatever the emulator exposes (its traffic log); if it exposes nothing
  suitable, add a small internal counter to `PadEmulator`, and keep it
  faithful to the firmware (the counter must not change any reply).
- The stock layout still applies, with exactly one `fs.write`.

### F4 (low). The `IOHIDManager` stays open after a failed connect

**Where:** `Sources/WLKit/WLDevice.swift`, `connect()` and `disconnect(reason:)`.

**Problem:** `connect()` stores and opens the manager before it knows there
is a device. On `notFound`, `noVendorCollection` or `openFailed` it throws
with the manager still open in `self.manager`. `disconnect()` returns early
when `device` is nil, so it never closes that manager. While the pad is
missing, the bridge retries every 3 s, and each retry replaces (and so
releases) the previous manager. But after `stop()` with the pad missing, the
last manager stays open for as long as the bridge is off. **verify:** an
open manager opens devices that match it later, so plugging the pad in while
the bridge is off may leave this process holding it open (visible in
`ioreg` as an `IOHIDLibUserClient` created by this process). If it does, this
also shows up in the contention scan of `design/pad-contention.md`, for
another process that is checking.

**Fix:**

- A private `closeManager()` that closes and drops `manager` if set.
- `connect()` calls it on every throw after the manager was created.
- `disconnect(reason:)` (hardware path) calls it even when `device` is nil,
  before the early return.

**Test:** none. It needs a real IOKit device; say so in the PR. Code review
plus the **verify** above, as a user check if no pad can be unplugged in the
session.

---

## Part 2 — Phased ToDo

### Phase 1 — Herdr socket lifetime (F1, F2)

Branch `fix/followup-1-socket-lifetime` · PR title `fix: free herdr connections and survive closed sockets`

- [x] F1: `SocketConnection.readLoop()` clears `onLine`/`onClosed` after
      `onClosed` in its `defer`.
- [x] F1: `SocketConnection.open()` clears both callbacks on every failure
      path.
- [x] F1: `finish` in `request` and `probe` still captures `conn` strongly
      (no weak capture; see F1).
- [x] F1 tests: `SocketConnectionLifetimeTests` with the three cases (reply,
      `open()` failure, peer close); each mutation-checked.
- [x] F1 **verify**: `leaks` on the headless debug app, before and after,
      with and (if possible) without a local Herdr; counts in Notes.
- [x] F2: `SO_NOSIGPIPE` set in `open()` right after `socket()`.
- [x] F2 test: close-at-once fake server plus a 1 MB write; mutation check
      (test runner killed by `SIGPIPE` without the fix) in Notes.
- [x] `SSHTunnelTests`, `BridgeReentrancyTests`, `HerdrClientRequestTests`
      and `HerdrEventStreamTests` still pass.
- [x] Optional, if the session has the tools: TSan
      (`env -u HERDR_SOCKET_PATH swift test --sanitize=thread --filter
      'SocketConnectionLifetimeTests|HerdrClientRequestTests|HerdrEventStreamTests'`)
      is clean; result in Notes.
- [x] In `design/review-fixes.md`, the leak entry under "Found during
      implementation" points at this phase as fixed.
- [x] `swift build -c release` (zero warnings) and
      `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- **Shape of the `open()` fix.** The socket work moved into a private
  `connect()`; `open()` wraps it, clears both callbacks in one `catch`
  and starts the read loop only on success. That covers every failure
  path at once, including the new one below, instead of clearing at
  each `throw`.
- **`SO_NOSIGPIPE` failure is an open failure.** If `setsockopt` fails,
  `open()` closes the handle and throws `cannotConnect` rather than going
  on with a socket that could kill the app. It is not expected to fail
  on a fresh `AF_UNIX` socket.
- **The F2 fake server cannot close "at once".** The first version of
  `HangUpHerdrServer` closed right after `accept`, and the SIGPIPE test
  passed even with `SO_NOSIGPIPE` removed. The cause was a race in the
  test, not a masked signal (the runner's SIGPIPE disposition was
  `SIG_DFL`, unblocked on the test thread): the client's read loop saw the
  hang-up first and gave up the fd, so `write` returned at its `fd >= 0`
  guard without touching the socket. The server now `poll`s until the
  client's first bytes are pending (1 s cap), then closes without reading
  them, so the 1 MB write is blocked when the peer goes away. The
  peer-close lifetime test uses the same server and sends a request line
  first, i.e. Herdr hanging up on an unread request.
- **Mutation checks.** Each fix removed on its own, then restored:
  - No clearing in `readLoop()`'s `defer`: the reply and peer-close tests
    fail ("the connection outlived its last callback"); the `open()`
    failure test still passes.
  - No clearing in `open()`'s failure path: only the `open()` failure
    test fails.
  - No `SO_NOSIGPIPE`: the test runner exits with "unexpected signal
    code 13" (SIGPIPE), in a separate `--filter` run, 10 runs out of 10.
  - With the fixes, `SocketConnectionLifetimeTests` passed 30 runs out
    of 30.
- **`leaks` (verify).** `WL_EMULATE=1 .build/debug/WLMicroManager`, 15 s,
  then `leaks <pid>`. "With Herdr" set `HERDR_SOCKET_PATH` to the running
  local Herdr; "without" set it to a path that does not exist, which is
  the `open()` failure path.

  | run | before | after |
  |---|---|---|
  | with a local Herdr | 4 `ROOT CYCLE: <SocketConnection>` | 0 |
  | without Herdr (`open()` fails) | 5 `ROOT CYCLE: <SocketConnection>` | 0 |

  Fewer than one per 2.5 s poll before the fix, because a request's
  `finish` is still reachable from its pending timeout for 5 s. That is
  bounded, not a leak, and stays as it is. The remaining reports (about
  290 entries, 14 KB, same before and after) are all
  `NSXPCConnection` / `dispatch_mach_t` cycles for
  `com.apple.linkd.autoShortcut` inside system frameworks, not app code.
- **TSan** on `SocketConnectionLifetimeTests|HerdrClientRequestTests|HerdrEventStreamTests`:
  9 tests, 0 failures, no ThreadSanitizer reports.
- Full suite: 197 tests, 0 failures, 2 skipped. Release build in a clean
  `--build-path`: zero warnings.

### Phase 2 — Device-side hygiene (F3, F4)

Branch `fix/followup-2-device-hygiene` · PR title `fix: no futile keymap writes, close the hid manager on failure`

- [ ] F3: `KeymapManager.Failure.cannotApply` with an actionable message.
- [ ] F3: `apply` checks `isAgentKeymapApplied(withAgentKeymap(config))`
      before writing, and throws `.cannotApply` without `fs.write`.
- [ ] F3 tests: three pure layout cases; the emulator case (no `fs.write`
      after the test's own); the stock layout still writes exactly once.
- [ ] F3: if `PadEmulator` gained a counter, it changes no reply (the
      emulator stays faithful to the firmware); say so in Notes.
- [ ] F4: `WLDevice.closeManager()`; called on every failed `connect()` and
      from `disconnect(reason:)` even when no device is open.
- [ ] F4 **verify** (needs a pad you can unplug, else a user check): with
      the bridge off and the pad unplugged, plug it in; `ioreg -r -n
      "Creator Micro 2" -l -w0 | grep IOUserClientCreator` lists no client
      created by the app. Before the fix, record whether it did.
- [ ] `LiveDeviceTests` still pass with a pad, or skip without one.
- [ ] `swift build -c release` (zero warnings) and
      `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

### Done

- [ ] Both PRs merged; set this file's status to "implemented (PRs #…)".

---

## Found during implementation

(Problems discovered while working through the phases go here, not into the
current PR.)
