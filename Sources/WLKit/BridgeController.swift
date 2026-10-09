import Foundation
import SwiftUI
import IOKit
import IOKit.hid

/// Drives the pad from Herdr agent status: each agent gets its own key, and the
/// underglow carries a worst-state-wins aggregate.
///
/// Liveness comes from three places, so a missed event can never leave the pad
/// showing something stale:
///   1. a lifecycle stream (panes appearing, disappearing, gaining agents)
///   2. one status stream per agent pane (instant transitions)
///   3. a slow poll of `agent.list` as a backstop
///
/// `agent.list` is always the source of truth; events only decide *when* to
/// look. This is a port of `bin/leds.js` — including the parts that were bug
/// fixes, which are called out where they matter.
@MainActor
public final class BridgeController: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var deviceConnected = false
    @Published public private(set) var keymapReady = false
    @Published public private(set) var permissionDenied = false
    @Published public private(set) var deviceName = "—"
    @Published public private(set) var firmware = "—"
    @Published public private(set) var battery: String?
    @Published public private(set) var agents: [HerdrAgent] = []
    @Published public private(set) var keyColors: [Int: Color] = [:]
    @Published public private(set) var keyEffects: [Int: OAI.Effect] = [:]
    @Published public private(set) var aggregateState: String?
    @Published public private(set) var lastError: String?
    /// Another process is talking to the same pad. A shared HID open means we
    /// receive its replies too, so a response id we never issued is a reliable
    /// tell.
    @Published public private(set) var contendingClient = false
    /// Whether the GitButler stack is on screen. Only the key light cares —
    /// the panel itself lives in the app layer.
    @Published public private(set) var stackPanelOpen = false
    /// Same for the land window.
    @Published public private(set) var landPanelOpen = false
    /// Whether a Claude voice take is open, for the voice key's light.
    @Published public private(set) var voiceActive = false
    /// Which Herdr server the pad mirrors. Changed only through `setTarget`.
    @Published public private(set) var target: HerdrTarget = .local
    /// How far the connection to a remote target has got. While a tunnel is
    /// down this — not `lastError` — is what explains an empty pad.
    @Published public private(set) var link: LinkState = .local

    public enum LinkState: Equatable, Sendable {
        /// No tunnel in play: the target is this Mac, or the bridge is off.
        case local
        case connecting
        case connected
        /// A message meant for a person, straight from `SSHTunnel`.
        case failed(String)
    }

    public var isRemote: Bool {
        if case .remote = target { return true } else { return false }
    }

    public var config: BridgeConfig
    /// Text macros for the spare keys, reloaded on every bridge start so a
    /// config edit only needs an off/on toggle, not a relaunch.
    public private(set) var keyBindings = KeyBindings.load()

    /// Called when the stack key is pressed. The bridge owns the key, the app
    /// owns the window, so this is where the two meet.
    public var onStackKey: (() -> Void)?
    /// Called when the land key is pressed; same split as `onStackKey`.
    public var onLandKey: (() -> Void)?
    /// Called when either half of the wide voice key is pressed.
    public var onVoiceKey: (() -> Void)?
    /// Called per dial detent: +1 clockwise, -1 counter-clockwise.
    public var onDial: ((Int) -> Void)?
    /// Called when the joystick enters a cardinal sector.
    public var onJoystick: ((Pad.JoystickDirection) -> Void)?
    /// Consulted before any key does its normal job. Returning true consumes
    /// the press — this is how a pending land confirmation turns every other
    /// key into "cancel" without those keys also doing their usual work.
    public var onKeyIntercept: ((Int) -> Bool)?
    /// Called whenever `target` changes, before the new target is brought
    /// up. The app closes its Stack and Land windows here: what they show,
    /// and a pending land confirmation, belong to the target the pad left.
    public var onTargetChange: ((HerdrTarget) -> Void)?

    // MARK: - Internals

    private var device = WLDevice()
    /// Non-nil while the bridge is driving a virtual pad instead of hardware.
    @Published public private(set) var emulator: PadEmulator?
    private var lifecycle: HerdrEventStream?
    private var statusStreams: [String: HerdrEventStream] = [:]
    /// Internal so tests can check that no poll loop outlives its target.
    private(set) var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var lastFingerprint: String?
    private var issuedIDs = Set<Int>()
    private var warnedPermission = false
    /// Owned while the target is remote and the bridge runs.
    private var tunnel: SSHTunnel?
    /// The ssh the tunnel runs. A seam for live tests, which reach a
    /// throwaway sshd through a wrapper script rather than `~/.ssh/config`.
    var sshPath = "/usr/bin/ssh"
    /// Where `refresh()` reads agents from. A seam for tests, which hold a
    /// read open to land a stop or a switch in the middle of it.
    var listAgents: @MainActor () async throws -> [HerdrAgent] = { try await HerdrClient.listAgents() }
    /// Whether the Herdr side — socket path, tunnel, streams, poll — is up
    /// for the current target. Separate from `isRunning` because the device
    /// opens first: until `start()` has opened it and ensured the keymap,
    /// nothing may refresh — a refresh would paint keys that may not be bound
    /// yet, and read whatever socket the previous target left behind.
    private var herdrActive = false
    /// True while `start()` is between turning on and `startHerdr()`: the
    /// device side is still opening, and `start()` will bring up whatever the
    /// target is by then.
    private var openingDevice = false
    /// Bumped on every Herdr teardown. Callbacks and replies that were set up
    /// under an older value belong to a target the pad no longer mirrors —
    /// a superseded tunnel's state change, a closed stream's retry, an
    /// `agent.list` that was in flight across a switch — and are dropped.
    private var herdrGeneration = 0

    public init(config: BridgeConfig = BridgeConfig()) {
        self.config = config
        wire(device)
    }

    /// Swap the hardware for a virtual pad, or back. The device is rebuilt
    /// either way, so the bridge reconnects from scratch rather than trying to
    /// carry state across a transport it no longer has.
    public func useEmulator(_ on: Bool) async {
        guard on != (emulator != nil) else { return }
        let wasRunning = isRunning
        if wasRunning { await stop() }
        let pad = on ? PadEmulator() : nil
        emulator = pad
        device = WLDevice(emulator: pad)
        wire(device)
        if wasRunning { await start() }
    }

    private func wire(_ device: WLDevice) {
        device.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.deviceConnected = false
            self.lastFingerprint = nil
            if self.isRunning { self.scheduleReopen() }
        }
        device.onTX = { [weak self] _, _, id in
            self?.issuedIDs.insert(id)
        }
        device.onResponse = { [weak self] id, _, _ in
            guard let self else { return }
            // A reply to an id we never sent came from another client.
            if self.issuedIDs.remove(id) == nil { self.contendingClient = true }
        }
        device.onNotification = { [weak self] method, params in
            guard let self, method == OAI.notifyHID else { return }
            guard let dict = params as? [String: Any] else { return }
            guard (dict["act"] as? Int) == 1 else { return }   // press, not release
            guard let index = OAI.agIndex(dict["k"] as? String) else { return }
            self.handleKeyPress(index)
        }
    }

    // MARK: - Lifecycle

    public func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        contendingClient = false
        keyBindings = KeyBindings.load()

        openingDevice = true
        await openDevice()
        openingDevice = false
        await startHerdr()
    }

    public func stop() async {
        isRunning = false
        // A start() still opening the device finds isRunning false and stops
        // there; clearing this now keeps a quick stop/start from inheriting it.
        openingDevice = false
        reopenTask?.cancel(); reopenTask = nil
        teardownHerdr()
        await teardownDevice()
    }

    /// Points the pad at another Herdr server. Takes effect at once while
    /// running, otherwise on the next `start()`.
    ///
    /// Only the Herdr side is rebuilt: the device stays open, so there is no
    /// keymap re-read and no flicker. The old target's agent lights are
    /// cleared first, so they can never pass for the new target's.
    public func setTarget(_ target: HerdrTarget) async {
        guard target != self.target else { return }
        self.target = target
        onTargetChange?(target)
        guard isRunning else { return }

        teardownHerdr()
        // Whatever went wrong was about the server the pad just left.
        lastError = nil
        // start() is still opening the pad: it brings up the new target
        // itself, and must be the first to paint, once the keymap is ensured.
        guard !openingDevice else { return }
        let generation = herdrGeneration
        await render([])
        // Another switch, or a stop, may have come in during the repaint;
        // whichever did owns the Herdr side now.
        guard isRunning, generation == herdrGeneration else { return }
        await startHerdr()
    }

    /// Retries a failed remote link now. A transient failure would retry by
    /// itself, but only after its backoff; a permanent one (a rejected key,
    /// an unknown host key) never does, and re-selecting the same target is
    /// a no-op. So once the user has fixed what the message named, this is
    /// the way back short of switching off and on.
    public func reconnect() {
        guard isRunning, herdrActive, case .failed = link, let tunnel else { return }
        // `stop()` reports `.idle`, which `tunnelChanged` ignores; `start()`
        // then moves the link to `.connecting` as any first attempt would.
        tunnel.stop()
        tunnel.start()
    }

    /// Switches the pad dark, closes it and kills a remote target's ssh, all
    /// before returning. Meant for `applicationWillTerminate`: the process
    /// exits as soon as that returns, so the `Task` a `stop()` would need
    /// never runs and the pad would keep showing the last agents after quit.
    ///
    /// Each write still waits for its reply, as every other call does, so the
    /// firmware never has two messages in flight; `replyTimeout` bounds that
    /// wait, so a pad that stopped answering cannot hold up the quit for
    /// long. The persisted on/off setting is left alone: quitting is not
    /// switching off, and the next launch starts again.
    public func shutdown(replyTimeout: TimeInterval = 0.5) {
        isRunning = false
        openingDevice = false
        reopenTask?.cancel(); reopenTask = nil
        teardownHerdr()
        guard device.isConnected else { return }
        for call in Self.lightsOffCalls {
            callBlocking(call.method, params: call.params, timeout: replyTimeout)
        }
        device.disconnect(reason: nil)
        clearDeviceState()
    }

    /// Sends one call and spins the main run loop until its reply or the
    /// timeout. Only for `shutdown()`, where there is no later turn of the
    /// run loop to await: the reply arrives through an input report (or, on
    /// the emulator, a main-queue block), and both need the loop to run.
    /// Called from inside a main-queue job, the main queue cannot drain, so
    /// the reply never lands and the call waits out its timeout; the write
    /// itself has already gone out by then.
    private func callBlocking(_ method: String, params: Any, timeout: TimeInterval) {
        var answered = false
        guard device.call(method, params: params, completion: { _, _ in answered = true }) != nil
        else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !answered, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    /// Kills a remote target's ssh, synchronously. Part of `shutdown()`, and
    /// of every Herdr teardown; the tunnel's stdin trick already covers a
    /// crash. Nothing restarts the tunnel afterwards short of the next
    /// `start()` or `setTarget`.
    public func shutdownTunnel() {
        guard let tunnel else { return }
        // Its `.idle` is our own doing, not news for `link`.
        tunnel.onStateChange = nil
        tunnel.stop()
        self.tunnel = nil
    }

    // MARK: - Herdr side

    /// Brings up the current target — the tunnel first if it is remote —
    /// then the streams and the poll. Does nothing if already up, so a
    /// `start()` and a `setTarget` that overlap bring it up once.
    private func startHerdr() async {
        guard isRunning, !herdrActive else { return }
        herdrActive = true
        let generation = herdrGeneration

        switch target {
        case .local:
            HerdrClient.setSocketPath(nil)
            link = .local
        case .remote(let remote):
            let tunnel = SSHTunnel(remote: remote, sshPath: sshPath)
            tunnel.onStateChange = { [weak self] state in
                guard let self, generation == self.herdrGeneration else { return }
                self.tunnelChanged(state)
            }
            self.tunnel = tunnel
            // The path is fixed per remote, so every call can be pointed at
            // it before the forward exists. Until it does, they fail fast
            // and the lifecycle stream and poll simply retry.
            HerdrClient.setSocketPath(tunnel.localSocket)
            link = .connecting
            tunnel.start()
        }

        startLifecycleStream()
        await refresh()
        // A stop or a switch during the refresh owns the Herdr side now; a
        // poll started here would carry its generation and never be dropped.
        guard isRunning, generation == herdrGeneration else { return }

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.config.pollInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled, generation == self.herdrGeneration else { return }
                await self.refresh()
            }
        }
    }

    /// Everything that talks to Herdr, and nothing that talks to the pad.
    private func teardownHerdr() {
        herdrActive = false
        herdrGeneration += 1
        pollTask?.cancel(); pollTask = nil
        debounceTask?.cancel(); debounceTask = nil
        lifecycle?.stop(); lifecycle = nil
        statusStreams.values.forEach { $0.stop() }
        statusStreams.removeAll()
        // Stop the old tunnel before a new one can start: two tunnels to the
        // same remote share a local socket path.
        shutdownTunnel()
        // Back to the local default, so the next bring-up always moves the
        // client's generation and nothing in flight survives the switch —
        // even when a remote was edited in place and keeps its socket path.
        HerdrClient.setSocketPath(nil)
        link = .local
        agents = []
        lastFingerprint = nil
    }

    /// Mirrors the tunnel into `link`, and repaints at once rather than on
    /// the next poll: on `.connected` to show the remote's agents, on a drop
    /// to stop showing them as live.
    private func tunnelChanged(_ state: SSHTunnel.State) {
        let newLink: LinkState
        switch state {
        case .idle: return   // only `stop()` gets here, and that is ours
        case .connecting: newLink = .connecting
        case .connected: newLink = .connected
        case .failed(let message): newLink = .failed(message)
        }
        guard newLink != link else { return }
        link = newLink
        Task { [weak self] in
            if newLink == .connected {
                await self?.forceRepaint()
            } else {
                await self?.refresh()
            }
        }
    }

    /// Whether Herdr calls can reach the target right now. Always assumed for
    /// this Mac — a local failure is reported as it always was.
    private var linkUp: Bool {
        link == .local || link == .connected
    }

    // MARK: - Device teardown

    private func teardownDevice() async {
        // Switching off clears the lights but deliberately leaves the keymap
        // alone: rebinding is a flash write, and the keys light instantly on
        // the way back in if the bindings are still there.
        if device.isConnected {
            await allLightsOff()
            device.disconnect(reason: nil)
        }
        clearDeviceState()
    }

    private func clearDeviceState() {
        deviceConnected = false
        keyColors = [:]
        keyEffects = [:]
        aggregateState = nil
        agents = []
    }

    // MARK: - Device

    private func openDevice() async {
        // Ask for Input Monitoring explicitly. hidapi-style opens just fail
        // with a privilege violation without ever raising the prompt, which
        // reads as a bug rather than a permission. The virtual pad needs none.
        if device.emulator == nil,
           IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        do {
            try device.connect()
            deviceConnected = true
            permissionDenied = false
            warnedPermission = false
            deviceName = device.info?.product ?? "Work Louder device"
            lastError = nil
        } catch {
            deviceConnected = false
            let message = error.localizedDescription
            if message.contains("0xE00002C1") || message.contains("Input Monitoring") {
                permissionDenied = true
                if !warnedPermission { warnedPermission = true; lastError = message }
            } else {
                lastError = message
            }
            scheduleReopen()
            return
        }

        if let version = try? await device.callAsync("sys.version"),
           let dict = version as? [String: Any],
           let text = dict["version"] as? String {
            firmware = text
        }
        if let status = try? await device.callAsync("device.status"),
           let dict = status as? [String: Any],
           let percent = dict["battery"] as? Int {
            let charging = (dict["is_charging"] as? Bool) == true
            battery = "\(percent)%\(charging ? " ⚡" : "")"
        }

        await ensureKeymap()
    }

    /// Per-key lighting only works on keys bound to `KV_OAI_AG*` on the active
    /// layer, and nothing reports a mismatch — `v.oai.thstatus` answers
    /// `{"ok":1}` for a key it cannot light. So check rather than assume.
    private func ensureKeymap() async {
        do {
            if config.manageKeymap {
                _ = try await KeymapManager.apply(device)
                keymapReady = true
            } else {
                let cfg = try await KeymapManager.read(device)
                keymapReady = KeymapManager.isAgentKeymapApplied(cfg)
                if !keymapReady {
                    lastError = "The agent keys and the stack key are not bound to KV_OAI_AG00..AG06, so per-key colours will do nothing."
                }
            }
        } catch {
            keymapReady = false
            lastError = "Keymap: \(error.localizedDescription)"
        }
    }

    private func scheduleReopen() {
        guard isRunning, reopenTask == nil else { return }
        reopenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isRunning else { return }
                if self.deviceConnected { break }
                await self.openDevice()
                if self.deviceConnected {
                    await self.forceRepaint()
                    break
                }
            }
            self?.reopenTask = nil
        }
    }

    // MARK: - Herdr events

    private func startLifecycleStream() {
        guard isRunning, herdrActive else { return }
        let generation = herdrGeneration
        let stream = HerdrEventStream(subscriptions: [
            ["type": "pane.created"],
            ["type": "pane.closed"],
            ["type": "pane.exited"],
            ["type": "pane.agent_detected"],
        ])
        stream.onEvent = { [weak self] _ in self?.schedule() }
        stream.onClosed = { [weak self] _ in
            // A close already queued when the stream was stopped must not
            // drop — or restart — the stream that replaced it.
            guard let self, self.isRunning, generation == self.herdrGeneration else { return }
            self.lifecycle = nil
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, generation == self.herdrGeneration else { return }
                self.startLifecycleStream()
            }
        }
        lifecycle = stream.start()
    }

    /// One dedicated stream per agent pane: a subscription owns its connection
    /// and cannot be extended after the fact.
    private func reconcileStatusStreams(_ agents: [HerdrAgent]) {
        let wanted = Set(agents.compactMap(\.paneID))
        for (paneID, stream) in statusStreams where !wanted.contains(paneID) {
            stream.stop()
            statusStreams.removeValue(forKey: paneID)
        }
        let generation = herdrGeneration
        for paneID in wanted where statusStreams[paneID] == nil {
            let stream = HerdrEventStream(subscriptions: [
                ["type": "pane.agent_status_changed", "pane_id": paneID],
            ])
            stream.onEvent = { [weak self] _ in self?.schedule() }
            stream.onClosed = { [weak self] _ in
                // Pane ids are only unique per server: after a switch, the
                // same id may name the new target's stream.
                guard let self, generation == self.herdrGeneration else { return }
                self.statusStreams.removeValue(forKey: paneID)
            }
            statusStreams[paneID] = stream.start()
        }
    }

    private func schedule() {
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.config.debounce
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Cancelled by a teardown, which may already have let a new
            // debounce start; that one is not ours to clear.
            if Task.isCancelled { return }
            self.debounceTask = nil
            await self.refresh()
        }
    }

    // MARK: - Repaint

    public func forceRepaint() async {
        lastFingerprint = nil
        await refresh()
    }

    /// Re-reads `agent.list` and paints it. While a remote link is down there
    /// is nothing to read: the pad shows no agents, and the raw socket error
    /// (which names a temp path nobody would recognise) is not surfaced —
    /// `link` already says what is wrong.
    private func refresh() async {
        guard isRunning, herdrActive else { return }
        let generation = herdrGeneration

        var fetched: [HerdrAgent] = []
        if linkUp {
            do {
                fetched = try await listAgents()
            } catch {
                // A switch or a dropped link since the request went out makes
                // the error about something the UI no longer shows.
                guard generation == herdrGeneration, linkUp else { return }
                lastError = error.localizedDescription
                return
            }
            guard isRunning, generation == herdrGeneration else { return }
            lastError = nil
        }
        agents = fetched
        reconcileStatusStreams(fetched)
        await render(fetched)
    }

    /// Paints the pad for a set of agents, skipping the device when the
    /// picture has not changed since the last paint.
    private func render(_ agents: [HerdrAgent]) async {
        let state = StatusMapper.aggregate(agents, config)
        let threads = Self.padThreads(
            agents: agents,
            keyBindings: keyBindings,
            voiceActive: voiceActive,
            stackPanelOpen: stackPanelOpen,
            landPanelOpen: landPanelOpen,
            isRemote: isRemote,
            config
        )

        // Fingerprint the whole rendered picture, not just the aggregate, so
        // one agent changing still repaints when the worst state has not.
        let fingerprint = threads.map { thread in
            "\(thread.id):\(thread.color ?? -1):\(thread.effect?.rawValue ?? -1):\(thread.brightness ?? -1)"
        }.joined(separator: "|") + "|agg:\(state ?? "-")"

        publishKeyState(threads)
        aggregateState = state

        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        await apply(state: state, threads: threads)
    }

    /// Every key the bridge lights, in one list: the agent keys, then the
    /// action keys, then the macro/voice keys. Pure, so what each mode paints
    /// can be tested without a device.
    ///
    /// Stack and Land run the local `but` in the agent's working directory,
    /// which on a remote target is a path on another machine, so they go dark
    /// there — dark reads as "unavailable", where a dim light means "ready".
    nonisolated static func padThreads(
        agents: [HerdrAgent],
        keyBindings: KeyBindings,
        voiceActive: Bool,
        stackPanelOpen: Bool,
        landPanelOpen: Bool,
        isRemote: Bool,
        _ config: BridgeConfig
    ) -> [OAI.Thread] {
        // Macro and voice keys share ids, so the binding decides each key's
        // light: configured text wins, the wide key falls back to voice.
        let flexKeys = (Pad.macroKeyIDs + Pad.voiceKeyIDs).map { key -> OAI.Thread in
            if keyBindings.text(for: key) != nil {
                return StatusMapper.macroThread(id: key, config)
            }
            if Pad.voiceKeyIDs.contains(key) {
                return StatusMapper.voiceThread(id: key, active: voiceActive, config)
            }
            return OAI.Thread(id: key, brightness: 0, effect: .off)
        }
        let stack = isRemote
            ? OAI.Thread(id: Pad.stackKeyID, brightness: 0, effect: .off)
            : StatusMapper.stackThread(open: stackPanelOpen, config)
        let land = isRemote
            ? OAI.Thread(id: Pad.landKeyID, brightness: 0, effect: .off)
            : StatusMapper.landThread(open: landPanelOpen, config)
        return StatusMapper.threads(for: agents, config)
            + [stack, StatusMapper.tabCycleThread(config), land]
            + flexKeys
    }

    private func publishKeyState(_ threads: [OAI.Thread]) {
        var colors: [Int: Color] = [:]
        var effects: [Int: OAI.Effect] = [:]
        for thread in threads {
            guard let packed = thread.color, (thread.brightness ?? 0) > 0,
                  let effect = thread.effect, effect != .off else { continue }
            colors[thread.id] = Color(packedRGB: packed)
            effects[thread.id] = effect
        }
        keyColors = colors
        keyEffects = effects
    }

    private func apply(state: String?, threads: [OAI.Thread]) async {
        guard deviceConnected else { return }
        do {
            _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
            let zone = StatusMapper.zone(for: state, config) ?? .dark
            _ = try await device.callAsync(
                OAI.methodRGBConfig,
                params: OAI.rgbConfigParams(
                    keys: config.driveBacklight ? zone : .dark,
                    ambient: zone
                )
            )
        } catch {
            lastError = error.localizedDescription
            lastFingerprint = nil   // repaint on the next tick
        }
    }

    /// Thread state paints over zone state, so clearing the zones alone leaves
    /// the pad lit. Both have to go.
    private static var lightsOffCalls: [(method: String, params: Any)] {
        let threads = (0...Pad.maxThreadID).map {
            OAI.Thread(id: $0, brightness: 0, effect: .off, syncKeys: false, syncAmbient: false)
        }
        return [
            (OAI.methodThreads, OAI.threadsParams(threads)),
            (OAI.methodRGBConfig, OAI.rgbConfigParams(keys: .dark, ambient: .dark)),
        ]
    }

    private func allLightsOff() async {
        for call in Self.lightsOffCalls {
            _ = try? await device.callAsync(call.method, params: call.params)
        }
    }

    // MARK: - Key presses

    /// Every bound key arrives here. Which key does what is the one place that
    /// has to agree with `Pad`, so keep the dispatch in a single switch.
    public func handleKeyPress(_ index: Int) {
        if onKeyIntercept?(index) == true { return }
        // Dark on a remote target (see `padThreads`); say why rather than
        // letting the press vanish. A land window that outlived a switch to a
        // remote (one still running when the target changed) still owns the
        // land key: its report says to press it again to dismiss.
        let landKeyOwnedByPanel = index == Pad.landKeyID && landPanelOpen
        if isRemote, index == Pad.stackKeyID || index == Pad.landKeyID, !landKeyOwnedByPanel {
            noteError("Stack and Land are not available for a remote Herdr.")
            return
        }
        if index == Pad.stackKeyID {
            onStackKey?()
        } else if index == Pad.tabCycleKeyID {
            Task { await cycleTabs() }
        } else if index == Pad.landKeyID {
            onLandKey?()
        } else if Pad.macroKeyIDs.contains(index) || Pad.voiceKeyIDs.contains(index) {
            // A configured text macro wins over the key's built-in role, which
            // is how the config file may repurpose the wide voice key.
            if let text = keyBindings.text(for: index) {
                Task { await injectPrompt(text) }
            } else if Pad.voiceKeyIDs.contains(index) {
                onVoiceKey?()
            }
        } else if index == Pad.dialUpID || index == Pad.dialDownID {
            onDial?(index == Pad.dialUpID ? 1 : -1)
        } else if let direction = Pad.JoystickDirection(keyID: index) {
            onJoystick?(direction)
        } else if let slot = Pad.agentSlot(for: index) {
            Task { await focusSlot(slot) }
        }
    }

    /// Types a macro string into the focused agent's prompt, unsubmitted —
    /// the human still reads it and presses enter.
    public func injectPrompt(_ text: String) async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let pane = agent.paneID
            else {
                lastError = "Nothing has focus in Herdr right now."
                return
            }
            try await HerdrClient.sendText(paneID: pane, text: text)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the voice key. Same contract as `setStackPanelOpen`.
    public func setVoiceActive(_ active: Bool) async {
        guard voiceActive != active else { return }
        voiceActive = active
        await forceRepaint()
    }

    /// Lets app-layer features that fail outside the bridge surface their
    /// error where the menu already shows the bridge's own.
    public func noteError(_ message: String) {
        lastError = message
    }

    /// Advances the focused workspace to its next tab, wrapping.
    public func cycleTabs() async {
        do {
            try await HerdrClient.cycleTabs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the stack key. Called by the app when the window opens or
    /// closes, so the key reflects what is actually on screen.
    public func setStackPanelOpen(_ open: Bool) async {
        guard stackPanelOpen != open else { return }
        stackPanelOpen = open
        await forceRepaint()
    }

    /// Repaints the land key. Same contract as `setStackPanelOpen`.
    public func setLandPanelOpen(_ open: Bool) async {
        guard landPanelOpen != open else { return }
        landPanelOpen = open
        await forceRepaint()
    }

    /// Slot N is the Nth key in reading order (`Pad.agentKeyIDs[N]`) — the
    /// same mapping the lighting uses, which is what makes the key you look at
    /// the key you press.
    ///
    /// Herdr selects the pane but leaves the terminal wherever it was in the
    /// window order, so an agent key pressed from a browser used to move a
    /// cursor you could not see. The terminal comes forward with it.
    public func focusSlot(_ index: Int) async {
        guard index >= 0, index < agents.count else { return }
        guard let target = agents[index].focusTarget else { return }
        do {
            try await HerdrClient.focusAgent(target)
            raiseTerminal()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The app Herdr's panes live in. Override with `WL_TERMINAL_BUNDLE_ID` if
    /// they live somewhere other than Ghostty.
    public static let defaultTerminalBundleID = "com.mitchellh.ghostty"

    /// Brings the terminal forward unless it is already the active app.
    ///
    /// Nothing is ever launched: the agent whose key was pressed is running in
    /// a pane of a terminal that is by definition already up, so a terminal
    /// that is not running means the bundle id is wrong, and opening a fresh
    /// window would not be what the key meant. macOS may refuse a background
    /// app's `activate` outright, which is what the second attempt is for —
    /// `openApplication` on an already-running app raises it the way `open -a`
    /// does.
    private func raiseTerminal() {
        let identifier = ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTerminalBundleID
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier).first
        else { return }
        guard !app.isActive else { return }
        if app.activate(options: []) { return }
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
