import XCTest
@testable import WLKit

/// The pure half of the IORegistry scan: reading `IOUserClientCreator` and
/// turning the entries into the list of other clients. The registry walk
/// itself needs a pad; see `LiveDeviceClientsTests`.
final class HIDClientScanTests: XCTestCase {

    func testParsesANormalValue() throws {
        let entry = try XCTUnwrap(WLDevice.parseCreator("pid 24859, MicroManager"))
        XCTAssertEqual(entry.pid, 24859)
        XCTAssertEqual(entry.name, "MicroManager")
    }

    /// The kernel cuts long process names, mid-word or mid-bracket.
    func testKeepsACutName() throws {
        let entry = try XCTUnwrap(WLDevice.parseCreator("pid 24023, Discord Helper ("))
        XCTAssertEqual(entry.pid, 24023)
        XCTAssertEqual(entry.name, "Discord Helper (")
    }

    /// Only the first comma separates the pid; the rest belongs to the name.
    func testKeepsCommasInTheName() throws {
        let entry = try XCTUnwrap(WLDevice.parseCreator("pid 7, Foo, Bar, Baz"))
        XCTAssertEqual(entry.pid, 7)
        XCTAssertEqual(entry.name, "Foo, Bar, Baz")
    }

    func testRejectsAnythingElse() {
        for value in [
            "pid 24859 MicroManager",   // no comma
            "pid abc, MicroManager",    // non-numeric pid
            "pid -5, MicroManager",     // not a pid either
            "pid , MicroManager",       // no pid at all
            "uid 501, MicroManager",    // another prefix, same length
            "",
        ] {
            XCTAssertNil(WLDevice.parseCreator(value), value)
        }
    }

    /// This process often holds several clients (`IOHIDManagerOpen` opens
    /// every matching interface, and a test may open the pad twice), and so
    /// may any other: neither may show up as a duplicate, nor this process
    /// at all.
    func testDropsOwnPidAndDuplicates() {
        let entries: [(pid: pid_t, name: String)] = [
            (100, "MicroManager"),
            (200, "input"),
            (100, "MicroManager"),
            (300, "Inspector"),
            (200, "input (cut"),
            (100, "MicroManager"),
        ]
        XCTAssertEqual(
            WLDevice.others(among: entries, ownPID: 100),
            [HIDClient(pid: 200, name: "input"), HIDClient(pid: 300, name: "Inspector")]
        )
        XCTAssertEqual(WLDevice.others(among: [(100, "MicroManager")], ownPID: 100), [])
        XCTAssertEqual(WLDevice.others(among: [], ownPID: 100), [])
    }

    /// The emulator has no registry entry to scan, and neither has a device
    /// that is not open.
    func testEmulatorAndClosedDeviceAreUnavailable() throws {
        let emulated = WLDevice(emulator: PadEmulator())
        XCTAssertEqual(emulated.otherClients(), .unavailable)
        try emulated.connect()
        XCTAssertEqual(emulated.otherClients(), .unavailable)
        emulated.disconnect(reason: nil)

        XCTAssertEqual(WLDevice().otherClients(), .unavailable)
    }
}
