import XCTest
@testable import WLKit

/// Runs the process plumbing against shell scripts standing in for `but`, so
/// the stream handling is checked without GitButler installed.
final class GitButlerOutputTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitButlerOutputTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - landPlan

    /// An update notice on stderr must not end up inside the JSON.
    func testStderrWarningDoesNotBreakThePlan() async throws {
        let but = try script("but", """
        echo 'warning: x' >&2
        echo '{"stacks":[]}'
        """)
        let plan = try await GitButler.landPlan(in: directory.path, binary: but, timeout: 5)
        XCTAssertEqual(plan, [])
    }

    func testFailureReportsStderr() async throws {
        let but = try script("but", """
        echo 'some progress'
        echo 'error: not a GitButler project' >&2
        exit 1
        """)
        do {
            _ = try await GitButler.landPlan(in: directory.path, binary: but, timeout: 5)
            XCTFail("a failed `but status --json` must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "error: not a GitButler project")
        }
    }

    /// A failure that says nothing on stderr still has stdout to show.
    func testFailureFallsBackToStdout() async throws {
        let but = try script("but", """
        echo 'not a workspace'
        exit 1
        """)
        do {
            _ = try await GitButler.landPlan(in: directory.path, binary: but, timeout: 5)
            XCTFail("a failed `but status --json` must throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "not a workspace")
        }
    }

    /// More stderr than a pipe buffers (64 KB) before any stdout: draining the
    /// streams one after the other would block `but` on its stderr write until
    /// the watchdog killed it.
    func testChattyStderrDoesNotDeadlock() async throws {
        let but = try script("but", """
        head -c 200000 /dev/zero | tr '\\0' 'w' >&2
        echo '{"stacks":[{"branches":[{"name":"b","branchStatus":"completelyUnpushed"}]}]}'
        """)
        let started = Date()
        let plan = try await GitButler.landPlan(in: directory.path, binary: but, timeout: 5)
        XCTAssertEqual(plan, ["b"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "finished by the watchdog, not by itself")
    }

    // MARK: - launch

    /// Output shown to the user keeps both streams in one, in order.
    func testMergedOutputKeepsBothStreams() throws {
        let but = try script("but", """
        echo out
        echo err >&2
        """)
        let output = try GitButler.launch(
            but, arguments: [], in: directory.path,
            color: true, separateStderr: false, timeout: 5
        )
        XCTAssertEqual(output.text, "out\nerr\n")
        XCTAssertEqual(output.errorText, "")
        XCTAssertTrue(output.succeeded)
    }

    // MARK: - askLoginShell

    func testLoginShellAnswerIsUsed() throws {
        let shell = try script("shell", "echo /bin/sh")
        XCTAssertEqual(GitButler.askLoginShell(shell, timeout: 5), "/bin/sh")
    }

    /// A profile blocked in a child outside the shell's process group (`set -m`
    /// gives it its own): terminating the shell leaves the child holding the
    /// pipe, so only a bounded wait on the read returns in time.
    func testBlockedLoginShellGivesUp() throws {
        let shell = try script("shell", """
        set -m
        sleep 5 &
        wait
        echo /bin/sh
        """)
        let started = Date()
        XCTAssertNil(GitButler.askLoginShell(shell, timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
