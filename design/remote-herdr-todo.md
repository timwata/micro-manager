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

- [ ] Add `Sources/WLKit/HerdrTarget.swift` with `HerdrRemote`, `HerdrTarget`,
      `HerdrRemotes.load()` / `parse(_:)` (§2).
  - [ ] Skip entries without non-empty `name`/`host`; keep first of duplicate
        names; malformed or absent → `[]`.
  - [ ] `load()` reads `KeyBindings.configPath()`.
- [ ] `HerdrClient`: add lock-protected `setSocketPath(_:)`,
      `environmentOverride`, and the 3-level precedence in `socketPath()` (§3).
- [ ] Tests: `Tests/WLKitTests/HerdrRemotesTests.swift` (valid, missing
      fields, duplicates, malformed, absent key, default socket).
- [ ] Tests: socket path precedence (set → used; `nil` → XDG default; skip
      the env case when `HERDR_SOCKET_PATH` is set).
- [ ] `swift test` green.

## Phase 2 — SSH tunnel

Branch `feat/remote-herdr-2-tunnel` · PR title `feat: ssh tunnel to a remote herdr socket`
· New class only; nothing calls it yet.

- [ ] Add `Sources/WLKit/SSHTunnel.swift` (§4).
  - [ ] Pure `arguments(host:localSocket:remoteSocket:)` with every option in
        §4.1, ending in `<host> cat >/dev/null`.
  - [ ] Pure local socket path builder (`$TMPDIR/mm-<sanitized>.sock`,
        < 104 bytes) (§4.2).
  - [ ] Remote `~/` expansion via `ssh … printenv HOME`, cached per host, 10 s
        timeout (§4.3). **verify** whether sshd expands `~` itself; if so,
        drop this step.
  - [ ] Process launch with stdin `Pipe` held open, stderr captured (last
        non-empty line kept).
  - [ ] Readiness: poll `connect()` on the local socket every 200 ms, max
        10 s. **verify** Herdr tolerates a connect-and-close with no request;
        otherwise use `agent.list`.
  - [ ] State machine `idle → connecting → connected | failed(msg)`,
        `onStateChange` callback, backoff 3/6/12/…/30 s, reset after
        `connected` (§4.4).
  - [ ] Friendly messages for `Host key verification failed` and
        `Permission denied` (raw line kept).
  - [ ] `stop()`: cancel retries, close stdin, terminate, unlink local socket;
        idempotent.
- [ ] Tests: `SSHTunnelTests` (argument list, path sanitizing/length, `~`
      helper, message mapping).
- [ ] Live test `LiveRemoteHerdrTests`: `XCTSkip` unless
      `WL_TEST_REMOTE_HOST`; connect, `listAgents()` through the tunnel, stop,
      assert local socket removed.
- [ ] Manual: run the live test against a real host once; confirm that after
      killing the test process no `ssh … cat >/dev/null` remains
      (`pgrep -fl 'cat >/dev/null'`). Record result in the PR.
- [ ] `swift test` green (live test skipped in CI).

## Phase 3 — Bridge target switching

Branch `feat/remote-herdr-3-bridge` · PR title `feat: switch the bridge between local and remote herdr`
· API only; the app still never sets a remote target.

- [ ] Split `stop()` into `teardownHerdr()` + device teardown; split
      `start()` to call a new `startHerdr()` (§5.2). `stop()`/`start()`
      behaviour for local must be unchanged.
- [ ] Add `target`, `LinkState link`, `isRemote`, `setTarget(_:)` (§5.1,
      §5.3); device stays open on switch; clear agent lights before bringing
      up the new target.
- [ ] Remote bring-up in `startHerdr()`: own an `SSHTunnel`, set
      `HerdrClient.setSocketPath`, mirror tunnel state into `link`,
      `forceRepaint()` on `.connected` (§5.4).
- [ ] Generation counter so callbacks from a superseded tunnel are ignored
      (§7).
- [ ] `refresh()`: don't surface raw socket errors while the link is
      connecting/failed; clear agents + repaint when a connected tunnel drops
      (§5.4).
- [ ] Factor the thread list out of `refresh()` into a pure static function
      taking `isRemote`; stack/land threads dark when remote (§5.5).
- [ ] `handleKeyPress`: stack/land presses → `noteError(...)` only, when
      remote (§5.5).
- [ ] Public synchronous `shutdownTunnel()` for the quit hook (§6.5).
- [ ] Tests: thread list with `isRemote` true/false (stack/land dark vs lit,
      everything else identical).
- [ ] Manual: local mode with `WL_EMULATE=1 swift run WLMicroManager` behaves
      exactly as before (on/off, agent lights, key presses).
- [ ] `swift test` green.

## Phase 4 — App UI, wiring and docs

Branch `feat/remote-herdr-4-ui` · PR title `feat: pick a remote herdr from the menu bar`
· The feature ships with this PR, so docs ship with it too.

- [ ] `BridgeSettings.targetName` + `resolvedTarget()` (env override or unknown
      name → `.local`) (§2, §6.3).
- [ ] Launch: `setTarget(BridgeSettings.resolvedTarget())` after
      `useEmulator`, before `start()` (§6.3).
- [ ] `MenuPanelView` target row: picker (This Mac + remotes), link status
      line, reload remotes `.onAppear`, disabled with caption under
      `HERDR_SOCKET_PATH`, hint when no remotes (§6.1).
- [ ] `keyView`: stack/land disabled with "Not available for a remote Herdr"
      help when remote; subtitle " · via <name>" (§6.1).
- [ ] Footer "Edit Config…" (create `{}` + dir if missing, then open) (§6.2).
- [ ] Close Stack/Land panels when `bridge.target` changes (§6.4).
- [ ] `applicationWillTerminate` → `bridge.shutdownTunnel()` (§6.5).
- [ ] `MenuBarIcon`: grey dot when remote link is connecting/failed; help
      suffix " (via <name>)" (§6.6).
- [ ] README "Configuration": `remotes` block, key/agent auth requirement
      (BatchMode), Stack/Land disabled remotely, `HERDR_SOCKET_PATH` disables
      the picker.
- [ ] CLAUDE.md "Things that are easy to get wrong": one line on the owned ssh
      (`ControlMaster=no`, stdin-EOF lifetime) and the env override.
- [ ] Manual (with `WL_EMULATE=1` and a real host): switch This Mac ↔ remote ↔
      second remote; kill the ssh process → reconnects; bad host → readable
      error; quit → no ssh left; relaunch → last target restored.
- [ ] `swift test` green; `./scripts/bundle.sh` succeeds.

## Done

- [ ] All four PRs merged; mark the design doc status as "implemented".
