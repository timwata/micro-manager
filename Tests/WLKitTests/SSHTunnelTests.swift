import XCTest
@testable import WLKit

@MainActor
final class SSHTunnelTests: XCTestCase {

    // MARK: - Command line

    func testArgumentsCarryEveryOptionInOrder() {
        let args = SSHTunnel.arguments(
            host: "workbox",
            localSocket: "/tmp/mm-workbox.sock",
            remoteSocket: "/home/me/.config/herdr/herdr.sock"
        )
        XCTAssertEqual(args, [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "RemoteCommand=none",
            "-o", "ForwardAgent=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            "-L", "/tmp/mm-workbox.sock:/home/me/.config/herdr/herdr.sock",
            "--", "workbox",
            "cat >/dev/null",
        ])
    }

    /// Whatever the host looks like, it comes after `--`, where ssh can only
    /// read it as a destination.
    func testHostIsNeverReadAsAnOption() {
        let args = SSHTunnel.arguments(host: "-oProxyCommand=touch /tmp/pwned", localSocket: "/l", remoteSocket: "/r")
        XCTAssertEqual(Array(args.suffix(3)), ["--", "-oProxyCommand=touch /tmp/pwned", "cat >/dev/null"])
        XCTAssertEqual(args.firstIndex(of: "--"), args.count - 3)
    }

    func testHomeLookupSharesTheSafetyOptions() {
        let args = SSHTunnel.homeLookupArguments(host: "me@gpu-box")
        XCTAssertEqual(Array(args.prefix(SSHTunnel.commonOptions.count)), SSHTunnel.commonOptions)
        XCTAssertEqual(Array(args.suffix(3)), ["--", "me@gpu-box", "printenv HOME"])
        XCTAssertFalse(args.contains("-L"))
    }

    // MARK: - Local socket path

    private let tmp = "/var/folders/pr/_b3km7957sb34kfwm6wrwvz00000gn/T/"

    func testPlainNameIsUsedAsIs() {
        XCTAssertEqual(
            SSHTunnel.localSocketPath(name: "workbox", directory: tmp),
            "/var/folders/pr/_b3km7957sb34kfwm6wrwvz00000gn/T/mm-workbox.sock"
        )
        XCTAssertEqual(SSHTunnel.localSocketPath(name: "gpu", directory: "/tmp"), "/tmp/mm-gpu.sock")
    }

    func testOddCharactersAreReplacedAndHashed() {
        let path = SSHTunnel.localSocketPath(name: "me@gpu box/../x", directory: "/tmp")
        let file = (path as NSString).lastPathComponent
        XCTAssertEqual((path as NSString).deletingLastPathComponent, "/tmp")
        XCTAssertTrue(file.hasPrefix("mm-me_gpu_box_.._x-"), file)
        XCTAssertTrue(file.hasSuffix(".sock"))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        XCTAssertTrue(file.unicodeScalars.allSatisfy(allowed.contains), file)
    }

    func testNamesThatSanitizeAlikeGetDifferentSockets() {
        let a = SSHTunnel.localSocketPath(name: "a b", directory: "/tmp")
        let b = SSHTunnel.localSocketPath(name: "a_b", directory: "/tmp")
        let c = SSHTunnel.localSocketPath(name: "a/b", directory: "/tmp")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        XCTAssertEqual(b, "/tmp/mm-a_b.sock")
    }

    func testPathIsStableAcrossCalls() {
        XCTAssertEqual(
            SSHTunnel.localSocketPath(name: "wörk böx", directory: tmp),
            SSHTunnel.localSocketPath(name: "wörk böx", directory: tmp)
        )
    }

    func testLongNameIsTruncatedUnderTheSocketLimit() {
        let long = String(repeating: "verylonghostname", count: 10)
        let path = SSHTunnel.localSocketPath(name: long, directory: tmp)
        XCTAssertLessThanOrEqual(path.utf8.count, SSHTunnel.maxSocketPathBytes)
        XCTAssertLessThan(path.utf8.count, 104)
        XCTAssertTrue(path.hasPrefix(tmp + "mm-verylong"), path)
        // Two long names sharing a prefix must not collide after truncation.
        XCTAssertNotEqual(path, SSHTunnel.localSocketPath(name: long + "2", directory: tmp))
    }

    func testNameThatJustFitsIsNotHashed() {
        let room = SSHTunnel.maxSocketPathBytes - "/tmp/mm-.sock".utf8.count
        let name = String(repeating: "x", count: room)
        XCTAssertEqual(SSHTunnel.localSocketPath(name: name, directory: "/tmp"), "/tmp/mm-\(name).sock")
        let tooLong = SSHTunnel.localSocketPath(name: name + "x", directory: "/tmp")
        XCTAssertEqual(tooLong.utf8.count, SSHTunnel.maxSocketPathBytes)
        XCTAssertNotEqual(tooLong, "/tmp/mm-\(name).sock")
    }

