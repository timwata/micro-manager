import XCTest
@testable import WLKit

private extension BridgeController {
    /// A reply to a lighting call, which the firmware answers {"ok":1}.
    func noteResponse(id: Int) { noteResponse(id: id, result: ["ok": 1], error: nil) }
}

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
    private let input = HIDClient(pid: 5151, name: "Input")
    private let relaunched = HIDClient(pid: 4343, name: "Inspector")
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

    /// A foreign reply while the registry lists `clients`; the reply scans,
    /// and the clock leaves the window for whatever the test does next.
    private func reply(while clients: [HIDClient]) {
        scanResult = .authoritative(clients)
        bridge.noteResponse(id: foreignID)
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

    /// An unavailable scan leaves the replies to decide, and does not clear
    /// what they raised.
    func testUnavailableScanFollowsTraffic() async {
        await startScanned()
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)

        seeTraffic()
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])
    }

    /// Nobody else on the pad clears the warning, and forgets the replies
    /// behind it.
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

    /// The same over Bluetooth.
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

    /// The reported bug: Input running in the background holds the vendor
    /// interface but sends nothing, and raised the warning on every launch
    /// until Recheck. Holding the pad alone never raises it, over USB or
    /// Bluetooth, at open, on a later scan, or after an off/on toggle; the
    /// holder is still named should the warning come up.
    func testHoldingThePadAloneNeverRaises() async {
        await startScanned(.authoritative([input]))
        XCTAssertFalse(bridge.contendingClient, "a holder seen as the pad opens")
        XCTAssertEqual(bridge.contenders, [input])

        scanResult = .authoritative([input, inspector])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient, "a holder that arrives later")

        scanResult = .advisory([input])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient, "over Bluetooth")

        scanResult = .authoritative([input])
        await bridge.stop()
        await bridge.start()
        XCTAssertFalse(bridge.contendingClient, "after an off/on toggle")
    }

    /// The user check: with Input quietly holding the pad, the Inspector
    /// opens and sends. The warning names the Inspector alone and clears by
    /// itself once a scan no longer lists it, though Input is still there.
    func testAReplyIsLaidAtTheNewcomer() async {
        await startScanned(.authoritative([input]))

        reply(while: [input, inspector])
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])

        scanResult = .authoritative([input, inspector])
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient, "the Inspector is still there")

        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient, "the Inspector has quit")
        XCTAssertEqual(bridge.contenders, [input])
    }

    /// The second report: Input announces the frontmost app
    /// (`host.focused_app`) on every app switch, including the one when the
    /// Inspector quits, and the firmware answers that with a bare null. Such
    /// a reply neither raises the warning nor scans, so it cannot blame Input
    /// once the Inspector has gone.
    func testANullReplyIsNotAboutTheLighting() async {
        await startScanned(.authoritative([input]))
        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [inspector])

        scanResult = .authoritative([input])
        let before = scans
        bridge.noteResponse(id: foreignID, result: NSNull(), error: nil)
        bridge.noteResponse(id: foreignID, result: nil, error: nil)
        XCTAssertEqual(scans, before, "a null reply does not scan")
        XCTAssertTrue(bridge.contendingClient, "nor does it clear what the Inspector raised")

        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)
        bridge.noteResponse(id: foreignID, result: NSNull(), error: nil)
        XCTAssertFalse(bridge.contendingClient, "Input's focus announcement")
    }

    /// The device's reply callback hands the result on, so the filter sees
    /// what the pad answered.
    func testTheDeviceReplyCarriesItsResult() async {
        await bridge.start()
        bridge.device.onResponse?(foreignID, NSNull(), nil)
        XCTAssertFalse(bridge.contendingClient)
        bridge.device.onResponse?(foreignID, ["ok": 1], nil)
        XCTAssertTrue(bridge.contendingClient)
    }

    /// The emulator answers `host.focused_app` the way the device does.
    func testEmulatorAnswersFocusedAppWithNull() throws {
        let pad = PadEmulator()
        let (result, error) = pad.handle("host.focused_app", params: ["name": "Finder", "bundle_id": "com.apple.finder"])
        XCTAssertNil(error)
        XCTAssertTrue(result is NSNull)
    }

    /// An error reply still counts: whoever got it is talking to the pad,
    /// and nothing says it was not about the lighting.
    func testAnErrorReplyStillRaises() async {
        await startScanned(.authoritative([input]))
        scanResult = .authoritative([input, inspector])
        bridge.noteResponse(id: foreignID, result: nil, error: "Method not found")
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])
    }

    /// A null reply to one of our own calls still ends that call: had the
    /// id stayed in flight, another client's reply under the same id would
    /// later be taken for ours.
    func testOurOwnNullReplyIsStillConsumed() async {
        await bridge.start()
        bridge.noteIssued(id: 500)
        bridge.noteResponse(id: 500, result: NSNull(), error: nil)
        bridge.noteResponse(id: 500)
        XCTAssertTrue(bridge.contendingClient)
    }

    /// The third report: after the Mac wakes and the screen is unlocked,
    /// "Also driving this pad: input" until Recheck. Input reconnects to its
    /// devices on every unlock — its client leaves the registry and comes
    /// back — and asks for `device.status` (or `sys.version`) a second
    /// later. Those replies are objects, not the lighting's {"ok":1}, so
    /// they neither raise the warning nor scan, and Input stays quiet.
    func testInputReconnectingAfterAnUnlockDoesNotRaise() async {
        await startScanned(.authoritative([input]))
        let pad = PadEmulator()

        scanResult = .authoritative([])
        bridge.scanContention()             // the panel opens during the gap
        scanResult = .authoritative([input])
        bridge.scanContention()

        let before = scans
        for method in ["device.status", "sys.version"] {
            let (result, error) = pad.handle(method, params: nil)
            bridge.noteResponse(id: foreignID, result: result, error: error)
            XCTAssertFalse(bridge.contendingClient, method)
        }
        XCTAssertEqual(scans, before, "a reply to a query does not scan")

        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [inspector], "Input is still taken for quiet")
    }

    /// Which of the emulator's answers count as a fight over the colours:
    /// the lighting calls and the keymap write (all {"ok":1}) and errors do;
    /// the queries and the focus announcement do not.
    func testOnlyLightingAndWriteRepliesCount() {
        let pad = PadEmulator()
        let counted: [(String, Any?)] = [
            (OAI.methodThreads, OAI.threadsParams([])),
            (OAI.methodRGBConfig, nil),
            ("fs.write", ["file": "keymap.json", "data": "{}"]),
            ("no.such.method", nil),
        ]
        let ignored: [(String, Any?)] = [
            ("sys.version", nil),
            ("device.status", nil),
            ("fs.list", nil),
            ("fs.read", ["file": "keymap.json"]),
            ("host.focused_app", ["name": "Finder"]),
        ]
        for (method, params) in counted {
            let (result, error) = pad.handle(method, params: params)
            XCTAssertTrue(BridgeController.isAboutTheLighting(result: result, error: error), method)
        }
        for (method, params) in ignored {
            let (result, error) = pad.handle(method, params: params)
            XCTAssertFalse(BridgeController.isAboutTheLighting(result: result, error: error), method)
        }
    }

    /// A quiet holder that starts sending is all there is to blame, and the
    /// warning stays until it has gone.
    func testAQuietHolderThatSendsIsBlamed() async {
        await startScanned(.authoritative([input]))

        reply(while: [input])
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [input])

        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient)

        scanResult = .authoritative([])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)
    }

    /// A later reply adds to whom the earlier ones were laid at; it does
    /// not replace them.
    func testSuspectsAddUp() async {
        await startScanned(.authoritative([input]))
        reply(while: [input])
        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [input, inspector])

        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient, "Input sent the first reply")
    }

    /// When every holder is quiet, a reply is laid at all of them, so the
    /// warning outlives the sender's quitting until Recheck. They are not
    /// marked for good, though: a later newcomer's reply is still laid at
    /// the newcomer alone.
    func testAReplyFromTheQuietIsLaidAtAllOfThem() async {
        await startScanned(.authoritative([input, inspector]))

        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [input, inspector])

        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient, "Input may have sent it")

        await bridge.recheckContention()
        XCTAssertFalse(bridge.contendingClient)

        reply(while: [input, relaunched])
        XCTAssertEqual(bridge.contenders, [relaunched])
        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)
    }

    /// Recheck with the Inspector still open clears the warning, and a scan
    /// does not then take the Inspector for a quiet holder: its next reply
    /// is laid at it alone, and the warning clears once it has quit.
    func testRecheckKeepsANewcomerSuspected() async {
        await startScanned(.authoritative([input]))
        reply(while: [input, inspector])

        await bridge.recheckContention()
        XCTAssertFalse(bridge.contendingClient)
        bridge.scanContention()

        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [inspector])
        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)
    }

    /// A reply no scan could attribute stays until a scan finds nobody else:
    /// any holder may have sent it.
    func testAnUnattributedReplyNeedsAnEmptyScan() async {
        await startScanned(.authoritative([input]))
        scanResult = .unavailable
        seeTraffic()

        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient, "even the quiet Input may have sent it")
        XCTAssertEqual(bridge.contenders, [input])

        reply(while: [input, inspector])
        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient, "an attributed reply does not undo an unattributed one")

        scanResult = .authoritative([])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)
    }

    /// An unavailable scan says nothing about who left: it keeps the
    /// suspects and the quiet holders alike.
    func testUnavailableScanKeepsWhatItKnew() async {
        await startScanned(.authoritative([input]))
        scanResult = .unavailable
        bridge.scanContention()

        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [inspector], "Input is still quiet")

        scanResult = .unavailable
        bridge.scanContention()
        XCTAssertTrue(bridge.contendingClient, "the Inspector is still suspected")

        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)
    }

    /// A holder that leaves is no longer quiet: back again, it is a newcomer
    /// to blame.
    func testAHolderThatLeftIsNoLongerQuiet() async {
        await startScanned(.authoritative([input]))
        scanResult = .authoritative([])
        bridge.scanContention()

        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [input, inspector])
    }

    /// A suspect that leaves is forgotten: a process back under its pid
    /// (pids are reused) and holding the pad quietly is quiet like any other.
    func testASuspectThatLeftIsForgotten() async {
        await startScanned(.authoritative([input]))
        reply(while: [input, inspector])
        scanResult = .authoritative([input])
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient)

        scanResult = .authoritative([input, inspector])
        bridge.scanContention()
        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [input, inspector])
    }

    /// Switching off and on forgets who was suspected: the reopen takes
    /// every holder for quiet.
    func testStopForgetsTheSuspects() async {
        await startScanned(.authoritative([input]))
        reply(while: [input, inspector])
        await bridge.recheckContention()

        await bridge.stop()
        await bridge.start()
        reply(while: [input, inspector])
        XCTAssertEqual(bridge.contenders, [input, inspector])
    }

    /// A foreign reply scans to see who may have sent it, but at most once
    /// a second. A reply inside the window still raises the warning.
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
    /// by its traffic, over USB and Bluetooth alike.
    func testForeignReplyNamesTheSender() async {
        await startScanned()
        scanResult = .authoritative([inspector])
        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])

        await bridge.stop()
        await startScanned()
        scanResult = .advisory([inspector])
        bridge.noteResponse(id: foreignID)
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector])
    }

    /// Who held a pad that has gone says nothing about the pad that comes
    /// back: an unplug drops the names, and the reopen scans afresh. The
    /// replies seen stay, as they do without a scan.
    func testUnplugDropsTheScan() async {
        await startScanned(.authoritative([input]))
        reply(while: [input, inspector])

        bridge.device.disconnect(reason: "unplugged")
        XCTAssertFalse(bridge.deviceConnected)
        XCTAssertTrue(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [])
    }

    /// Recheck forgets the replies and rescans, whoever is still there, and
    /// repaints (`testRecheckClearsAndRepaints`).
    func testRecheckScans() async throws {
        await startScanned()
        seeTraffic()
        let before = scans

        scanResult = .authoritative([inspector])
        await bridge.recheckContention()
        XCTAssertEqual(scans, before + 1)
        XCTAssertFalse(bridge.contendingClient)
        XCTAssertEqual(bridge.contenders, [inspector], "and still listed")

        scanResult = .unavailable
        bridge.scanContention()
        XCTAssertFalse(bridge.contendingClient, "the replies seen earlier stay forgotten")
    }

    /// Switched off, nothing is scanned and nothing is named, whatever the
    /// registry would say.
    func testOffBridgeDoesNotScan() async {
        await startScanned(.authoritative([input]))
        reply(while: [input, inspector])
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
