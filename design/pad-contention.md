# Pad contention: a warning that can clear

Status: Phases 1–3 implemented.

The panel warns "Another app is also driving this pad — colours may fight."
when something else talks to the pad. Once raised, the warning stays until
the bridge is switched off and on again, even after the other app has quit.
This plan makes it clear in two steps:

- **Phase 1 (option A):** a manual **Recheck** button, and the warning
  cleared when the bridge stops. Small, and needs no hardware to build.
- **Phases 2–3 (option C):** an active check that asks the IORegistry which
  other processes hold the pad open. It runs whenever the panel opens, so to
  the user the warning updates by itself, and it names the other app.

Option B (expire the warning N seconds after the last foreign reply) was
considered and rejected: detection by traffic is passive, so an idle client
is invisible either way, and a client that only talks now and then would
make the warning come and go.

Line numbers are as of `b303213` and will drift. Find code by the symbol
named, not by the line.

---

## Rules for the implementing agent

The same rules as `design/followup-fixes.md` § "Rules for the implementing
agent" apply: one phase = one branch = one PR based on `main`, tick the boxes
in this file in the same PR, Notes per phase, a "Found during
implementation" list for anything out of scope, mutation-check new tests,
never claim a hardware or UI check you did not do, English throughout, read
`docs/hacking.md` before touching `WLDevice`. The recommended order across
both plans is in that file.

Phase 2 has a **gate**: its hardware findings decide whether Phase 3 is built
as designed here, adjusted, or dropped. Do not start Phase 3 until Phase 2's
Notes record those findings.

---

## Part 1 — Background and design

### How detection works today

- `WLDevice` opens the pad **shared**: a seizing open fails with
  `0xE00002C1`, because macOS will not let anything seize a device that
  carries a keyboard collection (see the `WLDevice` doc comment and
  `docs/hacking.md`). So every client receives every other client's replies.
- `BridgeController.wire(_:)` records every id it sends (`device.onTX` →
  `issuedIDs`) and, on each reply (`device.onResponse`), sets
  `contendingClient = true` when the id is not one it issued.
- `contendingClient` is reset only in `start()`. `stop()` leaves it set, and
  the panel (`MenuPanelView`, the `if bridge.contendingClient` block) shows
  it whether or not the bridge is running.
- Detection is passive. A client that has the pad open but sends nothing is
  never seen, and clearing the flag proves nothing until the other client
  next sends a request.

A common way to trip it is the panel's own **Inspector** button: the
Inspector is a separate process that opens the same pad. Close it, and the
warning stays.

### What the IORegistry shows

Observed on 2026-10-10 with a Creator Micro 2 on USB, the installed app
running, and `ioreg -r -n "Creator Micro 2" -l -w0`:

- Each USB interface of the pad is its own `IOHIDDevice` service
  (`AppleUserUSBHostHIDDevice`). A process that opens one gets an
  `IOHIDLibUserClient` child under it, whose `IOUserClientCreator` property
  reads `"pid <n>, <process name>"`.
- On the vendor interface (`PrimaryUsagePage` = 65280 = `0xFF00`, the one
  `WLDevice` talks to), the only client was MicroManager.
- On the keyboard interface, Discord and Discord Helper held clients. They
  never talk to the pad's vendor protocol, so counting every client of every
  interface would be wrong.
- MicroManager also held a client on the consumer-control interface:
  `IOHIDManagerOpen` opens every interface that matches its vendor-only
  filter, not just the one `WLDevice` picks.
- Process names in `IOUserClientCreator` can be cut short
  (`"Discord Helper ("`), so they make a poor label.

So for a pad on USB, "other processes with a client on the vendor interface"
is an exact, active answer to "who else can drive the lighting". On
Bluetooth the pad is a single `IOHIDDevice` that carries the keyboard too
(see `WLDevice.connect()`), so the same list may include keyboard listeners
such as Discord. Phase 2 checks this.

### Option A — manual recheck (Phase 1)

- `BridgeController.recheckContention() async`: sets
  `contendingClient = false`, then, if running, `await forceRepaint()`. The
  repaint puts our colours back over whatever the other app painted, which
  is what the user wants after quitting it.
- **Never clear `issuedIDs`** in a recheck. A reply to one of our own calls
  still in flight would then look foreign and raise the warning again at
  once.
- `stop()` clears `contendingClient`: an off bridge drives nothing, so there
  is nothing to fight over. `start()` already clears it.
- Testing seam: move the body of the `device.onResponse` closure in
  `wire(_:)` into an internal `func noteResponse(id: Int)`, so a test can
  inject a reply id the bridge never issued. The closure calls it; behaviour
  is unchanged.