    func testTrailingSlashesInTheDirectoryAreIgnored() {
        XCTAssertEqual(SSHTunnel.localSocketPath(name: "box", directory: "/tmp///"), "/tmp/mm-box.sock")
    }

    func testOverlongDirectoryFallsBackToTmp() {
        let deep = "/" + String(repeating: "d", count: 120)
        XCTAssertEqual(SSHTunnel.localSocketPath(name: "box", directory: deep), "/tmp/mm-box.sock")
    }

    func testEmptyNameStillGetsAPath() {
        let path = SSHTunnel.localSocketPath(name: "", directory: "/tmp")
        XCTAssertTrue(path.hasPrefix("/tmp/mm--"), path)
        XCTAssertTrue(path.hasSuffix(".sock"))
    }

    // MARK: - Remote home

    func testTildePathsNeedTheRemoteHome() {
        XCTAssertTrue(SSHTunnel.needsRemoteHome("~/.config/herdr/herdr.sock"))
        XCTAssertTrue(SSHTunnel.needsRemoteHome("~"))
        XCTAssertFalse(SSHTunnel.needsRemoteHome("/run/user/1000/herdr.sock"))
        // `~user` is another account's home; not ours to guess.
        XCTAssertFalse(SSHTunnel.needsRemoteHome("~bob/herdr.sock"))
        XCTAssertFalse(SSHTunnel.needsRemoteHome("relative/~/x.sock"))
    }

    func testTildeIsReplacedWithTheRemoteHome() {
        XCTAssertEqual(
            SSHTunnel.expandRemoteHome("~/.config/herdr/herdr.sock", home: "/home/me"),
            "/home/me/.config/herdr/herdr.sock"
        )
        XCTAssertEqual(SSHTunnel.expandRemoteHome("~/x.sock", home: "/home/me/"), "/home/me/x.sock")
        XCTAssertEqual(SSHTunnel.expandRemoteHome("~/x.sock", home: "/"), "/x.sock")
        XCTAssertEqual(SSHTunnel.expandRemoteHome("~", home: "/home/me"), "/home/me")
        XCTAssertEqual(SSHTunnel.expandRemoteHome("~", home: "/"), "/")
    }

    func testOtherPathsAreLeftAlone() {
        XCTAssertEqual(SSHTunnel.expandRemoteHome("/run/h.sock", home: "/home/me"), "/run/h.sock")
        XCTAssertEqual(SSHTunnel.expandRemoteHome("~bob/h.sock", home: "/home/me"), "~bob/h.sock")
    }

    // MARK: - Messages

    func testHostKeyFailureExplainsWhatToDo() {
        let message = SSHTunnel.describeFailure(
            "Host key verification failed.", host: "workbox", remoteSocket: nil
        )
        XCTAssertEqual(
            message,
            "Run `ssh workbox` once in a terminal to trust the host key. (ssh: Host key verification failed.)"
        )
    }

    func testAuthFailureMentionsKeys() {
        let message = SSHTunnel.describeFailure(
            "me@workbox: Permission denied (publickey,password).", host: "workbox", remoteSocket: nil
        )
        XCTAssertEqual(
            message,
            "SSH key auth failed (no password prompts from a menu-bar app). (ssh: me@workbox: Permission denied (publickey,password).)"
        )
    }

    /// A socket the remote user may not open is not a login problem.
    func testChannelErrorsAreAboutTheRemoteSocket() {
        let missing = SSHTunnel.describeFailure(
            "channel 2: open failed: connect failed: No such file or directory",
            host: "workbox", remoteSocket: "/home/me/.config/herdr/herdr.sock"
        )
        XCTAssertEqual(
            missing,
            "No Herdr is listening at /home/me/.config/herdr/herdr.sock on workbox. Is Herdr running there? "
                + "(ssh: channel 2: open failed: connect failed: No such file or directory)"
        )
        let denied = SSHTunnel.describeFailure(
            "channel 3: open failed: connect failed: Permission denied", host: "workbox", remoteSocket: nil
        )
        XCTAssertTrue(denied?.hasPrefix("No Herdr is listening on workbox.") == true, denied ?? "nil")
    }

    func testForwardingDisabledOnTheServer() {
        let message = SSHTunnel.describeFailure(
            "channel 2: open failed: administratively prohibited: open failed", host: "box", remoteSocket: nil
        )
        XCTAssertTrue(message?.contains("AllowStreamLocalForwarding") == true, message ?? "nil")
    }

