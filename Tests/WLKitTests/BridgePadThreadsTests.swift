import XCTest
@testable import WLKit

/// What the bridge paints in local and remote mode. The only difference a
/// remote target may make is Stack and Land going dark: their `but` runs on
/// this Mac, in a working directory that lives on the other one.
final class BridgePadThreadsTests: XCTestCase {

    private let agents = [
        HerdrAgent(status: "working", paneID: "w1:p1"),
        HerdrAgent(status: "blocked", paneID: "w1:p2"),
    ]

    private func threads(
        isRemote: Bool,
        stackPanelOpen: Bool = false,
        landPanelOpen: Bool = false,
        voiceActive: Bool = false
    ) -> [OAI.Thread] {
        BridgeController.padThreads(
            agents: agents,
            keyBindings: KeyBindings(),
            voiceActive: voiceActive,
            stackPanelOpen: stackPanelOpen,
            landPanelOpen: landPanelOpen,
            isRemote: isRemote,
            BridgeConfig()
        )
    }

    private func thread(_ id: Int, in threads: [OAI.Thread]) -> OAI.Thread? {
        threads.first { $0.id == id }
    }

    func testLocalLightsStackAndLand() {
        let local = threads(isRemote: false)
        XCTAssertEqual(thread(Pad.stackKeyID, in: local), StatusMapper.stackThread(open: false))
        XCTAssertEqual(thread(Pad.landKeyID, in: local), StatusMapper.landThread(open: false))
    }

    func testLocalReflectsOpenPanels() {
        let local = threads(isRemote: false, stackPanelOpen: true, landPanelOpen: true)
        XCTAssertEqual(thread(Pad.stackKeyID, in: local), StatusMapper.stackThread(open: true))
        XCTAssertEqual(thread(Pad.landKeyID, in: local), StatusMapper.landThread(open: true))
    }

    func testRemoteDarkensStackAndLand() {
        // Even with a panel somehow open, a remote target never lights them.
        let remote = threads(isRemote: true, stackPanelOpen: true, landPanelOpen: true)
        let dark = { (id: Int) in OAI.Thread(id: id, brightness: 0, effect: .off) }
        XCTAssertEqual(thread(Pad.stackKeyID, in: remote), dark(Pad.stackKeyID))
        XCTAssertEqual(thread(Pad.landKeyID, in: remote), dark(Pad.landKeyID))
    }

    func testRemoteChangesNothingElse() {
        for voiceActive in [false, true] {
            let gated: Set<Int> = [Pad.stackKeyID, Pad.landKeyID]
            let local = threads(isRemote: false, voiceActive: voiceActive).filter { !gated.contains($0.id) }
            let remote = threads(isRemote: true, voiceActive: voiceActive).filter { !gated.contains($0.id) }
            XCTAssertEqual(local, remote)
        }
    }

    func testEveryBoundKeyIsPaintedOnceInBothModes() {
        for isRemote in [false, true] {
            let ids = threads(isRemote: isRemote).map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "duplicate thread ids (remote: \(isRemote))")
            XCTAssertEqual(Set(ids), Set(Pad.boundKeyIDs), "remote: \(isRemote)")
        }
    }

    func testAgentKeysFollowTheAgents() {
        let painted = threads(isRemote: true)
        XCTAssertEqual(Array(painted.prefix(Pad.agentKeyIDs.count)), StatusMapper.threads(for: agents))
    }
}

/// `setTarget` and key gating without a device: the bridge is never started,
/// so nothing here opens HID or launches ssh.
@MainActor
final class BridgeTargetTests: XCTestCase {

    private let box = HerdrRemote(name: "box", host: "box")

    func testSwitchingWhileOffOnlyRecordsTheTarget() async {
        let bridge = BridgeController()
        await bridge.setTarget(.remote(box))
        XCTAssertEqual(bridge.target, .remote(box))
        XCTAssertTrue(bridge.isRemote)
        // Nothing was brought up, so there is no link to report.
        XCTAssertEqual(bridge.link, .local)
        XCTAssertFalse(bridge.isRunning)

        await bridge.setTarget(.local)
        XCTAssertEqual(bridge.target, .local)
        XCTAssertFalse(bridge.isRemote)
    }

    func testRemoteStackAndLandPressesOnlyExplain() async {
        let bridge = BridgeController()
        var opened: [String] = []
        bridge.onStackKey = { opened.append("stack") }
        bridge.onLandKey = { opened.append("land") }
        await bridge.setTarget(.remote(box))

        bridge.handleKeyPress(Pad.stackKeyID)
        bridge.handleKeyPress(Pad.landKeyID)
        XCTAssertEqual(opened, [])
        XCTAssertEqual(bridge.lastError, "Stack and Land are not available for a remote Herdr.")
    }

    func testLocalStackAndLandPressesStillOpenTheirPanels() {
        let bridge = BridgeController()
        var opened: [String] = []
        bridge.onStackKey = { opened.append("stack") }
        bridge.onLandKey = { opened.append("land") }

        bridge.handleKeyPress(Pad.stackKeyID)
        bridge.handleKeyPress(Pad.landKeyID)
        XCTAssertEqual(opened, ["stack", "land"])
        XCTAssertNil(bridge.lastError)
    }

    func testAKeyInterceptStillWinsWhenRemote() async {
        let bridge = BridgeController()
        bridge.onKeyIntercept = { _ in true }
        await bridge.setTarget(.remote(box))
        bridge.handleKeyPress(Pad.stackKeyID)
        XCTAssertNil(bridge.lastError)
    }
}
