import SwiftUI
import AppKit
import WLKit

/// Owns the bridge and brings it up at launch.
///
/// This lives here rather than in the menu content because a `MenuBarExtra`
/// builds its content only when the panel is first opened: a `.task` there
/// left the pad dark after launch or login until the icon was clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let bridge = BridgeController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)

        wire()

        Task {
            // Choose the transport before starting: `useEmulator` rebuilds
            // the device, so doing it after would tear down a connection we
            // just made.
            await bridge.useEmulator(BridgeSettings.emulate)
            // And the target, so the first start brings up the right Herdr
            // rather than this Mac's and then switching.
            await bridge.setTarget(BridgeSettings.resolvedTarget())

            // Come back up in whatever state it was left in, so a login-item
            // launch resumes rather than sitting idle. Defaults to on for a
            // first run.
            if BridgeSettings.enabled, !bridge.isRunning {
                await bridge.start()
            }
        }
    }

    /// Nothing async gets to finish here, so the remote's ssh is killed
    /// synchronously. A crash skips this, which is what the tunnel's
    /// stdin-EOF lifetime is for.
    func applicationWillTerminate(_ notification: Notification) {
        bridge.shutdownTunnel()
    }

    /// The stack and land keys open windows, which the bridge knows nothing
    /// about, so the two are joined here.
    ///
    /// The closures capture the bridge and the panel singletons strongly: all
    /// of them live as long as the app, so there is no lifetime to break and
    /// the cycles through the singletons are harmless.
    private func wire() {
        let bridge = self.bridge

        let stack = StackPanelController.shared
        stack.onVisibilityChange = { open in
            Task { await bridge.setStackPanelOpen(open) }
        }
        bridge.onStackKey = { stack.toggle() }

        let land = LandPanelController.shared
        land.onVisibilityChange = { open in
            Task { await bridge.setLandPanelOpen(open) }
        }
        bridge.onLandKey = { land.handleLandKey() }

        let voice = VoiceController.shared
        voice.onActiveChange = { active in
            Task { await bridge.setVoiceActive(active) }
        }
        voice.onError = { message in
            bridge.noteError(message)
        }
        bridge.onVoiceKey = { voice.handleVoiceKey() }

        let tune = TuneController.shared
        tune.onError = { message in
            bridge.noteError(message)
        }
        tune.bindings = { bridge.keyBindings }
        bridge.onDial = { step in tune.handleDial(step) }
        bridge.onJoystick = { direction in tune.handleJoystick(direction) }
        // While a land confirmation is up, every key that is not the land key
        // means "cancel", nothing else.
        bridge.onKeyIntercept = { index in
            guard index != Pad.landKeyID else { return false }
            return land.handleOtherKey()
        }
        // What the two windows show — and a pending land confirmation —
        // belongs to the server the pad just left.
        bridge.onTargetChange = { _ in
            stack.close()
            land.closeForTargetChange()
        }
    }
}

@main
struct MicroManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(delegate.bridge)
        } label: {
            MenuBarLabel(bridge: delegate.bridge)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The icon as its own view: the `App` struct cannot observe an object held by
/// its delegate, so without this the icon would never re-render on a state
/// change.
private struct MenuBarLabel: View {
    @ObservedObject var bridge: BridgeController

    var body: some View {
        let state = MenuBarIcon.State.from(bridge)
        Image(nsImage: MenuBarIcon.image(for: state, help: MenuBarIcon.help(for: state, bridge)))
    }
}

/// Persisted across launches.
enum BridgeSettings {
    private static let key = "bridgeEnabled"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static let emulateKey = "emulatePad"

    /// Drive a virtual pad instead of the hardware. `WL_EMULATE=1` forces it on
    /// for a single run, which is what makes `swift run` useful with no device
    /// plugged in.
    static var emulate: Bool {
        get {
            if ProcessInfo.processInfo.environment["WL_EMULATE"] == "1" { return true }
            return UserDefaults.standard.bool(forKey: emulateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: emulateKey) }
    }

    private static let targetKey = "herdrTarget"

    /// The remote the pad last mirrored, by name; nil means this Mac.
    static var targetName: String? {
        get { UserDefaults.standard.string(forKey: targetKey) }
        set { UserDefaults.standard.set(newValue, forKey: targetKey) }
    }

    /// The persisted selection, looked up in the current config. This Mac
    /// when `HERDR_SOCKET_PATH` is set — it wins over any tunnel, so a remote
    /// would only be a link the pad does not actually read through — or when
    /// the remote has since been removed from the config.
    static func resolvedTarget() -> HerdrTarget {
        guard HerdrClient.environmentOverride == nil else { return .local }
        return HerdrRemotes.target(named: targetName, in: HerdrRemotes.load())
    }
}