- Panel: the warning row gets a small **Recheck** button, laid out like the
  link status's **Retry** (`HStack(alignment: .firstTextBaseline)`, text,
  `Spacer`, `.controlSize(.small)`), with the help text "Clear the warning.
  It comes back if the other app sends to the pad again." The warning text
  stays as it is.

### Option C — active check (Phases 2–3)

#### WLKit: scanning the registry (Phase 2)

```swift
/// A process other than this one that holds the pad open.
public struct HIDClient: Equatable, Sendable {
    public let pid: pid_t
    /// From `NSRunningApplication`, else the registry's (possibly cut) name.
    public let name: String
}

public enum HIDClientScan: Equatable, Sendable {
    /// Nothing to scan: the emulator, no open device, or a registry error.
    case unavailable
    /// The opened device is a dedicated vendor interface (its primary usage
    /// page is 0xFF00): every other client there can drive the lighting.
    case authoritative([HIDClient])
    /// The opened device also carries the keyboard (Bluetooth): other
    /// clients may only be listening for keys.
    case advisory([HIDClient])
}

extension WLDevice {
    public func otherClients() -> HIDClientScan
}
```

- Walk: `IOHIDDeviceGetService(device)` →
  `IORegistryEntryGetChildIterator(service, kIOServicePlane)` → children for
  which `IOObjectConformsTo(child, "IOHIDLibUserClient")` → read
  `IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, …)`.
  Release every `io_object_t`.
- Only the service of the `IOHIDDevice` that `WLDevice` opened is scanned,
  not its siblings: that is what keeps the keyboard interface's listeners
  out on USB.
- Parsing is a pure, internal `static func parseCreator(_ value: String) ->
  (pid: pid_t, name: String)?` for `"pid <n>, <name>"`. It returns nil for
  anything else.
- Drop entries whose pid is `getpid()` (this process may hold several), and
  de-duplicate by pid (one process may hold several clients).
- Label: `NSRunningApplication(processIdentifier:)?.localizedName`, falling
  back to the parsed name. The Inspector is then "Inspector" (or whatever its
  bundle calls itself).
- Authoritative vs advisory: `.authoritative` when the opened device's
  `PrimaryUsagePage` is `WLDevice.vendorUsagePage`, `.advisory` otherwise.
  Phase 2's hardware checks confirm or change this rule.
- The scan reads a handful of registry entries and is synchronous. Calling
  it on the main actor is fine; measure it once (Notes).

`IOUserClientCreator` is not documented API. It has been stable for many
macOS releases and `ioreg` shows it, but every failure (property missing,
unexpected format) must degrade to `.unavailable` or to a client list
without that entry, never to a crash or a false warning. A scan that does
not see this process's own client is `.unavailable` too (Phase 2 Notes).

#### Bridge and panel (Phase 3)

State, in `BridgeController`:

- `trafficSeen: Bool` (private): today's flag, renamed. Set by
  `noteResponse(id:)` for a foreign id, cleared by `start()`, `stop()` and a
  recheck.
- `@Published public private(set) var contenders: [HIDClient]`: the last
  scan's list, for the label.
- `@Published public private(set) var contendingClient: Bool` stays the one
  flag the panel shows. It is recomputed in one private `updateContention()`
  from `trafficSeen` and the last scan:

| last scan | others | `contendingClient` | effect on `trafficSeen` |
|---|---|---|---|
| `.unavailable` | — | `trafficSeen` | none (Phase 1 behaviour) |
| `.authoritative` | empty | false | cleared: whoever sent it is gone |
| `.authoritative` | some | true | none |
| `.advisory` | empty | false | cleared |
| `.advisory` | some | `trafficSeen` | none: the list labels, it cannot raise |

Scans run:

- when the panel opens: the existing `.onAppear` and own-window
  `didBecomeKeyNotification` hooks in `MenuPanelView`, which already call
  `reloadRemotes()`, also call a new `bridge.scanContention()` (scan only,
  no repaint);
- from **Recheck**: `recheckContention()` clears `trafficSeen`, scans, then
  repaints as in Phase 1;
- after a foreign reply, to put a name on it: at most one scan per second,
  so a chatty client cannot turn every reply into a registry walk;
- after the device (re)opens in `openDevice()`.

There is no timer: the warning is only visible in the panel, and the panel
scans whenever it opens. The menu-bar icon does not show contention, and this
plan does not change that.

Testing seam: `var scanClients: @MainActor () -> HIDClientScan`, defaulting
to a closure that scans the bridge's current device (read the device at call
time; `useEmulator` replaces it), like `listAgents`.

Panel copy:

