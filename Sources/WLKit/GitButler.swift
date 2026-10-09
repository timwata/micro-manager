import Foundation

/// Runs `but` commands for a directory.
///
/// The awkward part is finding `but` at all. A menu-bar app launched by
/// launchd inherits launchd's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), not the
/// one your shell sets up, so the binary the terminal finds instantly is
/// invisible here. Hence the explicit search, with a login shell as the last
/// resort for installs in places this list has never heard of.
public enum GitButler {

    public struct StatusOutput: Sendable {
        /// Combined stdout and stderr, still carrying its ANSI escapes. Only
        /// stdout when the streams were run separately.
        public var text: String
        /// stderr when the streams were run separately; empty when merged.
        public var errorText: String = ""
        public var succeeded: Bool
        public var directory: String
    }

    public enum Failure: LocalizedError {
        case binaryNotFound
        case launchFailed(String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the `but` binary. Set WL_BUT_PATH to its full path."
            case .launchFailed(let reason):
                return "Could not run `but`: \(reason)"
            case .commandFailed(let detail):
                return detail
            }
        }
    }

    /// Where `but` typically lands, most likely first.
    static let searchPaths = [
        "/opt/homebrew/bin/but",
        "/usr/local/bin/but",
        "~/.cargo/bin/but",
        "~/.local/bin/but",
        "/usr/bin/but",
    ]

    private static let cache = BinaryCache()

    public static func locateBinary() -> String? {
        if let cached = cache.value { return cached }
        guard let found = searchForBinary() else { return nil }
        cache.value = found
        return found
    }

    private static func searchForBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["WL_BUT_PATH"], !explicit.isEmpty,
           FileManager.default.isExecutableFile(atPath: explicit) {
            return explicit
        }
        for candidate in searchPaths {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return askLoginShell()
    }

    /// Last resort: whatever the user's own shell resolves, which covers mise,
    /// asdf, nvm-style installs that only exist once a profile has been read.
    private static func askLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return askLoginShell(shell, timeout: 10)
    }

    /// A profile that blocks (a prompt, a hung network mount) must not stall
    /// Stack and Land forever, so the answer is waited for, not the shell. On
    /// timeout the shell is terminated and the lookup gives up with `nil`,
    /// which is not cached, so the next press asks again.
    ///
    /// The wait has to be on the read, not on the shell. `terminate()` takes
    /// down the shell's process group, but a child that left it (a job started
    /// with job control, a daemon) keeps the pipe open, and a shell stuck in
    /// the kernel on a hung mount does not die until the call returns. Either
    /// way, reading to EOF after `terminate()` could still block. That reader
    /// is left behind on a global queue and finishes when the pipe closes.
    static func askLoginShell(_ shell: String, timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v but"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // A profile that reads the terminal gets EOF instead of waiting.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let output = DataBox()
        let drained = DispatchGroup()
        DispatchQueue.global().async(group: drained) {
            output.value = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        guard drained.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        process.waitUntilExit()

        let path = String(decoding: output.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: - Running

    public static func status(in directory: String, timeout: TimeInterval = 15) async throws -> StatusOutput {
        try await run(["status"], in: directory, timeout: timeout)
    }

    /// `but land --yes <branch>`. A land can push to a real remote, so it gets
    /// a network-sized timeout.
    public static func land(
        _ branch: String,
        in directory: String,
        timeout: TimeInterval = 120
    ) async throws -> StatusOutput {
        try await run(["land", "--yes", branch], in: directory, timeout: timeout)
    }

    /// Applied branches in landing order: bottom-most first within each stack,
    /// branches already integrated into the target skipped.
    public static func landPlan(in directory: String, timeout: TimeInterval = 15) async throws -> [String] {
        guard let binary = locateBinary() else { throw Failure.binaryNotFound }
        return try await landPlan(in: directory, binary: binary, timeout: timeout)
    }

    /// The streams are kept apart here: a single line on stderr (an update
    /// notice, a deprecation warning) would otherwise land in the middle of
    /// the JSON and fail the whole land. stderr still matters on failure,
    /// since that is where `but` says what went wrong.
    static func landPlan(in directory: String, binary: String, timeout: TimeInterval) async throws -> [String] {
        let output = try await run(
            binary, ["status", "--json"], in: directory,
            color: false, separateStderr: true, timeout: timeout
        )
        guard output.succeeded else {
            let error = output.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.commandFailed(
                error.isEmpty ? output.text.trimmingCharacters(in: .whitespacesAndNewlines) : error
            )
        }
        return try parseLandPlan(Data(output.text.utf8))
    }

    /// What a confirmed land does next, given a freshly read plan.
    public enum LandStep: Equatable, Sendable {
        case land(String)
        case done
        /// Stop without landing; the message is for the panel.
        case stop(String)
    }

    /// Decides the next land from the current plan, so a land only ever
    /// pushes what the user confirmed.
    ///
    /// The plan is re-read after every land, because each land rebases what
    /// is left. That same re-read can surface a branch an agent created or
    /// applied while the confirmation was up, which the user never agreed to
    /// push. Such a branch is never landed. When it sits in front of a
    /// confirmed one, the land stops rather than skipping it: skipping would
    /// land the stack out of order.
    public static func nextLandStep(
        plan: [String], confirmed: [String], landed: Set<String>
    ) -> LandStep {
        guard let next = plan.first else { return .done }
        if landed.contains(next) {
            return .stop("`\(next)` is still in the workspace after landing it; stopping here.")
        }
        let remaining = confirmed.filter { !landed.contains($0) }
        // Whatever is left was never agreed to, so it stays where it is.
        if remaining.isEmpty { return .done }
        guard confirmed.contains(next) else {
            return .stop(
                "`\(next)` was not in the confirmed plan; stopping before it. "
                    + "Not landed: \(remaining.joined(separator: ", "))."
            )
        }
        return .land(next)
    }

    static func parseLandPlan(_ data: Data) throws -> [String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stacks = json["stacks"] as? [[String: Any]]
        else { throw Failure.commandFailed("`but status --json` returned something unexpected.") }

        return stacks.flatMap { stack -> [String] in
            let branches = stack["branches"] as? [[String: Any]] ?? []
            // Status lists branches top first; landing goes bottom up.
            return branches.reversed().compactMap { branch -> String? in
                guard let name = branch["name"] as? String, !name.isEmpty,
                      (branch["branchStatus"] as? String) != "integrated"
                else { return nil }
                return name
            }
        }
    }

    public static func run(
        _ arguments: [String],
        in directory: String,
        color: Bool = true,
        timeout: TimeInterval = 15
    ) async throws -> StatusOutput {
        guard let binary = locateBinary() else { throw Failure.binaryNotFound }
        return try await run(
            binary, arguments, in: directory,
            color: color, separateStderr: false, timeout: timeout
        )
    }

    private static func run(
        _ binary: String,
        _ arguments: [String],
        in directory: String,
        color: Bool,
        separateStderr: Bool,
        timeout: TimeInterval
    ) async throws -> StatusOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try launch(
                        binary, arguments: arguments, in: directory,
                        color: color, separateStderr: separateStderr, timeout: timeout
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func launch(
        _ binary: String,
        arguments: [String],
        in directory: String,
        color: Bool,
        separateStderr: Bool,
        timeout: TimeInterval
    ) throws -> StatusOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        var environment = ProcessInfo.processInfo.environment
        // `but` drops colour when stdout is not a terminal, and colour is most
        // of what makes the stack readable. JSON goes the other way: forced
        // colour has no business inside machine-readable output.
        if color {
            environment["CLICOLOR_FORCE"] = "1"
        }
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = [
            (binary as NSString).deletingLastPathComponent,
            environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ].joined(separator: ":")
        process.environment = environment

        // Output shown to the user (`status`, `land`) gets one pipe for both
        // streams: it keeps the error text interleaved where it belongs.
        // Output parsed by us gets stderr on a pipe of its own.
        let pipe = Pipe()
        let errorPipe = separateStderr ? Pipe() : nil
        process.standardOutput = pipe
        process.standardError = errorPipe ?? pipe

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // stderr is drained while stdout is read, not after it: once either
        // pipe's buffer fills, `but` blocks writing to it, and a reader stuck
        // waiting for EOF on the other one never gets there.
        let errorOutput = DataBox()
        let drained = DispatchGroup()
        if let errorPipe {
            DispatchQueue.global().async(group: drained) {
                errorOutput.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        watchdog.cancel()

        return StatusOutput(
            text: String(decoding: data, as: UTF8.self),
            errorText: String(decoding: errorOutput.value, as: UTF8.self),
            succeeded: process.terminationStatus == 0,
            directory: directory
        )
    }

    /// Hands bytes read on another queue back to the waiting one. The
    /// `DispatchGroup` wait is the happens-before edge, so the box itself
    /// needs no lock.
    private final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    /// Resolving through a login shell costs a shell startup, so hold onto the
    /// answer. Nothing invalidates it: a `but` that moves mid-session is worth
    /// a relaunch.
    private final class BinaryCache: @unchecked Sendable {
        private var stored: String?
        private let lock = NSLock()
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
