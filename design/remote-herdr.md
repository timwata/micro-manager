# Design: syncing the pad with a remote Herdr

Status: approved plan, not yet implemented. Written for the implementing
session; read `CLAUDE.md` first, then work through
[`remote-herdr-todo.md`](remote-herdr-todo.md).

## Goal

Let the user switch, from the menu-bar panel, which single Herdr server the pad
mirrors: **this Mac** or **one of several remote hosts** reached over SSH.

The user has verified by hand that the current code already works against a
remote Herdr when given a forwarded socket:

```sh
ssh -N -L /tmp/herdr-remote.sock:/path/to/remote/herdr.sock workbox
HERDR_SOCKET_PATH=/tmp/herdr-remote.sock /Applications/MicroManager.app/Contents/MacOS/MicroManager
```

This feature automates exactly that, and makes it switchable at runtime.

### Non-goals (decided)

- Mixing local and remote agents on the pad at once. One target at a time.
- Stack / Land keys on a remote target. They are **disabled** in remote mode
  (see §5.5, §6.1). Running `but` remotely is future work (§10).
- An in-app host editor or `~/.ssh/config` discovery. Hosts live in
  `config.json`.
- Changing the Inspector (it never talks to Herdr).

## 1. Current state (what the design relies on)

- Every Herdr call resolves its socket through `HerdrClient.socketPath()`
  (`Sources/WLKit/HerdrClient.swift:124`): `HERDR_SOCKET_PATH`, else
  `$XDG_CONFIG_HOME|~/.config` + `herdr/herdr.sock`. Used by `request`
  (`:140`) and `HerdrEventStream.init` (`:283`).
- Protocol is one request per connection; each subscription owns a long-lived
  connection. Over an SSH `-L` forward each of those is just another channel —
  no protocol change needed.
- Static callers: `BridgeController` (list/focus/sendText/cycleTabs, lifecycle
  and per-pane status streams), `TuneController` (sendKeys/sendText/
  focusedAgent), `StackPanel` and `LandPanel` (focusedAgent → `GitButler` in
  `agent.workingDirectory`).
- `BridgeController.stop()` tears down Herdr streams **and** the device
  (lights off + HID disconnect). `start()` reopens the device and re-checks the
  keymap.
- Config file: `~/.config/micromanager/config.json`, parsed by
  `KeyBindings.parse` (`Sources/WLKit/KeyBindings.swift:78`), reloaded on every
  bridge start. Persisted app state lives in `BridgeSettings` (UserDefaults,
  `Sources/WLMicroManager/MicroManagerApp.swift:82`).

Feature behaviour on a remote target:

| feature | remote | why |
|---|---|---|
| agent lights, agent-key focus, tab cycle, macros, dial/joystick, voice | works | socket API, or purely local input |
| `raiseTerminal` | works | raises the local terminal running the ssh session |
| Stack (key 6), Land (key 8) | **broken** | runs local `but` in a *remote* path |

## 2. Configuration

New top-level `remotes` array in the existing `config.json`:

```json
{
  "remotes": [
    { "name": "workbox", "host": "workbox" },
    { "name": "gpu", "host": "me@gpu-box", "socket": "/run/user/1000/herdr.sock" }
  ]
}
```

- `name` (required, unique, non-empty): label in the picker and the persisted
  selection key. Duplicate names: keep the first.
- `host` (required): anything `ssh` accepts as a destination; `~/.ssh/config`
  aliases, `ProxyJump`, identities etc. are honoured because we invoke the
  system `ssh`.
- `socket` (optional): remote socket path. Default
  `~/.config/herdr/herdr.sock`. A leading `~/` is expanded remotely (§4.3).
- Entries missing `name`/`host` are skipped; a malformed file yields `[]`
  (same tolerance as `KeyBindings`).

### Types (WLKit, new file `Sources/WLKit/HerdrTarget.swift`)

```swift
public struct HerdrRemote: Equatable, Sendable, Identifiable {
    public var name: String
    public var host: String
    public var socket: String?            // nil = default
    public var id: String { name }
    public static let defaultSocket = "~/.config/herdr/herdr.sock"
}

public enum HerdrTarget: Equatable, Sendable {
    case local
    case remote(HerdrRemote)
}

public enum HerdrRemotes {
    public static func load() -> [HerdrRemote]           // reads KeyBindings.configPath()
    static func parse(_ data: Data) -> [HerdrRemote]      // internal, unit-tested
}
```

Keep `KeyBindings` untouched; `HerdrRemotes` reads the same file independently.

### Persisted selection (`BridgeSettings`)