- authoritative, or advisory with traffic seen and names known: "Also driving
  this pad: Input, Inspector — colours may fight."
- names unknown: today's text.
- **Recheck** stays in every case.

---

## Part 2 — Phased ToDo

### Phase 1 — Manual recheck (option A)

Branch `feat/contention-1-recheck` · PR title `feat: recheck the "another app" warning`

- [x] `BridgeController.noteResponse(id:)` (internal) holds the reply-id
      check; the `onResponse` closure in `wire(_:)` calls it.
- [x] `BridgeController.recheckContention()` clears `contendingClient` and,
      when running, `forceRepaint()`s. `issuedIDs` is left alone, with a
      comment saying why.
- [x] `stop()` clears `contendingClient`.
- [x] Panel: **Recheck** button in the warning row, laid out like **Retry**,
      with the help text from Part 1.
- [x] Tests (`BridgeContentionTests`, on the emulator):
  - [x] a foreign id sets the flag; replies to the bridge's own calls never
        do (start, repaint, check);
  - [x] `recheckContention()` clears it, and a foreign id afterwards sets it
        again;
  - [x] `stop()` clears it;
  - [x] a recheck while one of our calls is in flight does not re-raise
        it (put the id in flight with `noteIssued(id:)`, recheck, then land
        its reply and check the flag).
- [x] Each test mutation-checked (for example: clear `issuedIDs` in the
      recheck and watch the last test fail).
- [x] `README.md` "Only one bridge at a time": the warning stays until the
      other app has quit and **Recheck** is pressed (or the bridge is
      switched off and on); the Inspector counts as another app.
- [x] `CLAUDE.md` "Only one HID client at a time" bullet mentions
      `recheckContention()` and that `issuedIDs` must survive it.
- [ ] User checks listed in the PR: open the Inspector from the panel, see
      the warning, quit the Inspector, press **Recheck**, warning gone and
      pad repainted; switch off with the warning up, warning gone.
- [x] `swift build -c release` (zero warnings) and
      `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- `stop()` clears `contendingClient` *after* the device teardown, and only if
  no `start()` came in meanwhile: the lights-off calls wait on replies, and
  another client's reply landing among them would otherwise leave the
  warning up on an off bridge.
- A recheck while off only clears the flag; there is nothing to repaint.
- The in-flight test puts an id in flight through the internal
  `noteIssued(id:)` seam (which `onTX` now calls, mirroring
  `noteResponse(id:)`), rechecks, then lands that id's reply. An earlier
  version raced a repaint against a recheck behind 0–6 yields; it caught
  the mutation only about half the time (found in review), so it was
  replaced.
- Mutation checks, each restored afterwards: recheck clears `issuedIDs` →
  the in-flight test fails (5 runs, every one failed); recheck leaves the
  flag set → the recheck and stop tests fail; recheck skips the repaint →
  the recheck test fails ("the recheck repainted the key"); `stop()` keeps
  the flag → the stop test fails; every reply counts as foreign → the
  own-replies, recheck and in-flight tests fail; no reply ever counts →
  every test that raises the flag fails.
- No hardware or UI check was done in-session; the panel button and the
  Inspector round trip are user checks in the PR.

### Phase 2 — Registry scan in WLKit (option C, part 1)

Branch `feat/contention-2-registry-scan` · PR title `feat: list the other processes holding the pad open`

- [x] `HIDClient`, `HIDClientScan` and `WLDevice.otherClients()` as in
      Part 1; the emulator and a closed device return `.unavailable`.
- [x] Pure `parseCreator(_:)`, with tests: a normal value, a cut name
      (`"pid 24023, Discord Helper ("`), a name with commas, no comma,
      a non-numeric pid, an empty string.
- [x] Own pid dropped and pids de-duplicated, tested through a pure helper
      that takes parsed entries plus the own pid.
- [x] Every `io_object_t` from the iterator released (review it; `leaks` on
      a loop of 1,000 scans in a live test if a pad is present).
- [x] `LiveDeviceClientsTests`: with a pad, `otherClients()` is not
      `.unavailable` and never lists this test process. It prints the scan.
      Skips without a pad, like `LiveDeviceTests`.
- [x] **verify** (pad on USB): run the live test while the installed
      MicroManager.app runs. The test process holds the pad as well, so the
      app must appear in the scan as an `.authoritative` client by name.
      Record the output.
- [ ] **verify** (user check if not possible in-session): the Inspector,
      Work Louder's Input app and the Codex desktop app each appear while
      open, and disappear once quit.
- [ ] **verify** (user check if no Bluetooth pad in-session): over
      Bluetooth the scan is `.advisory`; record which clients appear with no
      other app driving the pad (keyboard listeners such as Discord).
- [x] Scan duration measured (Notes). If it is over ~5 ms, say so: Phase 3
      runs it on the main actor.
- [x] **Gate:** Notes state whether Phase 3 goes ahead as designed. If any
      verify above fails (a contender does not appear, the property is
      missing, Bluetooth lists unrelated clients even in `.authoritative`
      cases), write the adjusted Phase 3 design into this file's Part 1
      first, or record that C is dropped and Phase 1 is the final state.
- [x] `docs/hacking.md` "You are not the only client": add the IORegistry
      check (`ioreg -r -n "Creator Micro 2" -l -w0`, `IOUserClientCreator`
      on the vendor interface) as the active way to see who else holds the
      pad.
- [x] `swift build -c release` (zero warnings) and
      `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- The scan lives in `WLDevice+Clients.swift` as the internal static
  `WLDevice.scanClients(of:vendorInterface:)`; `otherClients()` sits in
  `WLDevice.swift` because the opened `IOHIDDevice` is private there. The
  pure helpers are `WLDevice.parseCreator(_:)` and
  `WLDevice.others(among:ownPID:)` (keeps the first entry per pid, in
  registry order). `HIDClient` has a public init, for Phase 3's
  `scanClients` seam.
