import AppKit
import Foundation
import IOKit
import IOKit.hid

/// A process other than this one that holds the pad open.
public struct HIDClient: Equatable, Sendable {
    public let pid: pid_t
    /// From `NSRunningApplication`, else the registry's (possibly cut) name.
    public let name: String

    public init(pid: pid_t, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// Who else holds the pad open, read from the IORegistry. This is the active
/// counterpart to spotting a reply id we never issued: it also sees a client
/// that has the pad open but is not sending anything right now.
public enum HIDClientScan: Equatable, Sendable {
    /// Nothing to scan: the emulator, no open device, a registry error, or a
    /// scan that did not see this process's own client (so it did not
    /// understand the registry, and an empty list would be a guess).
    case unavailable
    /// The opened device is a dedicated vendor interface (its primary usage
    /// page is 0xFF00): every other client there can drive the lighting.
    case authoritative([HIDClient])
    /// The opened device also carries the keyboard (Bluetooth): other
    /// clients may only be listening for keys.
    case advisory([HIDClient])
}

extension WLDevice {

    /// Lists the other processes with a user client on `device`'s own
    /// registry entry.
    ///
    /// Each process that opens an IOHIDDevice gets an `IOHIDLibUserClient`
    /// child under that device's service, whose `IOUserClientCreator`
    /// property reads `"pid <n>, <process name>"`. Only the opened device is
    /// scanned, not its sibling interfaces: over USB the keyboard interface
    /// has listeners of its own (Discord, for one) that never touch the
    /// vendor protocol.
    ///
    /// `IOUserClientCreator` is not documented API, so anything unexpected
    /// drops that entry or the whole scan to `.unavailable`, never to a
    /// client that is not there. This process has just opened the device, so
    /// a walk that does not find its own client has failed (the property
    /// changed format, the clients hang elsewhere, the service is stale):
    /// that is `.unavailable` too, not an empty list.
    static func scanClients(of device: IOHIDDevice, vendorInterface: Bool) -> HIDClientScan {
        // A Get function: the service is not retained, so it is not released.
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return .unavailable }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return .unavailable
        }
        defer { IOObjectRelease(iterator) }

        var entries: [(pid: pid_t, name: String)] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOHIDLibUserClient") != 0,
                  let property = IORegistryEntryCreateCFProperty(
                    child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0),
                  let creator = property.takeRetainedValue() as? String,
                  let entry = parseCreator(creator)
            else { continue }
            entries.append(entry)
        }

        guard let others = others(among: entries, ownPID: getpid()) else { return .unavailable }
        let clients = others.map { client in
            HIDClient(
                pid: client.pid,
                name: NSRunningApplication(processIdentifier: client.pid)?.localizedName ?? client.name
            )
        }
        return vendorInterface ? .authoritative(clients) : .advisory(clients)
    }

    /// Parses an `IOUserClientCreator` value, `"pid <n>, <name>"`. The name
    /// is everything after the first comma, so a name that has commas of its
    /// own survives; the kernel may cut it short (`"Discord Helper ("`).
    /// Nil for anything else.
    static func parseCreator(_ value: String) -> (pid: pid_t, name: String)? {
        guard value.hasPrefix("pid "), let comma = value.firstIndex(of: ",") else { return nil }
        let digits = value[value.index(value.startIndex, offsetBy: 4)..<comma]
        guard let pid = pid_t(digits), pid > 0 else { return nil }
        let name = value[value.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (pid, name)
    }

    /// Drops this process (it may hold several clients: `IOHIDManagerOpen`
    /// opens every matching interface) and keeps one entry per pid, the
    /// first, in registry order. Nil when no entry is this process's: it has
    /// the device open, so the entries cannot be the whole picture.
    static func others(among entries: [(pid: pid_t, name: String)], ownPID: pid_t) -> [HIDClient]? {
        guard entries.contains(where: { $0.pid == ownPID }) else { return nil }
        var seen: Set<pid_t> = [ownPID]
        return entries.compactMap { entry in
            seen.insert(entry.pid).inserted ? HIDClient(pid: entry.pid, name: entry.name) : nil
        }
    }
}