Add `static var targetName: String?` (UserDefaults key `herdrTarget`; nil =
local). On launch, resolve it against `HerdrRemotes.load()`; a name that no
longer exists falls back to `.local`.

## 3. Socket path resolution (`HerdrClient`)

Keep the static API (all call sites stay as they are). Add a process-wide,
lock-protected override:

```swift
public static func setSocketPath(_ path: String?)   // nil = local default
public static func socketPath() -> String
public static var environmentOverride: String?      // HERDR_SOCKET_PATH if non-empty
```

Precedence in `socketPath()`:

1. `HERDR_SOCKET_PATH` (developer override; when set, the picker is disabled —
   §7).
2. Path set via `setSocketPath` (the tunnel's local socket).
3. Existing XDG default.

Implement the storage like the existing `Counter` (`final class … :
@unchecked Sendable` with an `NSLock`). Rationale for a global instead of an
injected client instance: only one target exists at a time, and it avoids
threading a client through `TuneController`/panels. Requests already in flight
during a switch keep their old connection; each request captures the override's
generation (bumped on every actual change) and turns any reply that arrives
after a switch into `HerdrError.targetChanged`, so the old target's agents are
never applied to the new one. Event streams resolve the path in `start()`, not
`init`. A blank path (`setSocketPath`, the env var, the override) counts as
unset.

## 4. SSH tunnel (WLKit, new file `Sources/WLKit/SSHTunnel.swift`)

### 4.1 Command

Launch `/usr/bin/ssh` by absolute path (launchd apps have a minimal `PATH`):

```
/usr/bin/ssh -T
  -o BatchMode=yes
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3
  -o StreamLocalBindUnlink=yes
  -o ControlMaster=no -o ControlPath=none
  -L <localSocket>:<remoteSocket>
  -- <host>
  cat >/dev/null
```

Why each option matters:

- `BatchMode=yes` — no TTY exists; a password/host-key prompt would hang
  forever. Fail fast and show the error instead. Auth must be key/agent based
  (macOS GUI apps inherit launchd's `SSH_AUTH_SOCK`; Keychain/1Password agents
  configured in `~/.ssh/config` also work).
- `ExitOnForwardFailure=yes` — a failed bind/forward kills ssh instead of
  leaving a useless connection.
- `StreamLocalBindUnlink=yes` — removes a stale local socket file from a
  previous run before binding.
- `--` before the host — `parse()` already drops hosts starting with `-`,
  but the argument list must not depend on that: ssh would read such a host
  as an option (`-oProxyCommand=…`).
- `ControlMaster=no`, `ControlPath=none` — if the user's config multiplexes,
  the forward would be registered on the master and the process lifetime
  would no longer equal the tunnel lifetime. Own a dedicated connection.
- Remote command `cat >/dev/null` instead of `-N`, with ssh's stdin set to a
  `Pipe` we hold open: if the app dies (even a crash), the pipe closes, `cat`
  sees EOF, the session ends and ssh exits. No orphaned ssh processes. Works in
  sh/bash/zsh/fish.

Build the argument list in a pure static function so it is unit-testable:

```swift
static func arguments(host: String, localSocket: String, remoteSocket: String) -> [String]
```

### 4.2 Local socket path

`$TMPDIR` + `mm-<sanitized name>.sock` (sanitize to `[A-Za-z0-9._-]`, truncate
the name to keep the full path under 100 bytes). `sockaddr_un.sun_path` is
104 bytes on macOS and `SocketConnection.open` already rejects longer paths
(`HerdrClient.swift:358`). Pure function, unit-tested.

### 4.3 Remote `~` expansion

sshd does **not** expand `~` in a streamlocal forward path (verify during
implementation; if it does, skip this step). When the remote socket starts
with `~/`, first run, with the same `BatchMode/ControlMaster` options:

```
/usr/bin/ssh -T -o BatchMode=yes -o ControlMaster=no -o ControlPath=none <host> printenv HOME
```

(`printenv` is a binary, so the remote login shell does not matter.) Replace
`~` with the trimmed output; cache per host for the app's lifetime. Failure
here is a connection failure with ssh's stderr as the message. 10 s timeout.

### 4.4 Lifecycle and state

```swift
@MainActor
public final class SSHTunnel {
    public enum State: Equatable { case idle, connecting, connected, failed(String) }
    public private(set) var state: State
    public var onStateChange: ((State) -> Void)?
    public let localSocket: String

    public init(remote: HerdrRemote)
    public func start()     // idempotent
    public func stop()      // terminate process, close stdin pipe, cancel retries, unlink local socket
}
```

- `start()`: state `.connecting` → resolve remote path (§4.3) → launch ssh →
  readiness check: poll every 200 ms (max 10 s) for a successful `connect()`
  on the local socket (a bare connect/close; Herdr tolerates a connection that
  sends nothing — verify, else use a cheap `agent.list` request). Success →
  `.connected`.
- Capture stderr into a pipe; keep the last non-empty line for error
  messages.
- Process exits (before or after ready) while not stopped → `.failed(lastLine
  ?? "ssh exited with status N")`, then auto-retry with backoff 3 s, 6 s, 12 s,
  capped at 30 s; reset backoff after a successful `.connected`. Each retry
  goes back through `.connecting`.
- Friendlier messages for common stderr (keep the raw line too):
  `Host key verification failed` → "Run `ssh <host>` once in a terminal to
  trust the host key."; `Permission denied` → "SSH key auth failed (no password
  prompts from a menu-bar app)."
- `stop()` must be safe to call from `applicationWillTerminate` and on target
  switch.

## 5. BridgeController changes

### 5.1 New published state and API

```swift
@Published public private(set) var target: HerdrTarget = .local
@Published public private(set) var link: LinkState = .local
public enum LinkState: Equatable { case local, connecting, connected, failed(String) }

public func setTarget(_ target: HerdrTarget) async
public var isRemote: Bool { if case .remote = target { return true } else { return false } }
```

### 5.2 Split teardown

Refactor `stop()` into:

- `teardownHerdr()` — cancel `pollTask`, `debounceTask`; stop `lifecycle`
  and all `statusStreams`; stop the tunnel; `agents = []`;
  `lastFingerprint = nil`.
- device teardown — the rest of today's `stop()` (lights off, disconnect,
  clear published key state).

