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

    // MARK: - Registry scan

    private let inspector = HIDClient(pid: 4242, name: "Inspector")
    /// What the stubbed scan returns next, and how often it was asked.
    private var scanResult: HIDClientScan = .unavailable
    private var scans = 0
    private var clock: TimeInterval = 1000

    /// Starts the bridge with the registry scan and the clock stubbed out.
    private func startScanned(_ initial: HIDClientScan = .unavailable) async {
        scanResult = initial
        bridge.scanClients = { [unowned self] in
            self.scans += 1
            return self.scanResult
        }
        bridge.uptime = { [unowned self] in self.clock }
        await bridge.start()
    }

    /// Raises the warning by traffic alone: a foreign reply, with a scan
    /// that cannot tell (so `scanResult` must be `.unavailable`).
    private func seeTraffic() {
        precondition(scanResult == .unavailable)
        bridge.noteResponse(id: foreignID)
        // Out of the reply-scan window, for whatever the test does next.
        clock += BridgeController.replyScanInterval
    }

    /// The emulator has no registry entry, so the real scan is unavailable
    /// and nothing is named: Phase 1 behaviour, which the tests above check.
    func testEmulatorScanIsUnavailable() async {
        await bridge.start()
        XCTAssertEqual(bridge.scanClients(), .unavailable)
        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])
    }

    /// Row 1: an unavailable scan leaves the replies to decide, and does not
    /// clear what they raised.
    func testUnavailableScanFollowsTraffic() async {
        await startScanned()
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)

        seeTraffic()
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])
    }

    /// Row 2: nobody else on a dedicated vendor interface clears the
    /// warning, and forgets the replies behind it.
    func testAuthoritativeEmptyClearsTraffic() async {
        await startScanned()
        seeTraffic()
        XCTAssertTrue(bridge.contendingClient)

        scanResult = .authoritative([])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)

        scanResult = .unavailable
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient, "the replies were forgotten, not just outvoted")
    }

    /// Row 3: anyone else on the vendor interface raises it with no traffic
    /// at all, and is named.
    func testAuthoritativeOthersRaise() async {
        await startScanned()
        XCTAssertFalse(bridge.contendingClient)

        scanResult = .authoritative([inspector])
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])

        // And it goes once the other app has.
        scanResult = .authoritative([])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])
    }

    /// Row 4: an advisory empty list clears the warning and the replies.
    func testAdvisoryEmptyClearsTraffic() async {
        await startScanned()
        seeTraffic()

        scanResult = .advisory([])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)

        scanResult = .unavailable
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient, "the replies were forgotten, not just outvoted")
    }

    /// Row 5: on a pad that also carries the keyboard, others may only be
    /// listening for keys: the list names them but cannot raise the warning.
    func testAdvisoryOthersOnlyLabel() async {
        await startScanned(.advisory([inspector]))
        XCTAssertFalse(bridge.contendingClient, "an advisory list alone does not raise it")
        XCTAssertEqual(bridge.contenders, [inspector])

        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])
    }

    /// A foreign reply scans to name its sender, but at most once a second.
    /// A reply inside the window still raises the warning.
    func testReplyScansAreLimitedToOnePerSecond() async {
        await startScanned()
        let afterStart = scans
        XCTAssertEqual(afterStart, 1, "openDevice() scanned once")

        bridge.noteResponse(id: foreignID)
        XCTAssertEqual(scans, afterStart + 1, "the first foreign reply scans")

        clock += BridgeController.replyScanInterval * 0.9
        bridge.noteResponse(id: foreignID)
        XCTAssertEqual(scans, afterStart + 1, "a second reply within the second does not")
        XCTAssertTrue(bridge.contendingClient)

        // The panel's scan neither counts towards the limit nor is held by it.
        bridge.scanContention()
        XCTAssertEqual(scans, afterStart + 2)

        clock += BridgeController.replyScanInterval * 0.1
        bridge.noteResponse(id: foreignID)
        XCTAssertEqual(scans, afterStart + 3, "a reply a second after the last reply scan scans again")

        // Replies to our own calls never scan.
        await bridge.forceRepaint()
        XCTAssertEqual(scans, afterStart + 3)
    }

    /// The reply-triggered scan is what puts a name on a client first seen
    /// by its traffic.
    func testForeignReplyNamesTheSender() async {
        await startScanned()
        scanResult = .authoritative([inspector])
        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])
    }

    /// A client already holding the pad is seen as the bridge opens it.
    func testOpenScans() async {
        await startScanned(.authoritative([inspector]))
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])
    }

    /// Who held a pad that has gone says nothing about the pad that comes
    /// back: an unplug drops the scan, and the reopen scans afresh.
    func testUnplugDropsTheScan() async {
        await startScanned(.authoritative([inspector]))
        XCTAssertTrue(bridge.contendingClient)

        bridge.device.disconnect(reason: "unplugged")
        XCTAssertFalse(bridge.deviceConnected)
        XCTAssertFalse(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])
    }

    /// Recheck forgets the replies and rescans: an empty authoritative list
    /// clears the warning, and one that still has the other app keeps it up.
    /// It repaints either way.
    func testRecheckScans() async throws {
        await startScanned()
        seeTraffic()
        let before = scans

        scanResult = .authoritative([inspector])
        await bridge.recheckContention()
        XCTAssertEqual(scans, before + 1)
        XCTAssertTrue(bridge.contendingClient, "the other app is still there")
        XCTAssertEqual(bridge.contenders, [inspector])

        scanResult = .authoritative([])
        await bridge.recheckContention()
        XCTAssertFalse(bridge.contendingClient)

        scanResult = .unavailable
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient, "the replies seen earlier stay forgotten")
    }

    /// Switched off, nothing is scanned and nothing is named, whatever the
    /// registry would say.
    func testOffBridgeDoesNotScan() async {
        await startScanned(.authoritative([inspector]))
        XCTAssertTrue(bridge.contendingClient)

        await bridge.stop()
        XCTAssertFalse(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])

        let before = scans
        bridge.scanContention()
        await bridge.recheckContention()
        XCTAssertEqual(scans, before)
        XCTAssertFalse(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])
    }
}
