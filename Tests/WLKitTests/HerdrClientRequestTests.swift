import XCTest
@testable import WLKit

/// `request`'s completion races — a reply, a timeout, a close, an open
/// failure, each on its own thread — and its socket's teardown.
final class HerdrClientRequestTests: XCTestCase {

    override func setUpWithError() throws {
        if HerdrClient.environmentOverride != nil {
            throw XCTSkip("HERDR_SOCKET_PATH is set, so it wins over any override")
        }
    }

    override func tearDown() {
        // The override is process-wide; never let it leak into the Live tests.
        HerdrClient.setSocketPath(nil)
        super.tearDown()
    }

    /// The reply finishes the request on the socket's queue; the timeout
    /// still fires later on a global queue. It must find the request
    /// finished — resuming the continuation a second time is fatal.
    func testALateTimeoutAfterTheReplyIsHarmless() async throws {
        let server = try FakeHerdrServer()
        HerdrClient.setSocketPath(server.path)

        let reply = Task { try await HerdrClient.request("agent.list", timeout: 0.2) }
        await server.receiveRequest()
        server.reply(#"{"id":"wl_1","result":{"agents":[]}}"#)

        let result = try await reply.value
        XCTAssertNotNil(result["agents"])
        // Outlive the timeout, so it fires against the finished request.
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    /// Every request opens and closes its own connection, so fd numbers are
    /// recycled constantly. A read loop that read from a number after its
    /// connection was closed would steal another request's reply: that
    /// request would then time out, or get a token that is not its own.
    func testConcurrentRequestsEachGetTheirOwnReply() async throws {
        let count = 200
        let server = try EchoHerdrServer(connections: count)
        HerdrClient.setSocketPath(server.path)

        let outcomes = await requestTokens(count: count) { _ in 5 }

        XCTAssertEqual(outcomes.count, count)
        for (i, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
            guard case .success(let token) = outcome else {
                XCTFail("request \(i): unexpected \(outcome)")
                continue
            }
            XCTAssertEqual(token, i, "request \(i) got another request's reply")
        }
    }

    /// The same, with half the requests timing out: a timeout closes its
    /// connection from a global queue while the read loop is blocked in
    /// `read()` and other requests are opening sockets — the window in which
    /// a freed fd number gets reused.
    func testTimeoutsAmongConcurrentRequestsTakeNoOtherReply() async throws {
        let count = 400
        let server = try EchoHerdrServer(connections: count, withhold: { $0 % 2 == 1 })
        HerdrClient.setSocketPath(server.path)

        let outcomes = await requestTokens(count: count) { $0 % 2 == 1 ? 0.05 : 5 }

        XCTAssertEqual(outcomes.count, count)
        for (i, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
            switch (i % 2, outcome) {
            case (0, .success(let token)):
                XCTAssertEqual(token, i, "request \(i) got another request's reply")
            case (1, .failure(HerdrError.timeout)):
                break
            default:
                XCTFail("request \(i): unexpected \(outcome)")
            }
        }
    }

    /// Sends `echo` with tokens `0..<count`, at most `width` in flight at
    /// once, and collects what each one got back. Bounded because the fake
    /// server answers on one thread, its backlog is capped at 128 by macOS,
    /// and a Unix socket refuses a connect outright when its backlog is full.
    private func requestTokens(
        count: Int,
        width: Int = 64,
        timeout: @escaping @Sendable (Int) -> TimeInterval
    ) async -> [Int: Result<Int?, Error>] {
        await withTaskGroup(of: (Int, Result<Int?, Error>).self) { group in
            func add(_ i: Int) {
                group.addTask {
                    do {
                        let result = try await HerdrClient.request(
                            "echo", params: ["token": i], timeout: timeout(i)
                        )
                        return (i, .success(result["token"] as? Int))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            var next = 0
            while next < min(width, count) { add(next); next += 1 }
            var outcomes: [Int: Result<Int?, Error>] = [:]
            for await (i, outcome) in group {
                outcomes[i] = outcome
                if next < count { add(next); next += 1 }
            }
            return outcomes
        }
    }
}
