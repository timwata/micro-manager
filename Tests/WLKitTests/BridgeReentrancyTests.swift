import XCTest
@testable import WLKit

/// Stops and switches that land while the bridge is suspended mid-start, on
/// the built-in virtual pad with `agent.list` stubbed out — so, unlike the
/// `Live*` tests, these run everywhere, CI included.
///
/// A real ssh is never started: the one remote used here runs `/usr/bin/false`
/// in its place, and the bridge only ever reads agents through the stub.
@MainActor
final class BridgeReentrancyTests: XCTestCase {

    private var bridge: BridgeController!
    private let agent = HerdrAgent(status: "working", paneID: "reentrancy:p1")
    private let remote = HerdrTarget.remote(HerdrRemote(name: "reentrancy", host: "mm-reentrancy.invalid"))

    override func setUp() async throws {
        try await super.setUp()
        bridge = BridgeController()
        bridge.sshPath = "/usr/bin/false"
        await bridge.useEmulator(true)
    }

    override func tearDown() async throws {
        await bridge?.stop()
        bridge = nil
        HerdrClient.setSocketPath(nil)
        try await super.tearDown()
    }

    // MARK: - A teardown during startHerdr's first refresh

    /// A stop while `start()` waits on its first `agent.list` must leave no
    /// poll loop behind once that read comes back.
    func testStopDuringFirstRefreshLeavesNoPoll() async throws {
        let gate = Gate()
        bridge.listAgents = { try await gate.hold() }

        let starting = Task { await bridge.start() }
        try await waitUntil("first agent.list in flight") { gate.isHolding }

        await bridge.stop()
        gate.release([agent])
        await starting.value

        XCTAssertFalse(bridge.isRunning)
        XCTAssertNil(bridge.pollTask)
    }

    /// A switch while `start()` waits on its first `agent.list` owns the
    /// Herdr side from then on: when the read comes back, the resumed start
    /// must not replace the switch's poll with one of its own.
    func testSwitchDuringFirstRefreshKeepsOnePoll() async throws {
        let gate = Gate()
        bridge.listAgents = { try await gate.hold() }

        let starting = Task { await bridge.start() }
        try await waitUntil("first agent.list in flight") { gate.isHolding }

        await bridge.setTarget(remote)
        let poll = try XCTUnwrap(bridge.pollTask, "the switch brings up its own poll")
        gate.release([agent])
        await starting.value

        XCTAssertEqual(bridge.pollTask, poll)
        XCTAssertTrue(bridge.agents.isEmpty, "the old target's late reply is dropped")
    }

    // MARK: - Overlapping refreshes

    /// Refreshes overlap, and over a tunnel they can finish out of order. The
    /// one that started last describes the newer state, so a slower, older
    /// read that finishes after it must not paint over it.
    func testOlderRefreshFinishingLastIsDropped() async throws {
        let older = HerdrAgent(status: "working", paneID: "reentrancy:older")
        let newer = HerdrAgent(status: "blocked", paneID: "reentrancy:newer")
        // No poll may slip a read of its own in between the two.
        var config = BridgeConfig()
        config.pollInterval = 3600
        bridge = BridgeController(config: config)
        bridge.sshPath = "/usr/bin/false"
        await bridge.useEmulator(true)
        bridge.listAgents = { [] }
        await bridge.start()

        let gate = Gate()
        bridge.listAgents = { try await gate.hold() }
        let first = Task { await bridge.forceRepaint() }
        try await waitUntil("first agent.list in flight") { gate.heldCount == 1 }
        let second = Task { await bridge.forceRepaint() }
        try await waitUntil("second agent.list in flight") { gate.heldCount == 2 }

        gate.release(call: 1, with: [newer])
        await second.value
        XCTAssertEqual(bridge.agents, [newer])
        gate.release(call: 0, with: [older])
        await first.value

        XCTAssertEqual(bridge.agents, [newer])
    }

    // MARK: - A switch while start() opens the device

    /// A switch while `start()` is still opening the pad must not paint
    /// before the keymap is ensured: a key that is not yet bound would take
    /// the colour in silence and stay dark.
    func testSwitchDuringDeviceOpenPaintsAfterTheKeymap() async throws {
        bridge.listAgents = { [agent] in [agent] }
        // Recorded while off; the switch back during start() is the race.
        await bridge.setTarget(remote)

        let starting = Task { await bridge.start() }
        // isRunning is set before the first await, so this is start()
        // suspended inside openDevice().
        while !bridge.isRunning { await Task.yield() }

        await bridge.setTarget(.local)
        await starting.value

        let pad = try XCTUnwrap(bridge.emulator)
        let keymapWritten = try XCTUnwrap(
            pad.traffic.firstIndex { $0.hasPrefix("fs.write keymap.json") },
            "a stock pad gets its keymap written"
        )
        let firstPaint = pad.traffic.firstIndex { $0.hasPrefix(OAI.methodThreads) }
        XCTAssertNotNil(firstPaint)
        if let firstPaint {
            XCTAssertGreaterThan(firstPaint, keymapWritten, "\(pad.traffic)")
        }
        XCTAssertEqual(bridge.link, .local)
        XCTAssertTrue(pad.keys[Pad.agentKeyIDs[0]]?.isLit ?? false, "the agent's key lights")
    }

    // MARK: - Retrying a failed link

