import XCTest
@testable import WLKit

/// A connection's callbacks usually capture the connection itself — a
/// request's `finish` closes it — so the connection has to break that cycle
/// once the callbacks can no longer fire, on every way it can end. Before it
/// did, every request (one per poll, every 2.5 s) leaked its connection and
/// dispatch queue.
///
/// Also the socket's behaviour against a peer that is already gone.
final class SocketConnectionLifetimeTests: XCTestCase {

    /// The shape `HerdrClient.request` has: the reply handler holds the
    /// connection strongly and closes it.
    func testAConnectionClosedFromItsReplyIsFreed() async throws {
        let server = try FakeHerdrServer()
        let replied = expectation(description: "onLine")
        weak var weakConn: SocketConnection?

        do {
            let conn = SocketConnection(path: server.path)
            conn.onLine = { _ in
                conn.close()
                replied.fulfill()
            }
            conn.onClosed = { _ in conn.close() }
            try conn.open()
            conn.write(Data("{\"id\":\"wl_1\",\"method\":\"agent.list\",\"params\":{}}\n".utf8))
            weakConn = conn
        }

        await server.receiveRequest()
        server.reply(#"{"id":"wl_1","result":{"agents":[]}}"#)
        await fulfillment(of: [replied], timeout: 1)

        try await assertFreed { weakConn }
    }

    /// No Herdr at the path (the local one is down, a tunnel is not up yet):
    /// `open()` throws and no read loop ever runs, so the loop cannot be what
    /// lets go of the callbacks. This path runs on every poll while the local
    /// Herdr is down.
    func testAConnectionThatFailedToOpenIsFreed() async throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mm-none-\(UUID().uuidString.prefix(8)).sock")
        weak var weakConn: SocketConnection?

        do {
            let conn = SocketConnection(path: path)
            conn.onLine = { _ in conn.close() }
            conn.onClosed = { _ in conn.close() }
            XCTAssertThrowsError(try conn.open())
            weakConn = conn
        }

        try await assertFreed { weakConn }
    }

    /// The peer hangs up on the request without replying: the loop ends on
    /// its own and reports it through `onClosed`.
    func testAConnectionThePeerClosedIsFreed() async throws {
        let server = try HangUpHerdrServer()
        let closed = expectation(description: "onClosed")
        weak var weakConn: SocketConnection?

        do {
            let conn = SocketConnection(path: server.path)
            conn.onLine = { _ in conn.close() }
            conn.onClosed = { _ in
                conn.close()
                closed.fulfill()
            }
            try conn.open()
            conn.write(Data("{\"id\":\"wl_1\",\"method\":\"agent.list\",\"params\":{}}\n".utf8))
            weakConn = conn
        }

        await fulfillment(of: [closed], timeout: 1)
        try await assertFreed { weakConn }
    }

    /// Writing to a peer that has closed raises SIGPIPE unless the socket
    /// says otherwise, and its default action kills the process — here the
    /// test runner, in the app the whole app. 1 MB is far more than a Unix
    /// socket buffers, so the write is still blocked when the server, having
    /// seen the first bytes arrive, hangs up; it can only end in EPIPE.
    func testWritingToAPeerThatClosedReturnsInsteadOfRaisingSIGPIPE() async throws {
        let server = try HangUpHerdrServer()
        let closed = expectation(description: "onClosed")

        let conn = SocketConnection(path: server.path)
        conn.onClosed = { _ in closed.fulfill() }
        try conn.open()
        conn.write(Data(repeating: UInt8(ascii: "x"), count: 1 << 20))

        // Reaching this line is the test: without SO_NOSIGPIPE the runner
        // is dead by now.
        await fulfillment(of: [closed], timeout: 1)
        conn.close()
    }

    /// Polls rather than checking once: the read loop lets go of the
    /// connection on its own queue, a moment after the callback the test
    /// waited for.
    private func assertFreed(
        _ object: () -> AnyObject?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(1)
        while object() != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(object(), "the connection outlived its last callback", file: file, line: line)
    }
}
