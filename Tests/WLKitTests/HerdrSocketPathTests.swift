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
    }

    func testEnvironmentOverrideMirrorsTheProcessEnvironment() {
        let raw = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"]
        XCTAssertEqual(HerdrClient.environmentOverride, raw?.isEmpty == false ? raw : nil)
    }
}
