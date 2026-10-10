import SwiftUI
import AppKit
import ServiceManagement
import WLKit

struct MenuPanelView: View {
    @EnvironmentObject var bridge: BridgeController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var inspectorError: String?
    @State private var configError: String?
    @State private var remotes: [HerdrRemote] = HerdrRemotes.load()
    @State private var panel = PanelWindow()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            targetSection
            Divider()

            if bridge.permissionDenied {
                permissionBanner
            } else if bridge.isRunning {
                padSection
                Divider()
                agentSection
            } else {
                idleHint
            }

            if let error = bridge.lastError, !bridge.permissionDenied {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }

            if bridge.contendingClient {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        "Another app is also driving this pad — colours may fight.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Recheck") { Task { await bridge.recheckContention() } }
                        .controlSize(.small)
                        .help("Clear the warning. It comes back if the other app sends to the pad again.")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }

            Divider()
            footer
        }
        .frame(width: 300)
        // Re-read on every opening, so a config edit shows up without a
        // relaunch. The window may be kept alive between openings, in which
        // case only becoming key marks a new one — this panel's window, not
        // the emulator or any other window of the app, which would re-read
        // the config (and maybe restart a tunnel) for no reason.
        .onAppear { reloadRemotes() }
        .background(WindowReader { panel.window = $0 })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window === panel.window else { return }
            reloadRemotes()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Micro Manager").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { bridge.isRunning },
                set: { on in
                    BridgeSettings.enabled = on
                    // Set, not toggle: a stale displayed state must not turn
                    // a click into the opposite of what the switch shows.
                    Task { if on { await bridge.start() } else { await bridge.stop() } }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(bridge.isRunning ? "Turn off" : "Turn on")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var subtitle: String {
        guard bridge.isRunning else { return "Off" }
        guard bridge.deviceConnected else { return "Looking for the pad…" }
        var parts = [bridge.deviceName, bridge.firmware]
        if let battery = bridge.battery { parts.append(battery) }
        if bridge.link == .connected, let name = bridge.target.remoteName {
            parts.append("via \(name)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Target

    /// `HERDR_SOCKET_PATH` beats any tunnel (see `HerdrClient.socketPath`),
    /// so offering a choice would only start an ssh nothing reads through.
    private var targetOverridden: Bool {
        HerdrClient.environmentOverride != nil
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Herdr")
                Picker("Herdr", selection: targetSelection) {
                    Text("This Mac").tag(String?.none)
                    if !pickerRemotes.isEmpty { Divider() }
                    ForEach(pickerRemotes) { remote in
                        Text(remote.name).tag(String?.some(remote.name))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(targetOverridden)
            }

            if targetOverridden {
                caption("Overridden by HERDR_SOCKET_PATH")
            } else if bridge.isRemote {
                linkStatus
            } else if remotes.isEmpty {
                caption("Add hosts under \"remotes\" in config.json")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// The selection is the remote's name; nil is this Mac.
    private var targetSelection: Binding<String?> {
        Binding(
            get: { bridge.target.remoteName },
            set: { name in
                guard !targetOverridden else { return }
                BridgeSettings.targetName = name
                let target = HerdrRemotes.target(named: name, in: pickerRemotes)
                Task { await bridge.setTarget(target) }
            }
        )
    }

    /// The configured remotes, plus the current one if it has since been
    /// removed from the config: the pad still mirrors it, and a picker
    /// showing a blank selection would hide which host that is.
    private var pickerRemotes: [HerdrRemote] {
        guard case .remote(let current) = bridge.target,
              !remotes.contains(where: { $0.name == current.name })
        else { return remotes }
        return remotes + [current]
    }

    @ViewBuilder
    private var linkStatus: some View {
        switch bridge.link {
        case .connected:
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                caption("Connected via SSH")
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Retry") { bridge.reconnect() }
                    .controlSize(.small)
                    .help("Try to connect again now")
            }
        case .connecting, .local:
            // `.local` with a remote target only while the bridge is off, or
            // for the instant between a teardown and the next bring-up.
            caption(bridge.isRunning ? "Connecting…" : "Connects over SSH when switched on")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Picks up config edits. A remote edited in place under the name the
    /// pad is mirroring is re-applied, the same as choosing it again would.
    private func reloadRemotes() {
        remotes = HerdrRemotes.load()
        guard !targetOverridden, case .remote(let current) = bridge.target,
              let updated = remotes.first(where: { $0.name == current.name }),
              updated != current
        else { return }
        Task { await bridge.setTarget(.remote(updated)) }
    }

    // MARK: - Pad

    private var padSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Pad.displayRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in keyView(key) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func keyView(_ index: Int) -> some View {
        let color = bridge.keyColors[index]
        let isBound = Pad.boundKeyIDs.contains(index)
        let isStackKey = index == Pad.stackKeyID
        let isTabCycleKey = index == Pad.tabCycleKeyID
        let isLandKey = index == Pad.landKeyID
        // Their `but` would run here, in a directory on the other machine.
        let isUnavailable = bridge.isRemote && (isStackKey || isLandKey)
        let macroText = bridge.keyBindings.text(for: index)
        let isVoiceKey = macroText == nil && Pad.voiceKeyIDs.contains(index)
        // Key index and agent slot are different orderings — the top row is
        // wired right to left — so the slot lookup goes through the pad map.
        let slot = Pad.agentSlot(for: index)
        let agent = slot.flatMap { $0 < bridge.agents.count ? bridge.agents[$0] : nil }

        return Button {
            if isStackKey {
                StackPanelController.shared.toggle()
            } else if isTabCycleKey {
                Task { await bridge.cycleTabs() }
            } else if isLandKey {
                LandPanelController.shared.handleLandKey()
            } else if let macroText {
                Task { await bridge.injectPrompt(macroText) }
            } else if isVoiceKey {
                VoiceController.shared.handleVoiceKey()
            } else if let slot, agent != nil {
                Task { await bridge.focusSlot(slot) }
            }
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(color ?? Color.secondary.opacity(isBound ? 0.16 : 0.07))
                .frame(width: 34, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable
                  || (agent == nil && !isStackKey && !isTabCycleKey && !isLandKey
                      && macroText == nil && !isVoiceKey))
        .help(isUnavailable
              ? "Not available for a remote Herdr"
              : helpText(index, agent: agent, isStackKey: isStackKey,
                         isTabCycleKey: isTabCycleKey, isLandKey: isLandKey,
                         macroText: macroText, isVoiceKey: isVoiceKey))
    }

    private func helpText(
        _ index: Int,
        agent: HerdrAgent?,
        isStackKey: Bool,
        isTabCycleKey: Bool,
        isLandKey: Bool,
        macroText: String?,
        isVoiceKey: Bool
    ) -> String {
        if isStackKey { return "GitButler stack for the focused agent" }
        if isTabCycleKey { return "Cycle tabs in the focused Herdr window" }
        if isLandKey { return "Land the focused agent's branches onto the target" }
        if let macroText { return "Type: \(macroText)" }
        if isVoiceKey { return "Right command — start or stop Superwhisper" }
        if let agent { return "\(agent.shortName) — \(agent.status)" }
        return "Key \(index)"
    }

    // MARK: - Agents

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bridge.agents.isEmpty {
                Text("No agents running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            } else {
                ForEach(Array(bridge.agents.prefix(Pad.agentKeyIDs.count).enumerated()), id: \.offset) { index, agent in
                    Button {
                        Task { await bridge.focusSlot(index) }
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(bridge.keyColors[Pad.agentKeyIDs[index]] ?? Color.secondary.opacity(0.3))
                                .frame(width: 9, height: 9)
                            Text("\(index)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(agent.shortName).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(agent.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Other states

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Monitoring is needed", systemImage: "lock.fill")
                .font(.callout).bold()
            Text("macOS blocks access to the pad until this app is allowed to monitor input.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var idleHint: some View {
        Text("Switch on to light each agent on its own key.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Open at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 14).padding(.top, 8)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Registering only works from a bundled, signed app;
                        // reflect reality rather than leaving the box ticked.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            // The button row below is full, so the config button sits here.
            HStack {
                Toggle("Emulate the pad", isOn: Binding(
                    get: { bridge.emulator != nil },
                    set: { on in
                        BridgeSettings.emulate = on
                        Task {
                            await bridge.useEmulator(on)
                            if let emulator = bridge.emulator {
                                EmulatorWindowController.shared.show(emulator)
                            } else {
                                EmulatorWindowController.shared.close()
                            }
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .help("Drive a virtual pad instead of the hardware")
                Spacer()
                Button("Edit Config…") { editConfig() }
                    .help("Open config.json: macro keys, dial and joystick lists, remote Herdr hosts")
            }
            .padding(.horizontal, 14).padding(.top, 4)

            if let inspectorError { footerError(inspectorError) }
            if let configError { footerError(configError) }

            HStack {
                Button("Refresh") { Task { await bridge.forceRepaint() } }
                    .disabled(!bridge.isRunning)
                Button("Inspector") {
                    inspectorError = nil
                    InspectorLauncher.launch { inspectorError = $0 }
                }
                .help("Watch the traffic to and from the pad, and drive its lighting by hand")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func footerError(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.top, 6)
    }

    /// Opens the config file, creating an empty one first: everything works
    /// without it, so on most Macs there is nothing to open yet.
    private func editConfig() {
        configError = nil
        let path = KeyBindings.configPath()
        let url = URL(fileURLWithPath: path)
        let files = FileManager.default
        if !files.fileExists(atPath: path) {
            do {
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Never clobber a file that appeared since the check.
                try Data("{}\n".utf8).write(to: url, options: .withoutOverwriting)
            } catch {
                configError = "Could not create \(path): \(error.localizedDescription)"
                return
            }
        }
        // A Mac without Xcode or an editor that claims .json has no default
        // app for it, and `open` would fail silently; TextEdit is always there.
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            configError = "No app to open \(path) with."
        }
    }
}

/// The panel's window, held weakly. A class rather than view state, so
/// recording it never triggers a view update.
private final class PanelWindow {
    weak var window: NSWindow?
}

/// Reports the window its view is placed in, and again whenever that changes.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReportingView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReportingView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