    func testUnknownLinesArePassedThrough() {
        XCTAssertEqual(
            SSHTunnel.describeFailure(
                "ssh: Could not resolve hostname nope: nodename nor servname provided, or not known",
                host: "nope", remoteSocket: nil
            ),
            "ssh: Could not resolve hostname nope: nodename nor servname provided, or not known"
        )
        XCTAssertEqual(
            SSHTunnel.describeFailure("Connection closed by 10.0.0.2 port 22", host: "box", remoteSocket: nil),
            "ssh: Connection closed by 10.0.0.2 port 22"
        )
    }

    func testNothingToSayIsNil() {
        XCTAssertNil(SSHTunnel.describeFailure(nil, host: "box", remoteSocket: nil))
        XCTAssertNil(SSHTunnel.describeFailure("  \n", host: "box", remoteSocket: nil))
    }

    func testLastNonEmptyLine() {
        XCTAssertEqual(SSHTunnel.lastNonEmptyLine("one\ntwo\n\n  \n"), "two")
        XCTAssertEqual(SSHTunnel.lastNonEmptyLine("only"), "only")
        XCTAssertNil(SSHTunnel.lastNonEmptyLine("\n \n"))
    }

    func testBackoffDoublesUpToThirtySeconds() {
        XCTAssertEqual((0...6).map(SSHTunnel.backoff(afterFailures:)), [3, 6, 12, 24, 30, 30, 30])
    }

