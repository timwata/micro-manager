import Foundation
import XCTest

/// Binds and listens on a fresh Unix socket under `$TMPDIR`, or skips the
/// test when that is not possible.
private func listenOnTemporarySocket(backlog: Int32) throws -> (path: String, listener: Int32) {
    // Short name: `sun_path` holds under 104 bytes, and $TMPDIR is long.
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("mm-\(UUID().uuidString.prefix(8)).sock")
    unlink(path)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
        path.withCString { source in
            strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
    }
    guard listener >= 0, bound == 0, listen(listener, backlog) == 0 else {
        let reason = String(cString: strerror(errno))
        if listener >= 0 { close(listener) }
        throw XCTSkip("cannot listen on \(path): \(reason)")
    }
    return (path, listener)
}

/// Reads one byte at a time up to (not including) the next newline. Nil when
/// the peer closed first.
private func readLine(from fd: Int32) -> String? {
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
        bytes.append(byte)
    }
    return nil
}

/// Just enough of a Herdr server to hold one request open: accepts a single
/// connection, reads one line, and answers only when told to.
final class FakeHerdrServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private var client: Int32 = -1

    init() throws {
        (path, listener) = try listenOnTemporarySocket(backlog: 1)
    }

    /// Returns once a client has connected and sent its first line.
    func receiveRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.client = accept(self.listener, nil, nil)
                if self.client >= 0 { _ = readLine(from: self.client) }
                continuation.resume()
            }
        }
    }

    func reply(_ line: String) {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }

    deinit {
        if client >= 0 { close(client) }
        close(listener)
        unlink(path)
    }
}

/// A server that, like Herdr, answers one request per connection, for any
/// number of connections at once: each request gets back
/// `{"id":<its id>,"result":{"token":<params.token>}}`, and the connection is
/// closed. Accepts exactly `connections` clients.
///
/// Answers inline on the accept thread: `request` writes right after it
/// connects, so no client holds it up. Clients still have to bound how many
/// connect at once: the backlog is capped at 128 by macOS, and a Unix socket
/// refuses a connect outright when it is full.
///
/// `withhold` picks tokens that get no reply: their connections are held open
/// until the server goes away, so the client's timeout is what closes them.
final class EchoHerdrServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var held: [Int32] = []

    init(connections: Int, withhold: @escaping @Sendable (Int) -> Bool = { _ in false }) throws {
        (path, listener) = try listenOnTemporarySocket(backlog: 128)
        let listener = self.listener
        Thread.detachNewThread { [weak self] in
            for _ in 0..<connections {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                if let fd = Self.answer(client, withhold: withhold) {
                    guard let self else { close(fd); return }
                    self.lock.lock(); self.held.append(fd); self.lock.unlock()
                }
            }
        }
    }

    /// Returns the connection instead of closing it when its token is
    /// withheld.
    private static func answer(_ client: Int32, withhold: (Int) -> Bool) -> Int32? {
        guard let line = readLine(from: client),
              let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let params = request["params"] as? [String: Any]
        else { close(client); return nil }
        if let token = params["token"] as? Int, withhold(token) { return client }
        defer { close(client) }
        let reply: [String: Any] = [
            "id": request["id"] ?? NSNull(),
            "result": ["token": params["token"] ?? NSNull()],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: reply) else { return nil }
        let data = Array(payload) + [UInt8(ascii: "\n")]
        _ = data.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        return nil
    }

    deinit {
        lock.lock(); held.forEach { close($0) }; lock.unlock()
        close(listener)
        unlink(path)
    }
}
