import XCTest
@testable import WLKit

/// The "another app is also driving this pad" warning, on the built-in
/// virtual pad with `agent.list` stubbed out, so these run everywhere.
///
/// Another client is played by `noteResponse(id:)` with an id the bridge
/// can never issue: firmware ids run 1...998, so 999 is always foreign.
@MainActor
final class BridgeContentionTests: XCTestCase {

    private var bridge: BridgeController!
    private let agent = HerdrAgent(status: "working", paneID: "contention:p1")
    private let foreignID = 999

    override func setUp() async throws {
        try await super.setUp()
        // No poll may slip a repaint of its own into the timing tests.
        var config = BridgeConfig()
        config.pollInterval = 3600
        bridge = BridgeController(config: config)
        bridge.sshPath = "/usr/bin/false"
        await bridge.useEmulator(true)
        bridge.listAgents = { [agent] in [agent] }
    }

    override func tearDown() async throws {
        await bridge?.stop()
        bridge = nil
        HerdrClient.setSocketPath(nil)
        try await super.tearDown()
    }

    /// Only a reply to an id the bridge never sent counts. Starting (device
    /// open, keymap, first paint) and repainting are all our own calls.
    func testOnlyAForeignReplyRaisesTheWarning() async {
        await bridge.start()
        XCTAssertFalse(bridge.contendingClient, "start's own replies")

        await bridge.forceRepaint()
        XCTAssertFalse(bridge.contendingClient, "a repaint's own replies")

        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient)
    }

    /// Recheck clears the warning and puts our colours back over whatever
    /// the other app painted. It proves nothing by itself, so the next
    /// foreign reply raises the warning again.
    func testRecheckClearsAndRepaints() async throws {
        await bridge.start()
        let pad = try XCTUnwrap(bridge.emulator)
        let key = Pad.agentKeyIDs[0]
        XCTAssertTrue(pad.keys[key]?.isLit ?? false, "the agent's key lights")

        // The other app turns our key off, and its reply is seen.
        _ = pad.handle(OAI.methodThreads, params: OAI.threadsParams([
            OAI.Thread(id: key, brightness: 0, effect: .off),
        ]))
        bridge.noteResponse(id: foreignID)
        XCTAssertFalse(pad.keys[key]?.isLit ?? true)
        XCTAssertTrue(bridge.contendingClient)

        await bridge.recheckContention()
        XCTAssertFalse(bridge.contendingClient)
        XCTAssertTrue(pad.keys[key]?.isLit ?? false, "the recheck repainted the key")

        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient, "a foreign reply after a recheck raises it again")
    }

    /// Switched off, the bridge drives nothing, so there is nothing to fight
    /// over — and a recheck while off just clears.
    func testStopClearsTheWarning() async {
        await bridge.start()
        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient)

        await bridge.stop()
        XCTAssertFalse(bridge.contendingClient)

        bridge.noteResponse(id: foreignID)
        await bridge.recheckContention()
        XCTAssertFalse(bridge.contendingClient)
        XCTAssertFalse(bridge.isRunning, "a recheck does not switch the bridge on")
    }

    /// A recheck must not forget the ids still in flight: the reply to a
    /// call sent just before it would then look foreign and raise the
    /// warning again at once. The id is put in flight by hand, so the
    /// recheck always lands between the send and the reply.
    func testRecheckKeepsInFlightIDs() async {
        await bridge.start()
        bridge.noteIssued(id: 500)          // one of our calls, reply not yet in
        await bridge.recheckContention()
        bridge.noteResponse(id: 500)        // its reply lands after the recheck
        XCTAssertFalse(bridge.contendingClient)
    }
}
