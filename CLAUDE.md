# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app (Swift, SwiftPM, macOS 13+) that lights each running [Herdr](https://herdr.dev) agent on its own key of a Work Louder Creator Micro 2 pad, and focuses that agent when the key is pressed. It talks to Herdr's socket directly and drives the pad over raw HID (IOKit) — no Node, no daemon. The Herdr can be this Mac's or one remote host's, reached through an app-owned SSH tunnel and switched from the menu-bar panel (one target at a time).

`README.md` covers user-facing behaviour and config; `docs/hacking.md` is the device protocol guide (wire format, keymap prerequisite, traps) — read it before touching `WLDevice`/`OAIProtocol`/`KeymapManager`. `design/remote-herdr.md` is the remote-Herdr design and `design/remote-herdr-todo.md` its phase log, including verified ssh/sshd behaviour and every deviation from the design — read both before touching `HerdrTarget`/`SSHTunnel`/the target code in `BridgeController`. New multi-PR features follow the same pattern: a design doc plus a todo checklist ticked in the same PR as the code. Fix plans from code reviews use one file with findings, rules for the implementing agent and a phased checklist: `design/review-fixes.md` (done), `design/followup-fixes.md`; `design/pad-contention.md` plans the "another app is driving this pad" recheck the same way. Before starting a phase, read its plan and follow its rules.

## Commands

```bash
swift build -c release              # build everything
swift test                          # full suite (what CI runs)
swift test --filter StatusMapperTests               # one test class
swift test --filter KeyBindingsTests/testSomething  # one test method
swift run WLInspector               # debug UI (needs hardware; run from a terminal that has Input Monitoring)
WL_EMULATE=1 swift run WLMicroManager   # run the app against the built-in virtual pad, no hardware
env -u HERDR_SOCKET_PATH WL_EMULATE=1 swift run WLMicroManager   # same, from inside a Herdr pane, with the target picker enabled
WL_TEST_REMOTE_HOST=workbox swift test --filter LiveRemoteHerdrTests   # real tunnel to a real remote Herdr
./scripts/bundle.sh                 # build + sign MicroManager.app into build/
./scripts/bundle.sh --install       # ...and install to /Applications and launch
```

