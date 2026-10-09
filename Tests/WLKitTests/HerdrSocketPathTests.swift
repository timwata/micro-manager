import XCTest
@testable import WLKit

final class HerdrSocketPathTests: XCTestCase {

    override func tearDown() {
        // The override is process-wide; never let it leak into the Live tests.
        HerdrClient.setSocketPath(nil)
        super.tearDown()
    }

    // MARK: - Precedence, inputs passed in

    func testEnvironmentBeatsTheOverride() {
        let path = HerdrClient.resolveSocketPath(
            environment: ["HERDR_SOCKET_PATH": "/tmp/env.sock", "XDG_CONFIG_HOME": "/xdg"],
            override: "/tmp/tunnel.sock"
        )
        XCTAssertEqual(path, "/tmp/env.sock")
    }

    func testOverrideBeatsTheDefault() {
        let path = HerdrClient.resolveSocketPath(
            environment: ["XDG_CONFIG_HOME": "/xdg"],
            override: "/tmp/tunnel.sock"
        )
        XCTAssertEqual(path, "/tmp/tunnel.sock")
    }

    func testEmptyEnvironmentValueIsIgnored() {
        let path = HerdrClient.resolveSocketPath(
            environment: ["HERDR_SOCKET_PATH": "", "XDG_CONFIG_HOME": "/xdg"],
            override: "/tmp/tunnel.sock"
        )
        XCTAssertEqual(path, "/tmp/tunnel.sock")
    }

    func testBlankOverrideFallsBackToTheDefault() {
        for blank in ["", "  ", "\n"] {
            XCTAssertEqual(
                HerdrClient.resolveSocketPath(environment: ["XDG_CONFIG_HOME": "/xdg"], override: blank),
                "/xdg/herdr/herdr.sock"
            )
        }
    }

    func testBlankEnvironmentValueIsIgnored() {
        let path = HerdrClient.resolveSocketPath(
            environment: ["HERDR_SOCKET_PATH": "  ", "XDG_CONFIG_HOME": "/xdg"],
            override: " /tmp/tunnel.sock "
        )
        XCTAssertEqual(path, "/tmp/tunnel.sock")
    }

    func testDefaultFollowsXDGConfigHome() {
        XCTAssertEqual(
            HerdrClient.resolveSocketPath(environment: ["XDG_CONFIG_HOME": "/xdg"], override: nil),
            "/xdg/herdr/herdr.sock"
        )
    }

    func testDefaultFallsBackToDotConfig() {
        let expected = (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/herdr.sock")
        XCTAssertEqual(HerdrClient.resolveSocketPath(environment: [:], override: nil), expected)
        XCTAssertEqual(
            HerdrClient.resolveSocketPath(environment: ["XDG_CONFIG_HOME": ""], override: nil),
            expected
        )
    }

    // MARK: - The real, process-wide setting

    func testSetSocketPathIsUsedAndNilRestoresTheDefault() throws {
        if HerdrClient.environmentOverride != nil {
            throw XCTSkip("HERDR_SOCKET_PATH is set, so it wins over any override")
        }
        let defaultPath = HerdrClient.socketPath()

        HerdrClient.setSocketPath("/tmp/mm-test.sock")
        XCTAssertEqual(HerdrClient.socketPath(), "/tmp/mm-test.sock")

        HerdrClient.setSocketPath(nil)
        XCTAssertEqual(HerdrClient.socketPath(), defaultPath)
        XCTAssertTrue(defaultPath.hasSuffix("/herdr/herdr.sock"))
    }

    /// An empty path could only ever fail to connect; treat it as "no override".
    func testEmptyPathClearsTheOverride() throws {
        if HerdrClient.environmentOverride != nil {
            throw XCTSkip("HERDR_SOCKET_PATH is set, so it wins over any override")
        }
        let defaultPath = HerdrClient.socketPath()
        HerdrClient.setSocketPath("/tmp/mm-test.sock")
        HerdrClient.setSocketPath("")
        XCTAssertEqual(HerdrClient.socketPath(), defaultPath)
        HerdrClient.setSocketPath("/tmp/mm-test.sock")
        HerdrClient.setSocketPath("   ")
        XCTAssertEqual(HerdrClient.socketPath(), defaultPath)
    }

    // MARK: - Switching while a request is in flight

    /// The control for the test below: with no switch, the fake server's
    /// reply comes through as usual.
    func testReplyFromTheCurrentTargetIsDelivered() async throws {
        if HerdrClient.environmentOverride != nil {
            throw XCTSkip("HERDR_SOCKET_PATH is set, so it wins over any override")
        }
        let server = try FakeHerdrServer()
        HerdrClient.setSocketPath(server.path)

        let reply = Task { try await HerdrClient.request("agent.list") }
        await server.receiveRequest()
        server.reply(#"{"id":"wl_1","result":{"agents":[]}}"#)

        let result = try await reply.value
        XCTAssertNotNil(result["agents"])
    }

    /// An `agent.list` asked of target A and answered after the switch to B
    /// must not light the pad with A's agents.
    func testReplyFromASupersededTargetIsDropped() async throws {
        if HerdrClient.environmentOverride != nil {
            throw XCTSkip("HERDR_SOCKET_PATH is set, so it wins over any override")
        }
        let server = try FakeHerdrServer()
        HerdrClient.setSocketPath(server.path)

        let reply = Task { try await HerdrClient.request("agent.list") }
        await server.receiveRequest()
        HerdrClient.setSocketPath("/tmp/mm-elsewhere.sock")
        server.reply(#"{"id":"wl_1","result":{"agents":[]}}"#)

        do {
            _ = try await reply.value
            XCTFail("a reply from the previous target was delivered")
        } catch HerdrError.targetChanged(let method) {
            XCTAssertEqual(method, "agent.list")
        }
    }

    func testEnvironmentOverrideMirrorsTheProcessEnvironment() {
        let raw = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
        XCTAssertEqual(HerdrClient.environmentOverride, raw?.isEmpty == false ? raw : nil)
    }
}

/// Just enough of a Herdr server to hold one request open: accepts a single
/// connection, reads one line, and answers only when told to.
private final class FakeHerdrServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private var client: Int32 = -1

    init() throws {
        // Short name: `sun_path` holds under 104 bytes, and $TMPDIR is long.
        path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("mm-\(UUID().uuidString.prefix(8)).sock")
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)

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
        guard listener >= 0, bound == 0, listen(listener, 1) == 0 else {
            let reason = String(cString: strerror(errno))
            if listener >= 0 { close(listener) }
            throw XCTSkip("cannot listen on \(path): \(reason)")
        }
    }

    /// Returns once a client has connected and sent its first line.
    func receiveRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.client = accept(self.listener, nil, nil)
                var byte: UInt8 = 0
                while self.client >= 0, read(self.client, &byte, 1) == 1, byte != UInt8(ascii: "\n") {}
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
