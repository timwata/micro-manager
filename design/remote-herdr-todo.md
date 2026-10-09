# ToDo: remote Herdr

Implementation checklist for [`remote-herdr.md`](remote-herdr.md). Section
numbers (§) refer to that document.

## Rules for the implementing agent

- **One phase = one branch = one PR**, based on `main`. Start a phase only
  after the previous phase's PR is merged; then branch from the fresh `main`.
  (If told to proceed without waiting, stack on the previous branch and set the
  PR base to it.)
- Branch names: `feat/remote-herdr-<n>-<slug>` as listed per phase.
- **Every push to `main` republishes the `latest` release** (`release.yml`).
  Phases 1–3 must therefore not change what a user sees: the feature stays
  unreachable (target is always `.local`) until Phase 4.
- Before opening each PR: `swift build -c release` and `swift test` pass; tick
  this phase's boxes **in this file in the same PR**; note anything deferred or
  deviating from the design in the PR description and here.
- Match the surrounding code style (doc comments explain *why*, as in
  `BridgeController.swift`). Read `docs/hacking.md` only if touching device
  code — no phase should need to.
- Items marked **verify** are assumptions in the design; record the result in
  the PR description and adjust the code if the assumption is wrong.

---

## Phase 1 — Targets config and socket override

Branch `feat/remote-herdr-1-config` · PR title `feat: herdr target config and socket override`
· No user-visible change.

- [x] Add `Sources/WLKit/HerdrTarget.swift` with `HerdrRemote`, `HerdrTarget`,
      `HerdrRemotes.load()` / `parse(_:)` (§2).
  - [x] Skip entries without non-empty `name`/`host`; keep first of duplicate
        names; malformed or absent → `[]`.
  - [x] `load()` reads `KeyBindings.configPath()`.
- [x] `HerdrClient`: add lock-protected `setSocketPath(_:)`,
      `environmentOverride`, and the 3-level precedence in `socketPath()` (§3).
- [x] Tests: `Tests/WLKitTests/HerdrRemotesTests.swift` (valid, missing
      fields, duplicates, malformed, absent key, default socket).
- [x] Tests: socket path precedence (set → used; `nil` → XDG default; skip
      the env case when `HERDR_SOCKET_PATH` is set).
- [x] `swift test` green.

Notes (small additions beyond the design, no deviation in behaviour):

- `HerdrRemote` also has a memberwise `public init` and `remoteSocket`
  (`socket ?? defaultSocket`) for Phase 2 to forward to.
- "Non-empty" means not blank after trimming whitespace, and the trimmed
  value is what is kept (so `"box "` and `"box"` are duplicates); an empty
  `socket` is treated as absent (default path).
- A `host` starting with `-` is skipped: ssh would read it as an option.
- A blank `setSocketPath`, override or `HERDR_SOCKET_PATH` counts as unset,
  in both `setSocketPath` and `resolveSocketPath`.
- `setSocketPath` bumps a generation counter on every actual change;
  `HerdrClient.request` turns a reply that arrives after a switch into
  `HerdrError.targetChanged` instead of delivering the old target's data.
  Tested against a fake socket server.
- `HerdrEventStream` resolves the socket path in `start()`, not `init`.
- The precedence lives in an internal pure
  `resolveSocketPath(environment:override:)`, so the env-wins case is tested
  without touching the process environment
  (`Tests/WLKitTests/HerdrSocketPathTests.swift`). Only the two tests of the
  real process-wide setting skip under `HERDR_SOCKET_PATH`.

## Phase 2 — SSH tunnel

Branch `feat/remote-herdr-2-tunnel` · PR title `feat: ssh tunnel to a remote herdr socket`
· New class only; nothing calls it yet.

- [x] Add `Sources/WLKit/SSHTunnel.swift` (§4).
  - [x] Pure `arguments(host:localSocket:remoteSocket:)` with every option in
        §4.1, ending in `-- <host> cat >/dev/null` (the `--` keeps a host
        starting with `-` from being read as an option).
  - [x] Pure local socket path builder (`$TMPDIR/mm-<sanitized>.sock`,
        < 104 bytes) (§4.2).
  - [x] Remote `~/` expansion via `ssh … printenv HOME`, cached per host, 10 s
        timeout (§4.3). **verify** whether sshd expands `~` itself; if so,
        drop this step.
  - [x] Process launch with stdin `Pipe` held open, stderr captured (last
        non-empty line kept).
  - [x] Readiness: poll `connect()` on the local socket every 200 ms, max
        10 s. **verify** Herdr tolerates a connect-and-close with no request;
        otherwise use `agent.list`.
  - [x] State machine `idle → connecting → connected | failed(msg)`,
        `onStateChange` callback, backoff 3/6/12/…/30 s, reset after
        `connected` (§4.4).
  - [x] Friendly messages for `Host key verification failed` and
        `Permission denied` (raw line kept).
  - [x] `stop()`: cancel retries, close stdin, terminate, unlink local socket;
        idempotent.
