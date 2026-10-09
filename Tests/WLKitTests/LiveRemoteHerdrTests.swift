import XCTest
@testable import WLKit

/// Brings up a real SSH tunnel to a real remote Herdr. Skipped unless
/// `WL_TEST_REMOTE_HOST` names a host that `ssh` reaches without a prompt
/// (key or agent auth, host key already trusted):
///
///     WL_TEST_REMOTE_HOST=workbox swift test --filter LiveRemoteHerdrTests
///
/// `WL_TEST_REMOTE_SOCKET` overrides the remote socket path, as `"socket"`
/// does in config.json. `WL_TEST_SSH_PATH` stands in for `/usr/bin/ssh` —
/// say, a script running `exec /usr/bin/ssh -F test_config "$@"`, to test
/// against a throwaway sshd without touching `~/.ssh`.
///
/// `WL_TEST_REMOTE_HOLD=<seconds>` keeps the tunnel up that long before
/// stopping it, which is the window for the orphan check: `kill -9` the test
/// process, then `pgrep -fl 'cat >/dev/null'` should find no ssh left.
@MainActor
final class LiveRemoteHerdrTests: XCTestCase {

    override func tearDown() {
        HerdrClient.setSocketPath(nil)
        super.tearDown()
    }

    func testListAgentsThroughTheTunnel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["WL_TEST_REMOTE_HOST"], !host.isEmpty else {
            throw XCTSkip("WL_TEST_REMOTE_HOST not set")
        }
        if HerdrClient.environmentOverride != nil {
            throw XCTSkip("HERDR_SOCKET_PATH is set, so it wins over the tunnel")
        }
        let socket = environment["WL_TEST_REMOTE_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        let sshPath = environment["WL_TEST_SSH_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin/ssh"
        let tunnel = SSHTunnel(
            remote: HerdrRemote(name: "live-test", host: host, socket: socket),
            sshPath: sshPath
        )

        let connected = expectation(description: "tunnel connected")
        var lastState = SSHTunnel.State.idle
        tunnel.onStateChange = { state in
            lastState = state
            if state == .connected { connected.fulfill() }
        }
        tunnel.start()
        await fulfillment(of: [connected], timeout: 30)
        XCTAssertEqual(lastState, .connected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tunnel.localSocket))

        HerdrClient.setSocketPath(tunnel.localSocket)
        let agents = try await HerdrClient.listAgents()
        print("remote agents: \(agents.map { "\($0.shortName):\($0.status)" })")

        if let hold = environment["WL_TEST_REMOTE_HOLD"].flatMap(TimeInterval.init), hold > 0 {
            print("holding the tunnel for \(hold) s (pid \(getpid()))")
            try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
        }

        tunnel.stop()
        XCTAssertEqual(tunnel.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tunnel.localSocket))
        try await assertNoSSH(forwarding: tunnel.localSocket)
    }

    /// ssh exits on its own once stopped; nothing is left forwarding.
    private func assertNoSSH(forwarding localSocket: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !sshIsRunning(forwarding: localSocket) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("an ssh forwarding \(localSocket) is still running")
    }

    private func sshIsRunning(forwarding localSocket: String) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "--", "-L \(localSocket):"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return false }
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }
}