    /// The panel's Retry: a failed tunnel goes straight back to connecting,
    /// instead of after its backoff (or, for a permanent failure, never).
    func testReconnectRetriesAFailedLinkAtOnce() async throws {
        bridge.listAgents = { [] }
        await bridge.setTarget(remote)
        await bridge.start()
        try await waitUntil("the tunnel fails") {
            if case .failed = self.bridge.link { return true } else { return false }
        }

        bridge.reconnect()
        XCTAssertEqual(bridge.link, .connecting)
        XCTAssertNil(bridge.lastError, "a link failure is not a bridge error")
        try await waitUntil("the retry fails too") {
            if case .failed = self.bridge.link { return true } else { return false }
        }
    }

    /// A retry is for the remote the pad mirrors, and only while it is down.
    func testReconnectLeavesALocalTargetAlone() async {
        bridge.listAgents = { [] }
        await bridge.start()
        bridge.reconnect()
        XCTAssertEqual(bridge.link, .local)
    }

    // MARK: - Quitting

    /// The quit hook returns before any `Task` runs, so the lights have to be
    /// off by the time `shutdown()` returns, not on a later turn.
    ///
    /// Synchronous on purpose, like `applicationWillTerminate`: an async test
    /// body runs inside a main-queue job, where the run loop `shutdown()`
    /// spins cannot deliver the replies it waits for, so every call would sit
    /// out its timeout instead.
    func testShutdownDarkensThePadBeforeReturning() throws {
        bridge.listAgents = { [agent] in [agent] }
        Task { await bridge.start() }
        let pad = try XCTUnwrap(bridge.emulator)
        let deadline = Date().addingTimeInterval(5)
        while !(pad.keys[Pad.agentKeyIDs[0]]?.isLit ?? false), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(pad.keys[Pad.agentKeyIDs[0]]?.isLit ?? false, "the agent's key lights")

        let started = Date()
        bridge.shutdown()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "replies arrived; no call timed out")
        XCTAssertFalse(bridge.isRunning)
        XCTAssertFalse(bridge.deviceConnected)
        XCTAssertNil(bridge.pollTask)
        XCTAssertTrue(pad.keys.values.allSatisfy { !$0.isLit }, "\(pad.keys)")
        XCTAssertEqual(pad.keysZone, .dark)
        XCTAssertEqual(pad.ambientZone, .dark)
    }

    /// A repaint already past its guards when Quit arrives must not relight
    /// the pad: `shutdown()` spins the run loop, which runs that repaint's
    /// queued `callAsync` hop, and its lit `threads` call would land between
    /// the two blanking calls. Thread state paints over zone state, so the
    /// keys would stay lit.
    ///
    /// Which run-loop pass leaves the repaint waiting on that hop depends on
    /// scheduling, so each count from 0 to 3 gets its own bridge. Synchronous
    /// for the same reason as the test above.
    func testShutdownWinsOverAQueuedRepaint() throws {
        for passes in 0...3 {
            let bridge = BridgeController()
            bridge.sshPath = "/usr/bin/false"
            var n = 0
            // Alternate the status so every repaint changes the fingerprint
            // and reaches the device.
            bridge.listAgents = {
                n += 1
                return [HerdrAgent(status: n % 2 == 0 ? "working" : "blocked", paneID: "race:p1")]
            }
            Task { await bridge.useEmulator(true); await bridge.start() }
            let deadline = Date().addingTimeInterval(5)
            while !(bridge.emulator?.keys[Pad.agentKeyIDs[0]]?.isLit ?? false), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            let pad = try XCTUnwrap(bridge.emulator)
            XCTAssertTrue(pad.keys[Pad.agentKeyIDs[0]]?.isLit ?? false, "passes \(passes): the agent's key lights")

            Task { await bridge.forceRepaint() }
            for _ in 0..<passes { RunLoop.current.run(mode: .default, before: Date()) }
            bridge.shutdown()
            // Let anything left over drain.
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            XCTAssertFalse(
                pad.keys.values.contains { $0.isLit },
                "passes \(passes): \(pad.keys.filter { $0.value.isLit }.keys.sorted())"
            )
            XCTAssertEqual(pad.keysZone, .dark, "passes \(passes)")
            XCTAssertEqual(pad.ambientZone, .dark, "passes \(passes)")
        }
    }

    /// Switched off first, there is nothing left to darken or close.
    func testShutdownAfterStopIsHarmless() async {
        bridge.listAgents = { [] }
        await bridge.start()
        await bridge.stop()
        bridge.shutdown()
        XCTAssertFalse(bridge.isRunning)
    }

    // MARK: - Helpers

    /// Holds every `agent.list` open until the test releases it. Calls are
    /// numbered from 0 in the order they arrive, so each can be released on
    /// its own, or all at once.
    @MainActor
    private final class Gate {
        private var waiting: [Int: CheckedContinuation<[HerdrAgent], Error>] = [:]
        private var calls = 0
        var isHolding: Bool { !waiting.isEmpty }
        var heldCount: Int { waiting.count }

        func hold() async throws -> [HerdrAgent] {
            try await withCheckedThrowingContinuation { continuation in
                waiting[calls] = continuation
                calls += 1
            }
        }

        func release(call: Int, with agents: [HerdrAgent]) {
            waiting.removeValue(forKey: call)?.resume(returning: agents)
        }

        func release(_ agents: [HerdrAgent]) {
            waiting.values.forEach { $0.resume(returning: agents) }
            waiting.removeAll()
        }
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
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private struct TimedOut: Error {}
}
