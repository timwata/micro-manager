import XCTest
@testable import WLKit

/// Uses a real keymap read off a device, so the double-encoded envelope and the
/// layer layout are exercised against genuine data rather than a fixture I
/// invented to match my own parser. It is the stock F-key map, straight from
/// `fs.read` — keep it that way, because half these tests assert on what an
/// *unmodified* device looks like.
final class KeymapManagerTests: XCTestCase {

    private func backupKeymap() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WLKitTests
            .appendingPathComponent("Fixtures/stock-keymap.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try KeymapManager.parse(raw)
    }

    func testParsesTheDoubleEncodedEnvelope() throws {
        let config = try backupKeymap()
        XCTAssertNotNil(config["profiles"], "inner JSON string must be decoded")
    }

    func testStockKeymapIsNotAgentBound() throws {
        let config = try backupKeymap()
        XCTAssertFalse(
            KeymapManager.isAgentKeymapApplied(config),
            "the backup is the stock F-key map"
        )
        XCTAssertEqual(KeymapManager.activeLayerKeymap(config)?[0], ["KC_F13", "KC_F14"])
    }

    /// The whole pad is managed now — every key must carry its own AG code,
    /// each key's code matching its index so lights and presses line up.
    func testApplyingBindsEveryKeyToItsOwnCode() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next))

        let keymap = try XCTUnwrap(KeymapManager.activeLayerKeymap(next))
        XCTAssertEqual(Set(Pad.boundKeyIDs).count, Pad.keyCount, "every key is managed")
        for key in Pad.boundKeyIDs {
            let at = try XCTUnwrap(Pad.position(of: key))
            XCTAssertEqual(keymap[at.row][at.column], KeymapManager.agCodes[key])
        }
    }

    /// A pad bound the old way — six agent keys, stack key still on its F-key —
    /// has to report as *not* applied, or the rebind never happens.
    func testAgentOnlyKeymapIsNotConsideredApplied() throws {
        var config = try backupKeymap()
        var profiles = try XCTUnwrap(config["profiles"] as? [[String: Any]])
        var layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        var layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        var keymap = try XCTUnwrap(layout["keymap"] as? [[String]])
        keymap[0] = ["KV_OAI_AG00", "KV_OAI_AG01"]
        keymap[1] = ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"]
        layout["keymap"] = keymap
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles

        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(try KeymapManager.withAgentKeymap(config)))
    }

    /// The dial's rotations become AG codes; its press keeps its keycode.
    func testApplyingBindsTheDialButNotItsPress() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let original = try XCTUnwrap(KeymapManager.activeLayerLayout(config))
        let layout = try XCTUnwrap(KeymapManager.activeLayerLayout(next))
        let dial = try XCTUnwrap((layout["encoders"] as? [[String]])?.first)
        let originalDial = try XCTUnwrap((original["encoders"] as? [[String]])?.first)
        XCTAssertEqual(dial[0], "KV_OAI_AG13")
        XCTAssertEqual(dial[1], "KV_OAI_AG14")
        XCTAssertEqual(dial[2], originalDial[2], "the press is not ours to take")
    }

    /// The joystick's four cardinal sectors become AG codes; diagonals keep
    /// whatever they had.
    func testApplyingBindsTheJoystickCardinals() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let layout = try XCTUnwrap(KeymapManager.activeLayerLayout(next))
        let joystick = try XCTUnwrap(layout["joystick"] as? [String: Any])
        let sectors = try XCTUnwrap(joystick["sectors"] as? [[String: Any]])

        var cardinals: [Double: String] = [:]
        var diagonals = 0
        for sector in sectors {
            let a1 = try XCTUnwrap(sector["a1"] as? Double)
            let a2 = try XCTUnwrap(sector["a2"] as? Double)
            let centre = KeymapManager.sectorCentre(a1, a2)
            if let code = sector["k"] as? String, code.hasPrefix("KV_OAI_AG") {
                cardinals[centre] = code
            } else {
                diagonals += 1
            }
        }
        XCTAssertEqual(cardinals[0.25], "KV_OAI_AG15")
        XCTAssertEqual(cardinals[0.50], "KV_OAI_AG16")
        XCTAssertEqual(cardinals[0.75], "KV_OAI_AG17")
        XCTAssertEqual(cardinals[0.00], "KV_OAI_AG18")
        XCTAssertEqual(diagonals, 4, "the diagonal sectors keep their keycodes")
    }

    func testApplyingIsIdempotent() throws {
        let once = try KeymapManager.withAgentKeymap(try backupKeymap())
        let twice = try KeymapManager.withAgentKeymap(once)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(twice))
    }

    func testEverythingElseSurvivesTheRewrite() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let profiles = try XCTUnwrap(next["profiles"] as? [[String: Any]])
        let layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 3, "the other layers are preserved")

        let layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        XCTAssertNotNil(layout["encoders"], "encoders survive")
        XCTAssertNotNil(layout["joystick"], "joystick survives")
        XCTAssertNotNil(layers[0]["lights"], "per-layer lighting survives")
    }

    func testMalformedInputIsRejectedRatherThanSilentlyAccepted() {
        XCTAssertThrowsError(try KeymapManager.parse(["nope": 1]))
        XCTAssertThrowsError(try KeymapManager.parse(["data": "not json"]))
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied([:]))
    }

    // MARK: - Layouts with no slot for a binding

    /// The emulator's stock keymap with its active layer's layout edited.
    private func stockKeymap(editing edit: (inout [String: Any]) -> Void) throws -> [String: Any] {
        var config = PadEmulator.stockKeymap()
        var profiles = try XCTUnwrap(config["profiles"] as? [[String: Any]])
        var layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        var layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        edit(&layout)
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles
        return config
    }

    /// One layout per part `withAgentKeymap` skips but `isAgentKeymapApplied`
    /// requires: a key outside the matrix, a dial without both rotation
    /// slots, a joystick without its north sector. `unbound` is what stays
    /// without an AG code once everything else is bound.
    private func unplaceableLayouts() throws -> [(name: String, config: [String: Any], unbound: Set<Int>)] {
        [
            ("a key outside the matrix", try stockKeymap { layout in
                var keymap = layout["keymap"] as! [[String]]
                keymap[3].removeLast()
                layout["keymap"] = keymap
            }, [12]),
            ("a dial with one slot", try stockKeymap { layout in
                layout["encoders"] = [["KC_MPLY"]]
            }, [Pad.dialUpID, Pad.dialDownID]),
            ("a joystick without north", try stockKeymap { layout in
                var joystick = layout["joystick"] as! [String: Any]
                var sectors = joystick["sectors"] as! [[String: Any]]
                sectors.removeAll { $0["k"] as? String == "KI_X" }
                joystick["sectors"] = sectors
                layout["joystick"] = joystick
            }, [Pad.joyNorthID]),
        ]
    }

    func testLayoutsWithoutASlotCannotBeApplied() throws {
        for (name, config, _) in try unplaceableLayouts() {
            let next = try KeymapManager.withAgentKeymap(config)
            XCTAssertFalse(KeymapManager.isAgentKeymapApplied(next), name)
        }
    }

    /// `apply` writes a partial binding only when the rewrite changes
    /// something, and tells by `NSDictionary` equality. The config it reads
    /// back is Foundation types from `JSONSerialization`, while the rewrite
    /// goes through Swift arrays and dictionaries, so the comparison must
    /// still see a partially bound config as unchanged, and a stock one as
    /// changed.
    func testARewriteOfAPartiallyBoundLayoutIsUnchanged() throws {
        for (name, config, _) in try unplaceableLayouts() {
            let stock = try roundTrip(config)
            let once = try KeymapManager.withAgentKeymap(stock)
            XCTAssertFalse((once as NSDictionary).isEqual(to: stock), "\(name): stock is rewritten")

            let read = try roundTrip(once)
            let twice = try KeymapManager.withAgentKeymap(read)
            XCTAssertTrue((twice as NSDictionary).isEqual(to: read), "\(name): bound once is final")
        }
    }

    /// The config as a device would hand it back after a write.
    private func roundTrip(_ config: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: config)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The fs.write calls the emulator has taken, from its traffic log.
    private func writes(_ emulator: PadEmulator) -> Int {
        emulator.traffic.filter { $0.hasPrefix("fs.write") }.count
    }

    /// A layout that cannot take every binding still gets the ones it has a
    /// slot for, since those keys light, but in one write only: a write per
    /// start and per reconnect would wear the flash and fail every time.
    func testApplyBindsWhatHasASlotAndWritesItOnce() async throws {
        let all = Set(Pad.boundKeyIDs + [Pad.dialUpID, Pad.dialDownID]
                      + [Pad.joyNorthID, Pad.joyWestID, Pad.joySouthID, Pad.joyEastID])
        for (name, config, unbound) in try unplaceableLayouts() {
            let emulator = PadEmulator()
            let device = WLDevice(emulator: emulator)
            try device.connect()
            let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: config),
                                            encoding: .utf8))
            _ = try await device.callAsync("fs.write", params: ["file": "keymap.json", "data": text])
            XCTAssertEqual(writes(emulator), 1, name)
            XCTAssertEqual(emulator.bound, [], "\(name): starts on the stock F-keys")

            for attempt in ["first", "second"] {
                do {
                    _ = try await KeymapManager.apply(device)
                    XCTFail("\(name), \(attempt) apply: expected cannotApply")
                } catch KeymapManager.Failure.cannotApply {
                } catch {
                    XCTFail("\(name), \(attempt) apply: expected cannotApply, got \(error)")
                }
                XCTAssertEqual(writes(emulator), 2, "\(name), \(attempt) apply: one write in all")
                XCTAssertEqual(emulator.bound, all.subtracting(unbound),
                               "\(name), \(attempt) apply: what has a slot is bound")
            }
            device.disconnect(reason: nil)
        }
    }

    func testStockLayoutAppliesWithOneWrite() async throws {
        let emulator = PadEmulator()
        let device = WLDevice(emulator: emulator)
        try device.connect()

        let changed = try await KeymapManager.apply(device)
        XCTAssertTrue(changed)
        XCTAssertEqual(writes(emulator), 1)
        let after = try await KeymapManager.read(device)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(after))
        device.disconnect(reason: nil)
    }
}
