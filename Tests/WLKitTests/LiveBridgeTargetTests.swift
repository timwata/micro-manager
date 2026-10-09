import XCTest
import IOKit.hid
@testable import WLKit

/// Switches a running bridge between targets, end to end, on the built-in
/// virtual pad: real Herdr sockets and a real ssh, no hardware.
///
/// Skipped unless this process already has Input Monitoring (`start()` would
/// otherwise raise the system prompt) and `HERDR_SOCKET_PATH` is unset (it
/// beats any target). Beyond that:
///
/// - `testSwitchingToAnUnreachableRemoteAndBack` needs a local Herdr with at
///   least one agent, and resolves a `.invalid` host, which fails at once.
/// - `testMirroringARemoteThroughATunnel` needs `WL_TEST_REMOTE_HOST`, with
///   `WL_TEST_REMOTE_SOCKET` and `WL_TEST_SSH_PATH` as in
///   `LiveRemoteHerdrTests`, and a remote Herdr with at least one agent.
@MainActor
final class LiveBridgeTargetTests: XCTestCase {

    private var bridge: BridgeController!

    override func setUp() async throws {
        try await super.setUp()
        if HerdrClient.environmentOverride != nil {
            throw XCTSkip("HERDR_SOCKET_PATH is set, so it wins over any target")
        }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            throw XCTSkip("no Input Monitoring; starting the bridge would prompt for it")
        }
        bridge = BridgeController()
        await bridge.useEmulator(true)
    }

    override func tearDown() async throws {
        await bridge?.stop()
        bridge = nil
        HerdrClient.setSocketPath(nil)
        try await super.tearDown()
    }

    /// Local mode after the start/stop split: off clears the pad and drops
    /// the device, on lights it again, and the stack key still reaches the
    /// app. (Agent and tab keys are left alone: they would move focus in the
    /// Herdr this runs against.)
    func testLocalOnOffAndStackKey() async throws {
        let local = HerdrClient.socketPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: local), "no local herdr server")
        let localAgents = try await HerdrClient.listAgents()
        try XCTSkipIf(localAgents.isEmpty, "no local agents to light")

        var stackPresses = 0
        bridge.onStackKey = { stackPresses += 1 }
        await bridge.start()
        let pad = try XCTUnwrap(bridge.emulator)
        try await waitUntil("local agents lit") { self.isLit(Pad.agentKeyIDs[0], on: pad) }
        XCTAssertEqual(bridge.link, .local)

        pad.press(Pad.stackKeyID)
        try await waitUntil("stack key reached the app") { stackPresses == 1 }
        XCTAssertNil(bridge.lastError)

        await bridge.stop()
        XCTAssertFalse(bridge.deviceConnected)
        XCTAssertTrue(bridge.agents.isEmpty)
        XCTAssertFalse(Pad.boundKeyIDs.contains { isLit($0, on: pad) })

        await bridge.start()
        try await waitUntil("lit again") { self.isLit(Pad.agentKeyIDs[0], on: pad) }
        assertLit(Pad.stackKeyID, true, on: pad)
    }

    func testSwitchingToAnUnreachableRemoteAndBack() async throws {
        let local = HerdrClient.socketPath()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: local), "no local herdr server")
        let localAgents = try await HerdrClient.listAgents()
        try XCTSkipIf(localAgents.isEmpty, "no local agents to light")

        await bridge.start()
        let pad = try XCTUnwrap(bridge.emulator)
        try await waitUntil("local agents lit") { self.isLit(Pad.agentKeyIDs[0], on: pad) }
        XCTAssertEqual(bridge.link, .local)
        assertLit(Pad.stackKeyID, true, on: pad)
        assertLit(Pad.landKeyID, true, on: pad)

        let bad = HerdrRemote(name: "live-unreachable", host: "mm-live-test.invalid")
        await bridge.setTarget(.remote(bad))
        // The old target's agents are gone before the new one has said
        // anything, and the device was never reopened.
        XCTAssertTrue(bridge.agents.isEmpty)
        XCTAssertTrue(bridge.deviceConnected)
        XCTAssertTrue(bridge.emulator === pad)
        assertLit(Pad.agentKeyIDs[0], false, on: pad)
        assertLit(Pad.stackKeyID, false, on: pad)
        assertLit(Pad.landKeyID, false, on: pad)
        assertLit(Pad.tabCycleKeyID, true, on: pad)

        try await waitUntil("link failed", timeout: 15) {
            if case .failed = self.bridge.link { return true } else { return false }
        }
        print("unreachable remote: \(bridge.link)")
        // The link carries the explanation; no raw socket error on top.
        XCTAssertNil(bridge.lastError)
        XCTAssertTrue(bridge.agents.isEmpty)

        pad.press(Pad.stackKeyID)
        try await waitUntil("stack press explained") {
            self.bridge.lastError == "Stack and Land are not available for a remote Herdr."
        }

        await bridge.setTarget(.local)
        XCTAssertEqual(bridge.link, .local)
        XCTAssertNil(bridge.lastError)
        try await waitUntil("local agents lit again") { self.isLit(Pad.agentKeyIDs[0], on: pad) }
        assertLit(Pad.stackKeyID, true, on: pad)
        assertLit(Pad.landKeyID, true, on: pad)

        // A retry scheduled by the abandoned tunnel must not bring it back.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertEqual(bridge.link, .local)
        XCTAssertEqual(HerdrClient.socketPath(), local)
    }

    func testMirroringARemoteThroughATunnel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["WL_TEST_REMOTE_HOST"], !host.isEmpty else {
            throw XCTSkip("WL_TEST_REMOTE_HOST not set")
        }
        let socket = environment["WL_TEST_REMOTE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        if let sshPath = environment["WL_TEST_SSH_PATH"], !sshPath.isEmpty {
            bridge.sshPath = sshPath
        }
        let remote = HerdrRemote(name: "live-bridge", host: host, socket: socket)
        let localSocket = SSHTunnel.localSocketPath(name: remote.name, directory: NSTemporaryDirectory())

        // Chosen while off, applied by start().
        await bridge.setTarget(.remote(remote))
        XCTAssertEqual(bridge.link, .local)
        await bridge.start()
        let pad = try XCTUnwrap(bridge.emulator)
        XCTAssertEqual(HerdrClient.socketPath(), localSocket)

        try await waitUntil("tunnel connected", timeout: 30) { self.bridge.link == .connected }
        try await waitUntil("remote agents lit") { self.isLit(Pad.agentKeyIDs[0], on: pad) }
        print("remote agents: \(bridge.agents.map { "\($0.shortName):\($0.status)" })")
        assertLit(Pad.stackKeyID, false, on: pad)
        assertLit(Pad.landKeyID, false, on: pad)

        // A dropped tunnel stops showing the remote's agents as live, then
        // comes back on its own.
        XCTAssertTrue(killSSH(forwarding: localSocket))
        try await waitUntil("link dropped") { self.bridge.link != .connected }
        try await waitUntil("agents cleared on drop") { !self.isLit(Pad.agentKeyIDs[0], on: pad) }
        XCTAssertTrue(bridge.agents.isEmpty)
        XCTAssertNil(bridge.lastError)
        try await waitUntil("tunnel reconnected", timeout: 30) { self.bridge.link == .connected }
        try await waitUntil("remote agents lit again") { self.isLit(Pad.agentKeyIDs[0], on: pad) }

        await bridge.setTarget(.local)
        XCTAssertEqual(bridge.link, .local)
        XCTAssertNotEqual(HerdrClient.socketPath(), localSocket)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localSocket))
        try await waitUntil("ssh gone") { !self.sshIsRunning(forwarding: localSocket) }
        assertLit(Pad.stackKeyID, true, on: pad)
    }

    // MARK: - Helpers

    /// `agents` is published before the paint reaches the pad, so anything
    /// that follows an agent change waits on the light itself.
    private func isLit(_ key: Int, on pad: PadEmulator) -> Bool {
        pad.keys[key]?.isLit ?? false
    }

    private func assertLit(_ key: Int, _ lit: Bool, on pad: PadEmulator, line: UInt = #line) {
        XCTAssertEqual(isLit(key, on: pad), lit, "key \(key)", line: line)
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 5,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for: \(what)", line: line)
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Ends the test at the first failed wait; the rest would only cascade.
    private struct TimedOut: Error {}

    private func killSSH(forwarding localSocket: String) -> Bool {
        run("/usr/bin/pkill", ["-f", "--", "-L \(localSocket):"])
    }

    private func sshIsRunning(forwarding localSocket: String) -> Bool {
        run("/usr/bin/pgrep", ["-f", "--", "-L \(localSocket):"])
    }

    /// Whether the command exited 0 — for pgrep/pkill, "something matched".
    private func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
