# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app (Swift, SwiftPM, macOS 13+) that lights each running [Herdr](https://herdr.dev) agent on its own key of a Work Louder Creator Micro 2 pad, and focuses that agent when the key is pressed. It talks to Herdr's socket directly and drives the pad over raw HID (IOKit) — no Node, no daemon. `README.md` covers user-facing behaviour and config; `docs/hacking.md` is the device protocol guide (wire format, keymap prerequisite, traps) — read it before touching `WLDevice`/`OAIProtocol`/`KeymapManager`.

## Commands

```bash
swift build -c release              # build everything
swift test                          # full suite (what CI runs)
swift test --filter StatusMapperTests               # one test class
swift test --filter KeyBindingsTests/testSomething  # one test method
swift run WLInspector               # debug UI (needs hardware; run from a terminal that has Input Monitoring)
WL_EMULATE=1 swift run WLMicroManager   # run the app against the built-in virtual pad, no hardware
./scripts/bundle.sh                 # build + sign MicroManager.app into build/
./scripts/bundle.sh --install       # ...and install to /Applications and launch
```

`Live*Tests` (device, Herdr, GitButler) call `XCTSkip` when the pad / Herdr socket / `but` binary is absent, so `swift test` is meaningful on a runner with no hardware. Fixtures in `Tests/WLKitTests/Fixtures` are read via `#filePath`, not as bundle resources.

## Architecture

Three SwiftPM targets (`Package.swift`):

- **`WLKit`** (library) — everything that isn't UI:
  - `WLDevice` / `WLDevice+Async` — IOKit HID transport; `OAIProtocol` — the vendor JSON-RPC (`v.oai.*`) message shapes.
  - `KeymapManager` / `KeyBindings` — the pad boots on a stock F-key keymap; keys must be rebound to `KV_OAI_AG*` before per-key lighting or press events work. An unbound key accepts a colour silently and stays dark.
  - `HerdrClient` — Herdr socket client (`agent.list`, lifecycle and per-pane status streams).
  - `StatusMapper` — Herdr agent state → key colour/effect.
  - `BridgeController` — the `@MainActor` engine tying it together. `agent.list` is the source of truth; the lifecycle stream, per-pane status streams, and a slow poll only decide *when* to re-read it.
  - `GitButler` (stack / land plan via the `but` CLI), `AnsiHTML`, `PadEmulator` (in-process fake firmware).
- **`WLMicroManager`** (executable) — the menu-bar app: SwiftUI panel plus the floating panels (stack, land, tune, emulator), `TuneController` (dial = reasoning effort, joystick = model), `VoiceController` (wide key taps right command for Superwhisper).
- **`WLInspector`** (executable) — debug UI with traffic log and raw JSON-RPC console. Ships nested inside the app at `Contents/Library/Inspector.app`; it's a separate process, so it can't use the emulator.

## Things that are easy to get wrong

- **Firmware lies**: it answers `{"ok":1}` to any payload, malformed or not. The LEDs are the only ground truth. `PadEmulator` reproduces this on purpose (and the stock keymap, and silent unbound keys) — keep it faithful when changing it.
- **Only one HID client at a time**: Work Louder's Input app and the Codex desktop app fight over the same lighting. A reply with a response id we never issued is how `contendingClient` is detected.
- **Signing matters**: Input Monitoring is granted per code signature, so ad-hoc builds need re-granting every rebuild. `bundle.sh` prefers a real Apple Development / Developer ID identity (`WL_SIGN_IDENTITY` overrides). `swift run` works only because it inherits the terminal's grant.
- **`but` is found by search, not `PATH`** (launchd apps get a minimal PATH); `WL_BUT_PATH` overrides. Other env overrides: `WL_TERMINAL_BUNDLE_ID`, `HERDR_SOCKET_PATH`, `WL_EMULATE`.
- Turning the manager "off" clears lights but deliberately leaves the device keymap alone (rebinding is a flash write).
- User config lives at `~/.config/micromanager/config.json`.

## CI / release

`.github/workflows/ci.yml` builds, tests, and bundles on macos-14. `release.yml` republishes the `latest` release on every push to `main` (and cuts versioned releases on `v*` tags), signing/notarizing only if the repo has the secrets and falling back to ad-hoc otherwise. `docs/` is the GitHub Pages site.