- [x] Tests: `SSHTunnelTests` (argument list, path sanitizing/length, `~`
      helper, message mapping).
- [x] Live test `LiveRemoteHerdrTests`: `XCTSkip` unless
      `WL_TEST_REMOTE_HOST`; connect, `listAgents()` through the tunnel, stop,
      assert local socket removed.
- [x] Manual: run the live test against a real host once; confirm that after
      killing the test process no `ssh … cat >/dev/null` remains
      (`pgrep -fl 'cat >/dev/null'`). Record result in the PR.
- [x] `swift test` green (live test skipped in CI).

Verify results (OpenSSH 10.3 client and sshd, Herdr on macOS):

- **sshd does not expand `~`** in a streamlocal forward path, and a relative
  path does not resolve against the home directory either (both fail with
  `open failed: connect failed: open failed`). The `printenv HOME` step stays.
  The ssh client does not expand `~` there either, but it does `%`-expand
  the path (`%h` → host), so a remote socket path containing `%` would be
  mangled; not handled, as no real Herdr path has one.
- **Herdr tolerates a bare connect-and-close** (no log noise, next request
  answered). Readiness still sends `agent.list` and waits for any reply,
  because a bare connect proves nothing: ssh binds the local socket before
  any remote connection exists and accepts connections even when nothing
  listens at the remote path (they are dropped right after). With a probe
  request, a missing remote socket surfaces after 10 s as "No Herdr is
  listening at … on <host>. Is Herdr running there?".
- **Manual run** against a throwaway unprivileged sshd on `127.0.0.1:2222`
  (own host key, `authorized_keys` and client config, reached through
  `WL_TEST_SSH_PATH`, so `~/.ssh` was never touched) serving the local Herdr
  socket via the default `~/.config/herdr/herdr.sock`: the live test lists
  agents through the tunnel and passes. With `WL_TEST_REMOTE_HOLD=60`,
  `kill -9` of the xctest process left no `ssh … cat >/dev/null`, no remote
  `cat` and no `sshd-session` within 2 s (only the stale local socket file,
  which the next start unlinks). Killing ssh while connected → `failed` →
  reconnected after the 3 s backoff; an unresolvable host fails at once with
  ssh's own message and keeps retrying; real ssh's `Host key verification
  failed.` and `Permission denied (publickey).` match the mapped messages.
- Foundation's `Process` does not leak the tunnel's stdin pipe into later
  children (checked with `lsof`: a second child only holds fds 0–2), so a
  `but` or a second ssh cannot keep the first tunnel alive after a crash.

Notes (additions beyond the design):