`stop()` = `teardownHerdr()` + device teardown (behaviour unchanged).

Likewise split `start()`: device open stays as is; a new `startHerdr()` does
"bring up the target (tunnel if remote) → `HerdrClient.setSocketPath` →
`startLifecycleStream()` → `refresh()` → start `pollTask`".

### 5.3 `setTarget`

```
guard target != self.target
self.target = target
if !isRunning { return }            // applied on next start()
await teardownHerdr()
await forceRepaint-with-no-agents   // clear stale agent lights; device stays open
await startHerdr()
```

The device is **not** reopened — no keymap re-read, no flicker.

### 5.4 Remote bring-up inside `startHerdr()`

- `.local`: `HerdrClient.setSocketPath(nil)`, `link = .local`, proceed.
- `.remote(r)`: create `SSHTunnel(remote: r)`, `HerdrClient.setSocketPath(
  tunnel.localSocket)`, `link = .connecting`, start the tunnel. Start the
  lifecycle stream and poll regardless — they already retry (lifecycle every
  2 s, poll every `pollInterval`) and will succeed once the socket is up.
  On `onStateChange`: mirror into `link`; on `.connected` call
  `forceRepaint()` immediately rather than waiting for the next tick.
- While `link` is `.connecting`/`.failed`, `refresh()` must not overwrite
  `lastError` with the raw "Cannot reach the Herdr server at /var/folders/…"
  message; the link state is what the UI shows. When the tunnel drops after
  having been connected, clear `agents` and repaint so the pad doesn't show
  stale colours as live (local mode keeps today's behaviour).

### 5.5 Remote-mode key gating (Stack / Land)

- In `refresh()`, when `isRemote`, replace `stackThread`/`landThread` with
  `OAI.Thread(id:, brightness: 0, effect: .off)` (dark = unavailable).
- In `handleKeyPress`, when `isRemote`, presses on `Pad.stackKeyID` /
  `Pad.landKeyID` do nothing except `noteError("Stack and Land are not
  available for a remote Herdr.")`.
- Keep the `onKeyIntercept` order as is (a land confirmation can't be open in
  remote mode, see §6.4).

## 6. App layer (WLMicroManager)

### 6.1 Panel (`MenuPanelView`)

Insert a target section right under the header (visible whether on or off):

```
Herdr  [ This Mac ▾ ]          ← Picker: This Mac, then each remote by name
       ● Connected via SSH     ← only for remote: Connecting… / Connected / failed message (red, wraps)
```

- Reload `HerdrRemotes.load()` each time the panel appears (`.onAppear`) so
  config edits show up without a relaunch.
- Selecting an item: persist `BridgeSettings.targetName`, then
  `Task { await bridge.setTarget(…) }`.
- If `HerdrClient.environmentOverride != nil`: show the picker disabled with
  caption "Overridden by HERDR_SOCKET_PATH" and never call `setTarget`.
- With no remotes configured, still show the row (This Mac only) plus a hint
  "Add hosts under \"remotes\" in config.json".
- `keyView`: when `bridge.isRemote`, disable the stack/land buttons and set
  their help text to "Not available for a remote Herdr".
- Header subtitle: append " · via <name>" when remote and connected.

### 6.2 Footer

Add an "Edit Config…" button: create `config.json` with `{}` (and the parent
dir) if missing, then `NSWorkspace.shared.open` it.

### 6.3 Launch (`MicroManagerApp`)

In the `.task`, after `useEmulator` and **before** `start()`:

```swift
await bridge.setTarget(BridgeSettings.resolvedTarget())   // .local if env override or unknown name
```

### 6.4 Target switch side effects

On target change (observe `bridge.target`), close `StackPanelController` and
`LandPanelController` if open — their content belongs to the previous target,
and a pending land confirmation must not survive a switch.

### 6.5 Quit

`AppDelegate.applicationWillTerminate`: stop the tunnel (the bridge exposes a
synchronous `shutdownTunnel()`). The stdin-EOF trick (§4.1) covers crashes.

### 6.6 Menu-bar icon (`MenuBarIcon`)

- Running + remote + `link == .failed` or `.connecting` → treat like
  `.deviceMissing` (grey dot) so "not actually mirroring" is visible.
- Help text appends " (via <name>)" when remote.

## 7. Edge cases

- Switching while off: only `target` changes; applied on next `start()`.
- Switching to the same target: no-op.
- Emulator mode is orthogonal; works with any target.
- Rapid switching: `setTarget` runs on the main actor; guard with a
  generation counter so a stale tunnel callback from a previous target is
  ignored.
- Tunnel failing forever: retries continue at 30 s; the panel shows the last
  error; switching back to "This Mac" stops it.
- `raiseTerminal` unchanged (it raises the local terminal hosting ssh).
- `contendingClient`, keymap logic and lights-off-on-stop are unaffected.

## 8. Tests

Unit (no network):

- `HerdrRemotesTests`: parse valid / missing fields / duplicate names /
  malformed JSON / absent key / default socket.
- `SSHTunnelTests`: `arguments(...)` contains every option of §4.1 in order and
  ends with host + `cat >/dev/null`; local socket path is sanitized and < 104
  bytes for a long name; `~/` expansion helper.
- `HerdrClient` socket precedence: set/clear override (skip the env case if
  `HERDR_SOCKET_PATH` is set in the test environment).
- `StatusMapper`/bridge thread list: stack/land dark when remote (factor the
  thread-list building out of `refresh()` into a pure static function taking
  `isRemote` so it can be tested without a device).

Live (skipped by default, matching the other `Live*Tests`):

- `LiveRemoteHerdrTests`: `XCTSkip` unless `WL_TEST_REMOTE_HOST` is set; bring
  up `SSHTunnel`, wait for `.connected`, `listAgents()` through it, stop, and
  assert the local socket file is gone.

Manual check (needs a reachable host): switch This Mac ↔ remote ↔ remote2
from the panel with the emulator on (`WL_EMULATE=1 swift run WLMicroManager`);
kill the ssh process and confirm reconnection; quit the app and confirm no
`ssh … cat` process remains (`pgrep -fl 'cat >/dev/null'`).

## 9. Implementation order

The task checklist, phase/PR split and working rules are in
[`remote-herdr-todo.md`](remote-herdr-todo.md). Each step builds and passes
`swift test` on its own.

1. `HerdrTarget.swift` (types + `HerdrRemotes.parse/load`) and `HerdrClient`
   socket override + tests. No behaviour change.
2. `SSHTunnel.swift` + unit tests + live test.
3. `BridgeController`: split start/stop, `setTarget`, link state, remote key
   gating, pure thread-list function + tests.
4. App layer: picker, link status, Edit Config, launch wiring, panel closing on
   switch, quit hook, menu-bar icon.
5. Docs: README "Configuration" (the `remotes` block, BatchMode/key-auth
   requirement, Stack/Land disabled remotely) and a line in CLAUDE.md's
   "Things that are easy to get wrong" (tunnel is owned ssh with
   `ControlMaster=no` + stdin-EOF; `HERDR_SOCKET_PATH` disables the picker).

## 10. Future work (out of scope)

Remote Stack/Land: make `GitButler.launch` pluggable and run
`ssh <host> -- cd '<dir>' && but …` for remote targets. Open questions: finding
`but` on the remote (login-shell `PATH`), safe quoting of the cwd, colour
forcing over ssh, and the longer timeouts a remote `but land` needs.
