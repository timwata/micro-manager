import Darwin
import XCTest
@testable import WLKit

/// Scans the IORegistry for the other processes holding a connected pad.
/// Skipped when no pad is present or the test runner has no Input Monitoring
/// grant, like `LiveDeviceTests`.
///
/// Run it while another client is open (the installed MicroManager.app, the
/// Inspector, Work Louder's Input app) and read the printed scan: that client
/// should be listed by name, and this test process never.
final class LiveDeviceClientsTests: XCTestCase {

    private func connected() throws -> WLDevice {
        let device = WLDevice()
        do {
            try device.connect()
        } catch {
            throw XCTSkip("no pad: \(error.localizedDescription)")
        }
        return device
    }

    func testScanListsOthersButNeverThisProcess() throws {
        let device = try connected()
        defer { device.disconnect(reason: nil) }

        let started = DispatchTime.now()
        let scan = device.otherClients()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        print("transport: \(device.info?.transport ?? "?"), usage page: \(device.info?.usagePage ?? 0)")
        print("scan (\(String(format: "%.2f", elapsed)) ms, first): \(scan)")

        // Only a dedicated vendor interface (USB) is authoritative; a device
        // that carries the keyboard too (Bluetooth) is advisory.
        let vendorInterface = device.info?.usagePage == WLDevice.vendorUsagePage
        let clients: [HIDClient]
        switch scan {
        case .unavailable:
            return XCTFail("a connected pad must be scannable")
        case .authoritative(let list):
            XCTAssertTrue(vendorInterface, "authoritative on a shared keyboard device")
            clients = list
        case .advisory(let list):
            XCTAssertFalse(vendorInterface, "advisory on the dedicated vendor interface")
            clients = list
        }
        XCTAssertFalse(clients.contains { $0.pid == getpid() }, "this process listed itself")
        XCTAssertEqual(Set(clients.map(\.pid)).count, clients.count, "a pid listed twice")
    }

    /// Every `io_object_t` from the walk is a Mach send right. A missed
    /// release does not show up in `leaks` (it is a kernel reference, not a
    /// heap block), but it does in this task's send-right count.
    func testRepeatedScansReleaseEveryRegistryObject() throws {
        let device = try connected()
        defer { device.disconnect(reason: nil) }
        _ = device.otherClients()   // warm up caches (NSRunningApplication)

        let runs = 1_000
        let before = try sendRightReferences()
        let started = DispatchTime.now()
        for _ in 0..<runs { _ = device.otherClients() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        let after = try sendRightReferences()

        print("\(runs) scans: \(String(format: "%.3f", elapsed / Double(runs))) ms each, send rights \(before) → \(after)")
        // Each scan takes at least an iterator and one client per process
        // holding the pad (this one included), so a leak grows by thousands.
        XCTAssertLessThan(after - before, 100, "registry objects leaked")
    }

    /// The sum of user references on every send right this task holds.
    private func sendRightReferences() throws -> Int {
        var names: mach_port_name_array_t?
        var namesCount: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var typesCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount) == KERN_SUCCESS,
              let names, let types
        else { throw XCTSkip("mach_port_names failed") }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: names),
                          vm_size_t(namesCount) * vm_size_t(MemoryLayout<mach_port_name_t>.size))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: types),
                          vm_size_t(typesCount) * vm_size_t(MemoryLayout<mach_port_type_t>.size))
        }

        // MACH_PORT_TYPE_SEND is a function-like macro Swift cannot import.
        let sendType: mach_port_type_t = 1 << (MACH_PORT_RIGHT_SEND + 16)
        var total = 0
        for i in 0..<Int(namesCount) where types[i] & sendType != 0 {
            var refs: mach_port_urefs_t = 0
            if mach_port_get_refs(mach_task_self_, names[i], MACH_PORT_RIGHT_SEND, &refs) == KERN_SUCCESS {
                total += Int(refs)
            }
        }
        return total
    }
}