- Extra ssh options: `ConnectTimeout=10` (an unreachable host would
  otherwise outlast the readiness window by a minute), `RemoteCommand=none`
  (a `RemoteCommand` in the user's config makes ssh refuse ours) and
  `ForwardAgent=no` (nothing needs the agent remotely, and a global
  `ForwardAgent yes` would otherwise lend it to the host). The `printenv HOME` lookup shares these options and
  `--`.
- Local socket names that had to be sanitized or truncated get an FNV-1a
  hash of the original name appended (`mm-a_b-1a2b3c4d.sock`), so names that
  sanitize alike (`"a b"`, `"a/b"`) don't share a socket. A `$TMPDIR` too long
  to leave room falls back to `/tmp`. Paths stay ≤ 100 bytes.
- Friendly messages also for channel errors (`open failed: connect failed`
  → "No Herdr is listening…", matched before `Permission denied` so a socket
  permission error isn't reported as an auth failure) and for
  `administratively prohibited` (`AllowStreamLocalForwarding`). Format:
  `<hint> (ssh: <raw line>)`; unmapped lines are shown as `ssh: <raw>`.
- ssh ends stderr lines with `\r\n`, which Swift treats as one `Character`;
  lines are split on `isNewline`, never on `"\n"` (found in the manual run).
- Readiness has two deadlines (PR #4 review): a 60 s login phase (wait for
  ssh to bind the local socket, which it does only after authenticating) and
  then the 10 s `agent.list` probe phase, so a slow login cannot use up the
  probe window. Their timeouts, and an early exit with no stderr, give
  "Timed out logging in to <host>." / "Logged in to <host>, but no Herdr
  answered at <path>." / "ssh exited with status N.".
- Permanent failures are not retried (PR #4 review): auth `Permission
  denied`, `Host key verification failed` and `administratively prohibited`
  end the run in `.failed` until `start()` is called again, so a bad key
  can't trip fail2ban on the server. Everything else keeps the backoff.
- The `printenv HOME` answer is the last stdout line starting with `/`, so
  login-shell startup files that echo a banner don't break the lookup
  (PR #4 review).
- Internal seams for tests: `init(remote:sshPath:)` (a shell script stands in
  for ssh in `SSHTunnelTests`, covering the state machine, stderr capture,
  `~` expansion end to end, and that `stop()` closes the stdin pipe) and
  `retryDelay`, `loginTimeout`, `readinessTimeout`. The live test also reads `WL_TEST_SSH_PATH`,
  `WL_TEST_REMOTE_SOCKET` and `WL_TEST_REMOTE_HOLD` (see its doc comment).
- `deinit` terminates ssh as a safety net but does not unlink the socket:
  two tunnels to the same remote share the path, so an old tunnel must not
  remove the new one's socket. Phase 3 should stop the old tunnel before
  starting the new one.

## Phase 3 — Bridge target switching

Branch `feat/remote-herdr-3-bridge` · PR title `feat: switch the bridge between local and remote herdr`
· API only; the app still never sets a remote target.

- [x] Split `stop()` into `teardownHerdr()` + device teardown; split
      `start()` to call a new `startHerdr()` (§5.2). `stop()`/`start()`
      behaviour for local must be unchanged.
- [x] Add `target`, `LinkState link`, `isRemote`, `setTarget(_:)` (§5.1,
      §5.3); device stays open on switch; clear agent lights before bringing
      up the new target.
- [x] Remote bring-up in `startHerdr()`: own an `SSHTunnel`, set
      `HerdrClient.setSocketPath`, mirror tunnel state into `link`,
      `forceRepaint()` on `.connected` (§5.4).
- [x] Generation counter so callbacks from a superseded tunnel are ignored
      (§7).
- [x] `refresh()`: don't surface raw socket errors while the link is
      connecting/failed; clear agents + repaint when a connected tunnel drops
      (§5.4).
- [x] Factor the thread list out of `refresh()` into a pure static function
      taking `isRemote`; stack/land threads dark when remote (§5.5).
- [x] `handleKeyPress`: stack/land presses → `noteError(...)` only, when
      remote (§5.5).
- [x] Public synchronous `shutdownTunnel()` for the quit hook (§6.5).
- [x] Tests: thread list with `isRemote` true/false (stack/land dark vs lit,
      everything else identical).
- [x] Manual: local mode with `WL_EMULATE=1 swift run WLMicroManager` behaves
      exactly as before (on/off, agent lights, key presses). Done through the
      bridge on the virtual pad (`LiveBridgeTargetTests`), not by clicking
      the app: this phase changes no app code. See below.
- [x] `swift test` green.

Notes (additions beyond the design):

- `teardownHerdr()` is synchronous (the design wrote `await`); nothing in it
  needs to wait. It also resets `link` to `.local` (documented as "no tunnel
  in play: the target is this Mac, or the bridge is off") and calls
  `HerdrClient.setSocketPath(nil)`, so every bring-up moves the client's
  generation — even when a remote edited in place keeps its socket path.
- `refresh()` is split into fetch + `render(_ agents:)`; `setTarget` uses
  `render([])` to clear the old target's lights. While a remote link is not
  `.connected`, `refresh()` skips `agent.list` and renders no agents, which
  is how a drop clears the pad. Local mode still fetches every time and
  reports a failure as before.
- A `herdrActive` flag (besides the generation counter) keeps `refresh()`
  and the lifecycle stream off until `startHerdr()` has pointed the client at
  the target: the device opens first, and a refresh in that gap would read
  whatever socket the previous target left. `startHerdr()` is a no-op when
  already up, so an overlapping `start()` and `setTarget` bring it up once.
- The generation counter also guards the lifecycle stream's 2 s restart, the
  status streams' `onClosed` (pane ids are only unique per server), the poll
  loop and in-flight `agent.list` replies. The lifecycle guard fixes an
  existing leak too: an off/on within 2 s used to start a second stream. A
  cancelled debounce no longer clears its successor's handle.
- Thread list: `BridgeController.padThreads(...)` (internal, `nonisolated
  static`) rather than a `StatusMapper` function, since it also needs the key
  bindings and panel state. Tests: `BridgePadThreadsTests`, plus
  `BridgeTargetTests` (switch while off, remote stack/land press only
  explains, key intercept still wins).
- Internal seam `BridgeController.sshPath` (default `/usr/bin/ssh`) for live
  tests, like `SSHTunnel`'s.
- Live test `LiveBridgeTargetTests` (virtual pad, real sockets; skipped
  without Input Monitoring or with `HERDR_SOCKET_PATH` set): local on/off and
  stack key; local → unreachable remote (`.invalid` host) → local, checking
  the pad clears without reopening the device, `link` carries the error with
  no `lastError`, a stack press explains itself, and the abandoned tunnel's
  retry never comes back; and, with `WL_TEST_REMOTE_HOST`, a remote mirrored
  through a real tunnel, ssh killed → agents cleared → reconnected → back to
  local with no ssh left. All pass against the throwaway sshd from Phase 2's
  manual run (`WL_TEST_SSH_PATH`) and the local Herdr, three runs in a row.

## Phase 4 — App UI, wiring and docs

Branch `feat/remote-herdr-4-ui` · PR title `feat: pick a remote herdr from the menu bar`
· The feature ships with this PR, so docs ship with it too.

- [x] `BridgeSettings.targetName` + `resolvedTarget()` (env override or unknown
      name → `.local`) (§2, §6.3).
- [x] Launch: `setTarget(BridgeSettings.resolvedTarget())` after
      `useEmulator`, before `start()` (§6.3).
- [x] `MenuPanelView` target row: picker (This Mac + remotes), link status
      line, reload remotes `.onAppear`, disabled with caption under
      `HERDR_SOCKET_PATH`, hint when no remotes (§6.1).
- [x] `keyView`: stack/land disabled with "Not available for a remote Herdr"
      help when remote; subtitle " · via <name>" (§6.1).
- [x] Footer "Edit Config…" (create `{}` + dir if missing, then open) (§6.2).
- [x] Close Stack/Land panels when `bridge.target` changes (§6.4).
- [x] `applicationWillTerminate` → `bridge.shutdownTunnel()` (§6.5).
- [x] `MenuBarIcon`: grey dot when remote link is connecting/failed; help
      suffix " (via <name>)" (§6.6).
- [x] README "Configuration": `remotes` block, key/agent auth requirement
      (BatchMode), Stack/Land disabled remotely, `HERDR_SOCKET_PATH` disables
      the picker.
- [x] CLAUDE.md "Things that are easy to get wrong": one line on the owned ssh
      (`ControlMaster=no`, stdin-EOF lifetime) and the env override.
- [x] Manual (with `WL_EMULATE=1` and a real host): switch This Mac ↔ remote ↔
      second remote; kill the ssh process → reconnects; bad host → readable
      error; quit → no ssh left; relaunch → last target restored.
      Done by the user on their own setup after PR #6 merged.
- [x] `swift test` green; `./scripts/bundle.sh` succeeds.

Notes (additions beyond the design):

- `HerdrRemotes.target(named:in:)` (pure, tested) does the name lookup for
  `resolvedTarget()` and the picker; `HerdrTarget.remoteName` is the
  persisted form (nil = This Mac).
- §6.4 is wired through a bridge callback, `onTargetChange`, set in the
  app's `.task` like `onStackKey`/`onLandKey`, rather than by observing
  `bridge.target` from a view: the panel view need not be on screen when the
  target changes. A land that is already **running** is not closed — it
  pushes this Mac's repository whatever the pad shows, and its window is the
  only place its outcome appears (`LandPanelController.closeForTargetChange`).
- `BridgeController.reconnect()` and a **Retry** button next to a failed link.
  §7 says a permanent failure is shown "until the user changes something and
  re-selects the target", but `setTarget` ignores the same target, so without
  this the only way back after fixing a key was off/on or switching away and
  back. It restarts the tunnel only when the link is `.failed`.
- Opening the panel re-reads the config (`.onAppear`, plus
  `NSWindow.didBecomeKeyNotification` in case the menu window is kept alive
  between openings). A remote edited in place under the selected name is
  re-applied; a selected remote removed from the config stays selected (and
  listed) until the user picks another, and falls back to This Mac on the
  next launch.
- "Edit Config…" sits on the "Emulate the pad" row, still in the footer: the
  button row (Refresh, Inspector, Quit) has no room for a fourth push button
  at the panel's 300 pt width (measured ~330 pt). A Mac with no app for
  `.json` gets TextEdit.
- `MenuBarIcon.State.linkDown` (badge symbol + grey dot, like
  `.deviceMissing`), checked after the device states and before the agent
  states. The " (via <name>)" suffix goes on the image's accessibility
  description, which is where the state's help text already went.
- Herdr exports `HERDR_SOCKET_PATH` into every pane it runs, so `swift run`
  from inside Herdr gets the disabled picker; launch with
  `env -u HERDR_SOCKET_PATH` to develop against the picker.

Manual check so far: headless runs (no clicking — this session has no
accessibility access) showed that the app's `.task`, which holds all the
wiring including the launch `setTarget` and auto-start, runs only once the
menu-bar panel is first opened, on `main` too: a fresh launch opens no Herdr
socket and no ssh until then. Not changed here (pre-existing, affects local
mode equally). Fixed later by Phase 1 of `design/review-fixes.md` (H1): the
wiring and bootstrap now run from `AppDelegate` at launch.

## Done

- [x] All four PRs merged; mark the design doc status as "implemented".