`Live*Tests` (device, Herdr, GitButler, remote Herdr, bridge targets) call `XCTSkip` when the pad / Herdr socket / `but` binary / `WL_TEST_REMOTE_HOST` is absent, so `swift test` is meaningful on a runner with no hardware. Remote live tests also read `WL_TEST_SSH_PATH` (a stand-in for `/usr/bin/ssh`, e.g. a script adding `-F test_config` to reach a throwaway sshd without touching `~/.ssh`), `WL_TEST_REMOTE_SOCKET` and `WL_TEST_REMOTE_HOLD` (see `LiveRemoteHerdrTests`' doc comment). Unit tests replace ssh with a shell script via the internal `SSHTunnel(remote:sshPath:)` / `BridgeController.sshPath` seams. Fixtures in `Tests/WLKitTests/Fixtures` are read via `#filePath`, not as bundle resources.

## Architecture

Three SwiftPM targets (`Package.swift`):

- **`WLKit`** (library) — everything that isn't UI:
  - `WLDevice` / `WLDevice+Async` — IOKit HID transport; `OAIProtocol` — the vendor JSON-RPC (`v.oai.*`) message shapes.
  - `KeymapManager` / `KeyBindings` — the pad boots on a stock F-key keymap; keys must be rebound to `KV_OAI_AG*` before per-key lighting or press events work. An unbound key accepts a colour silently and stays dark.
  - `HerdrClient` — Herdr socket client (`agent.list`, lifecycle and per-pane status streams). The socket path is process-wide: `HERDR_SOCKET_PATH` > `setSocketPath(_:)` (the tunnel's local socket) > the XDG default; the precedence lives in the pure `resolveSocketPath(environment:override:)`.
  - `HerdrTarget` — `HerdrRemote` / `HerdrTarget` (`.local` or `.remote`) and `HerdrRemotes`, which parses the `remotes` array of `config.json` independently of `KeyBindings`.
  - `SSHTunnel` — the `@MainActor` owned-ssh forward of a remote Herdr socket to `$TMPDIR/mm-<name>.sock`: `idle → connecting → connected | failed`, with backoff retries for transient failures only.
  - `StatusMapper` — Herdr agent state → key colour/effect.
  - `BridgeController` — the `@MainActor` engine tying it together. `agent.list` is the source of truth; the lifecycle stream, per-pane status streams, and a slow poll only decide *when* to re-read it. It owns the target: `setTarget(_:)` swaps only the Herdr side (`teardownHerdr()` / `startHerdr()`) and keeps the device open, `link` mirrors the tunnel, `reconnect()` backs the panel's Retry, the synchronous `shutdown()` the quit hook (it darkens the pad and kills the tunnel before `applicationWillTerminate` returns). The pad's thread list is the pure `padThreads(...)`, so remote gating is testable without a device.
  - `GitButler` (stack / land plan via the `but` CLI), `AnsiHTML`, `PadEmulator` (in-process fake firmware), `SerialTaskQueue` (one-at-a-time async work; keeps the dial and joystick slash commands from interleaving).
- **`WLMicroManager`** (executable) — the menu-bar app: SwiftUI panel (incl. the Herdr target picker, link status/Retry, Edit Config…; selection persisted as `BridgeSettings.targetName`) plus the floating panels (stack, land, tune, emulator), `TuneController` (dial = reasoning effort, joystick = model), `VoiceController` (wide key taps right command for Superwhisper).
- **`WLInspector`** (executable) — debug UI with traffic log and raw JSON-RPC console. Ships nested inside the app at `Contents/Library/Inspector.app`; it's a separate process, so it can't use the emulator.

## Things that are easy to get wrong

- **Firmware lies**: it answers `{"ok":1}` to any payload, malformed or not. The LEDs are the only ground truth. `PadEmulator` reproduces this on purpose (and the stock keymap, and silent unbound keys) — keep it faithful when changing it.
- **Only one HID client at a time**: Work Louder's Input app and the Codex desktop app fight over the same lighting. A reply with a response id we never issued is how `contendingClient` is detected. Only `start()` resets it, so today it outlives the other app; see `design/pad-contention.md`. The Inspector is a separate process and counts as another client.
- **Signing matters**: Input Monitoring is granted per code signature, so ad-hoc builds need re-granting every rebuild. `bundle.sh` prefers a real Apple Development / Developer ID identity (`WL_SIGN_IDENTITY` overrides). `swift run` works only because it inherits the terminal's grant.
- **A remote Herdr is an owned ssh**: `SSHTunnel` runs its own `/usr/bin/ssh` (`ControlMaster=no`, so the process lifetime *is* the tunnel's) with a remote `cat >/dev/null` on a stdin pipe we hold, so even a crash ends it by EOF. `HERDR_SOCKET_PATH` beats any tunnel, so the panel disables the target picker when it is set — and Herdr itself sets it for processes it spawns, so a `swift run` from inside a Herdr pane gets the disabled picker (and the `LiveBridgeTargetTests` skip).
- **The socket path is global, so a switch must not leak.** `setSocketPath` bumps a generation; a reply that lands after a switch becomes `HerdrError.targetChanged`, and the bridge guards every async callback (tunnel state, lifecycle restart, status-stream `onClosed`, poll, in-flight `agent.list`) with its own generation counter plus a `herdrActive` flag. Event streams resolve the path in `start()`, not `init`. Pane ids are only unique per server — never carry agent state across targets.
- **Permanent ssh failures are never retried** (auth `Permission denied`, `Host key verification failed`, `administratively prohibited`): repeated failed logins trip fail2ban-style jails. Only the user's Retry or a target change restarts. Everything else backs off 3 s → 30 s. `BatchMode=yes` means no prompts ever; key/agent auth only.
- **ssh/sshd quirks verified in Phase 2**: sshd does not expand `~` in a streamlocal forward (hence the `printenv HOME` lookup, taking the last stdout line starting with `/` to skip login-shell banners); a bare connect to the local socket proves nothing (ssh accepts before the remote side exists), so readiness waits for an `agent.list` reply; ssh ends stderr lines with `\r\n`, one Swift `Character` — split on `isNewline`. `sun_path` is 104 bytes, so local socket names are sanitized/truncated (+ FNV hash) to ≤ 100.
- **Stack / Land are dark and inert on a remote target** — they run the local `but` in a path that lives on the other machine. The app also closes their panels on a target change (`onTargetChange`), except a land that is already running.
- **`AppDelegate` owns the bridge, its wiring and the launch bootstrap** (`useEmulator` → `setTarget` → `start()` if enabled), run from `applicationDidFinishLaunching`. Don't move them back into the `MenuBarExtra` content: SwiftUI builds it only when the panel is first opened, which left the pad dark after launch until the icon was clicked. The icon is a separate `MenuBarLabel` view because the `App` struct cannot observe the delegate's object.
- **`but` is found by search, not `PATH`** (launchd apps get a minimal PATH); `WL_BUT_PATH` overrides. Other env overrides: `WL_TERMINAL_BUNDLE_ID`, `HERDR_SOCKET_PATH`, `WL_EMULATE`, `WL_SIGN_IDENTITY`.
- Turning the manager "off", or quitting, clears lights but deliberately leaves the device keymap alone (rebinding is a flash write). Quitting does not persist "off": the next launch starts again.
- User config lives at `~/.config/micromanager/config.json` (`keys`, `claude`, `codex`, `remotes`). The panel re-reads `remotes` every time it opens; a remote edited in place under the selected name is re-applied, and a selected name that vanished stays selected until the next launch, which falls back to This Mac.

## CI / release

`.github/workflows/ci.yml` builds, tests, and bundles on macos-14. `release.yml` republishes the `latest` release on every push to `main` (and cuts versioned releases on `v*` tags), signing/notarizing only if the repo has the secrets and falling back to ad-hoc otherwise. `docs/` is the GitHub Pages site.