    // MARK: - Lifecycle, against a stand-in for ssh

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHTunnelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes an executable shell script and returns its path.
    private func fakeSSH(_ body: String) throws -> String {
        let url = scratch.appendingPathComponent("ssh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Collects every state change and lets a test wait for a given one.
    private final class StateLog {
        var states: [SSHTunnel.State] = []
        var waiters: [(predicate: (SSHTunnel.State) -> Bool, expectation: XCTestExpectation)] = []

        func record(_ state: SSHTunnel.State) {
            states.append(state)
            for waiter in waiters where waiter.predicate(state) { waiter.expectation.fulfill() }
            waiters.removeAll { $0.predicate(state) }
        }
    }

    private func observe(_ tunnel: SSHTunnel) -> StateLog {
        let log = StateLog()
        tunnel.onStateChange = { log.record($0) }
        return log
    }

    private func waitFor(
        _ log: StateLog,
        timeout: TimeInterval = 5,
        _ predicate: @escaping (SSHTunnel.State) -> Bool
    ) async {
        let expectation = expectation(description: "state")
        log.waiters.append((predicate, expectation))
        await fulfillment(of: [expectation], timeout: timeout)
    }

    private static func isFailure(_ state: SSHTunnel.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    func testAuthFailureIsReportedThenRetriedUntilStopped() async throws {
        let ssh = try fakeSSH("""
        echo "debug noise" >&2
        echo "me@box: Permission denied (publickey)." >&2
        exit 255
        """)
        let tunnel = SSHTunnel(
            remote: HerdrRemote(name: "box", host: "box", socket: "/run/herdr.sock"),
            sshPath: ssh
        )
        tunnel.retryDelay = { _ in 0.05 }
        let log = observe(tunnel)

        tunnel.start()
        XCTAssertEqual(tunnel.state, .connecting)
        await waitFor(log, Self.isFailure)
        XCTAssertEqual(
            tunnel.state,
            .failed("SSH key auth failed (no password prompts from a menu-bar app). (ssh: me@box: Permission denied (publickey).)")
        )

        // The retry goes back through .connecting and fails the same way.
        let failuresSoFar = log.states.filter(Self.isFailure).count
        await waitFor(log) { _ in log.states.filter(Self.isFailure).count > failuresSoFar }
        XCTAssertEqual(Array(log.states.prefix(4)).map(Self.isFailure), [false, true, false, true])

        tunnel.stop()
        XCTAssertEqual(tunnel.state, .idle)
        let settled = log.states.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(log.states.count, settled, "no retry after stop: \(log.states)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tunnel.localSocket))
    }

    /// ssh writes `\r\n`, which Swift treats as a single character; the
    /// last line must still come out on its own.
    func testCRLFStderrYieldsOnlyTheLastLine() async throws {
        let ssh = try fakeSSH("""
        printf 'channel 2: open failed: connect failed: open failed\\r\\n' >&2
        printf 'Connection to box closed by remote host.\\r\\n' >&2
        exit 255
        """)
        let tunnel = SSHTunnel(
            remote: HerdrRemote(name: "box", host: "box", socket: "/run/herdr.sock"),
            sshPath: ssh
        )
        tunnel.retryDelay = { _ in 60 }
        let log = observe(tunnel)
        tunnel.start()
        await waitFor(log, Self.isFailure)
        XCTAssertEqual(tunnel.state, .failed("ssh: Connection to box closed by remote host."))
        tunnel.stop()
    }

    func testExitWithoutStderrReportsTheStatus() async throws {
        let ssh = try fakeSSH("exit 7")
        let tunnel = SSHTunnel(
            remote: HerdrRemote(name: "box", host: "box", socket: "/run/herdr.sock"),
            sshPath: ssh
        )
        tunnel.retryDelay = { _ in 60 }
        let log = observe(tunnel)
        tunnel.start()
        await waitFor(log, Self.isFailure)
        XCTAssertEqual(tunnel.state, .failed("ssh exited with status 7."))
        tunnel.stop()
    }

    /// The default socket is under `~/`, so the remote home is looked up
    /// first, and the forward names the expanded path.
    func testTildeIsExpandedWithTheRemoteHomeBeforeForwarding() async throws {
        let record = scratch.appendingPathComponent("args").path
        let ssh = try fakeSSH("""
        for last; do :; done
        if [ "$last" = "printenv HOME" ]; then echo /home/fake; exit 0; fi
        printf '%s\\n' "$@" > '\(record)'
        echo "stop here" >&2
        exit 1
        """)
        // A host unique to this test, since the home is cached per host.
        let host = "home-\(UUID().uuidString)"
        let tunnel = SSHTunnel(remote: HerdrRemote(name: "box", host: host), sshPath: ssh)
        tunnel.retryDelay = { _ in 60 }
        let log = observe(tunnel)
        tunnel.start()
        await waitFor(log, Self.isFailure)
        tunnel.stop()

        let args = try String(contentsOfFile: record, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(
            args,
            SSHTunnel.arguments(
                host: host,
                localSocket: tunnel.localSocket,
                remoteSocket: "/home/fake/.config/herdr/herdr.sock"
            )
        )
        XCTAssertEqual(tunnel.state, .idle)
    }

    func testHomeLookupFailureIsAConnectionFailure() async throws {
        let ssh = try fakeSSH("""
        echo "Host key verification failed." >&2
        exit 255
        """)
        let tunnel = SSHTunnel(remote: HerdrRemote(name: "box", host: "hk-\(UUID().uuidString)"), sshPath: ssh)
        tunnel.retryDelay = { _ in 60 }
        let log = observe(tunnel)
        tunnel.start()
        await waitFor(log, Self.isFailure)
        guard case .failed(let message) = tunnel.state else { return XCTFail("\(tunnel.state)") }
        XCTAssertTrue(message.hasPrefix("Run `ssh hk-"), message)
        tunnel.stop()
    }

    /// A long-lived ssh is killed by `stop()`, and the stdin pipe it was
    /// handed is closed — that EOF is what ends the remote `cat` for real.
    func testStopEndsAHangingSSH() async throws {
        let pidFile = scratch.appendingPathComponent("pid").path
        let eofFile = scratch.appendingPathComponent("eof").path
        let ssh = try fakeSSH("""
        echo $$ > '\(pidFile)'
        trap '' TERM
        cat >/dev/null
        touch '\(eofFile)'
        """)
        let tunnel = SSHTunnel(
            remote: HerdrRemote(name: "box", host: "box", socket: "/run/herdr.sock"),
            sshPath: ssh
        )
        tunnel.start()
        try await waitForFile(pidFile)

        tunnel.stop()
        tunnel.stop() // idempotent
        XCTAssertEqual(tunnel.state, .idle)
        // The script ignores SIGTERM, so only the closed pipe can end `cat`.
        try await waitForFile(eofFile)
    }

    func testStartTwiceRunsOneSSH() async throws {
        let countFile = scratch.appendingPathComponent("count").path
        let ssh = try fakeSSH("""
        echo run >> '\(countFile)'
        cat >/dev/null
        """)
        let tunnel = SSHTunnel(
            remote: HerdrRemote(name: "box", host: "box", socket: "/run/herdr.sock"),
            sshPath: ssh
        )
        tunnel.start()
        tunnel.start()
        try await waitForFile(countFile)
        try await Task.sleep(nanoseconds: 300_000_000)
        tunnel.stop()
        let runs = try String(contentsOfFile: countFile, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(runs, 1)
    }

    private func waitForFile(_ path: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: path) {
            guard Date() < deadline else { return XCTFail("\(path) never appeared") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