- `otherClients()` checks only for an open `IOHIDDevice`: the emulator never
  opens one, so it is `.unavailable` without a check of its own.
- `parseCreator` takes everything after the *first* comma as the name and
  leaves the pid to `pid_t(_:)` plus `pid > 0`; the name is trimmed of
  surrounding spaces.
- Leak check: `leaks` was not used. A leaked `io_object_t` is a Mach send
  right, not a heap block, so `leaks` cannot see it. The live test instead
  sums this task's send-right user references around 1,000 scans and allows
  growth under 100. Measured: 59 → 59.
- **verify (USB), 2026-10-10**, pad on USB, installed app running with the
  bridge on, Work Louder's Input app open:
  `transport: USB, usage page: 65280` and
  `authoritative([HIDClient(pid: 24802, name: "input"), HIDClient(pid: 30335, name: "Micro Manager")])`.
  The app is listed by its `NSRunningApplication` name ("Micro Manager";
  the registry says "MicroManager"); the test process is not listed. The
  Input app appeared while open; its disappearing on quit, and the
  Inspector and Codex, are left as user checks (the Input app was the
  user's own, and was not quit in-session).
- Bluetooth was not checked in-session (the pad was on USB): user check.
- Scan duration: about 0.5 ms for the first scan in a fresh test process
  (three runs: 0.49–0.52 ms), 0.077 ms on average over 1,000 warm scans. Fine
  on the main actor.
- Mutation checks, each restored afterwards: child not released → the leak
  test fails (+4,000 references); iterator not released → it fails
  (+1,000); own pid kept → the pure test and the live test ("this process
  listed itself") fail; no de-duplication → the pure test fails; name split
  at the last comma → the commas test fails; negative pid accepted → the
  reject test fails; no `pid ` prefix check → the reject test fails (only
  after its "another prefix" case was changed to the same length as
  `pid `, `"uid 501, …"`; the first version was not caught); authoritative
  and advisory swapped → the live test fails; a closed device returns
  `.authoritative([])` → the emulator/closed test fails.
- Review follow-up (PR #19): a scan that does not see this process's own
  client is `.unavailable`, not an empty list. This process has just opened
  the device, so a missing own entry means the walk did not understand the
  registry: `IOUserClientCreator` gone or reformatted in a future macOS, the
  clients hanging elsewhere (Bluetooth, unverified), or a stale service after
  removal. `others(among:ownPID:)` returns nil then, and `scanClients` maps
  it to `.unavailable`. **Phase 3's table relies on this:** an empty list
  clears `trafficSeen`, and Phase 3 scans after every foreign reply, so a
  broken scan returning `[]` would clear the warning as soon as it is raised.
  `.authoritative([])` / `.advisory([])` are only returned when this
  process's own client was seen. Mutation check: own-pid presence check
  dropped → `testNoOwnPidIsNil` fails.
- **Gate: Phase 3 goes ahead as designed.** On USB the property is present,
  the contenders (the app, the Input app) appear on the vendor interface by
  name, and the keyboard interface's listeners (Discord) do not. Bluetooth is
  unverified, but the table in Part 1 already keeps `.advisory` from raising
  the warning: if keyboard listeners always show up there, an advisory scan
  only ever labels, and Bluetooth stays at Phase 1 behaviour. If the
  Bluetooth user check shows otherwise, record it here before Phase 3.

### Phase 3 — Bridge and panel (option C, part 2)

Branch `feat/contention-3-active-check` · PR title `feat: clear the "another app" warning once the other app is gone`

- [x] Phase 2's gate in Notes says go (or Part 1 was adjusted first).
- [x] `trafficSeen`, `contenders`, `updateContention()` and the table in
      Part 1; `contendingClient` stays the flag the panel reads.
- [x] `scanClients` seam; `scanContention()` (scan only) and
      `recheckContention()` (clear traffic, scan, repaint).
- [x] Scans on panel open (both existing hooks), on **Recheck**, after a
      foreign reply (at most once a second) and after `openDevice()`
      succeeds.
- [x] Panel copy with names, as in Part 1; **Recheck** kept.
- [x] Tests (`BridgeContentionTests`, with the `scanClients` seam): every row
      of the table; the one-per-second limit on reply-triggered scans; a
      recheck that finds an authoritative empty list clears traffic seen
      earlier; `.unavailable` behaves exactly as Phase 1.
- [x] Each test mutation-checked.
- [x] `README.md` "Only one bridge at a time": the panel names the other
      app, and the warning clears by itself when the panel next opens after
      that app has quit (USB). Explain the Bluetooth caveat if Phase 2 found
      one.
- [x] `CLAUDE.md`: the "Only one HID client at a time" bullet describes
      both signals (reply ids, registry scan) and the table's rule.
- [ ] User checks listed in the PR: Inspector open → named warning; quit it,
      reopen the panel → warning gone without pressing anything; same with
      Input or Codex if installed.
- [x] `swift build -c release` (zero warnings) and
      `env -u HERDR_SOCKET_PATH swift test` green.

Notes:

- The table's "effect on `trafficSeen`" column is applied only when a scan
  runs (`applyScan()`), not on every recompute. `updateContention()` is then
  `trafficSeen || (authoritative && !others.isEmpty)` for the flag, which
  gives every row of the table at scan time and keeps a reply that lands
  *after* an empty scan raising the warning. Clearing on every recompute
  would let a stale `.authoritative([])` swallow each later foreign reply
  that falls inside the reply-scan window.
- The one-per-second limit counts reply-triggered scans only, on a
  monotonic clock (`ProcessInfo.systemUptime`, behind the `uptime` seam).
  Panel, Recheck and open scans neither count towards it nor are held by
  it. A reply inside the window still raises the warning (it sets
  `trafficSeen`); it just keeps the names from the last scan. There is no
  trailing scan at the end of the window: a chatty client is named by the
  first scan anyway, and the panel rescans whenever it opens.
- Scans only reach the registry while running with the device connected;
  otherwise they are `.unavailable` without calling `scanClients`, so an off
  bridge never shows the warning (Phase 1's rule). `start()` and `stop()`
  reset both signals and the reply-scan clock.
- Beyond the plan: an unplug (`device.onDisconnect`) drops the last scan to
  `.unavailable`, since who held a pad that has gone says nothing; the
  reopen scans afresh. Tested by unplugging the virtual pad, which needed
  `device` to become `private(set)` (internal read) instead of `private`.
- `scanClients` is a `lazy var` so its default can capture `self` weakly
  and read `device` at call time.
- **Recheck**'s help text now reads "Check again for other apps and repaint
  the pad. The warning comes back if the other app is still there." —
  Phase 1's text ("It comes back if the other app sends to the pad again")
  no longer described what it does.
- Mutation checks, each restored afterwards (the failing tests in
  brackets): an empty scan keeps `trafficSeen` (authoritative-empty,
  advisory-empty); authoritative others ignored (authoritative-others,
  open, recheck, off); advisory others raise (advisory-others); no reply
  scan limit (limit); replies never scan (names-the-sender, limit); an off
  bridge scans (off); `openDevice()` does not scan (open, advisory-others,
  off, limit); Recheck does not scan (recheck); `stop()` keeps the last scan
  (off); an unavailable scan clears `trafficSeen` (unavailable, emulator
  and the Phase 1 tests); panel scans count towards the limit (limit);
  `.unavailable` keeps the old names (off); an unplug keeps the scan
  (unplug).
- No hardware or UI check was done in-session; the named warning and the
  clear-on-reopen round trip are user checks in the PR. Bluetooth remains
  unverified (Phase 2 Notes).

### Done

- [ ] All PRs merged (or Phase 3 dropped at the gate, with the reason in
      Phase 2's Notes); set this file's status to "implemented (PRs #…)".

---

## Found during implementation

(Problems discovered while working through the phases go here, not into the
current PR.)
