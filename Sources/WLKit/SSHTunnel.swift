import Foundation

/// Forwards a remote Herdr's Unix socket to a local one with the system `ssh`,
/// so `HerdrClient` can talk to a server on another machine exactly as it
/// talks to the local one. This automates — and keeps alive — the hand-run
///
///     ssh -N -L /tmp/herdr-remote.sock:/path/to/remote/herdr.sock workbox
///
/// The ssh process is owned outright: one dedicated connection per tunnel,
/// never a multiplexed master, so its lifetime is the tunnel's lifetime. It
/// also dies with the app, crash included, because its remote command reads a
/// stdin pipe only this process holds (see `arguments`).
@MainActor
public final class SSHTunnel {

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        /// The message is meant for a person: ssh's own last word, with a
        /// plainer explanation in front where one is known.
        case failed(String)
    }

    public private(set) var state: State = .idle
    public var onStateChange: ((State) -> Void)?

    public let remote: HerdrRemote
    /// Where the forward listens on this Mac; hand it to
    /// `HerdrClient.setSocketPath`. Fixed per remote, so it can be set before
    /// the tunnel is up — and two tunnels to the same remote share it, so
    /// stop the old one before starting the new.
    public let localSocket: String

    /// Seconds to wait before the next attempt, given how many attempts in a
    /// row have failed. A seam for tests, which cannot wait 3 s per retry.
    var retryDelay: (Int) -> TimeInterval = SSHTunnel.backoff
    /// How long ssh gets to log in and bind the local socket. `ConnectTimeout`
    /// and ssh's own exit already bound the network part, so this is only a
    /// safety cap, generous enough for a slow link or a multi-hop
    /// `ProxyJump`. A seam for tests, like `retryDelay`.
    var loginTimeout: TimeInterval = 60
    /// How long a Herdr gets to answer through the forward once ssh has
    /// logged in. A seam for tests, like `retryDelay`.
    var readinessTimeout: TimeInterval = 10

    private let sshPath: String
    /// Bumped whenever an attempt is superseded, so the late callbacks of a
    /// killed ssh — its exit, a probe that was still in flight — are ignored
    /// instead of tearing down the attempt that replaced it.
    private var attemptID = 0
    private var active = false
    private var failures = 0
    private var retryTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var stderrTail: StderrTail?
    /// Kept outside the main actor's state so `deinit` can still kill the
    /// process if the owner forgot to call `stop()`.
    private nonisolated let processBox = ProcessBox()

    public convenience init(remote: HerdrRemote) {
        self.init(remote: remote, sshPath: "/usr/bin/ssh")
    }

    /// `sshPath` lets tests stand in a script for ssh.
    init(remote: HerdrRemote, sshPath: String) {
        self.remote = remote
        self.sshPath = sshPath
        self.localSocket = Self.localSocketPath(
            name: remote.name,
            directory: NSTemporaryDirectory()
        )
    }

    deinit {
        processBox.terminate()
    }

    // MARK: - Lifecycle

    /// Brings the tunnel up and keeps it up, retrying with backoff whenever
    /// ssh exits, until `stop()`. Calling it again while running does nothing.
    ///
    /// A failure that retrying cannot fix — a rejected key, an unknown host
    /// key, forwarding disabled on the server — ends the run instead: the
    /// state stays `.failed` and nothing is retried until `start()` is called
    /// again.
    public func start() {
        guard !active else { return }
        active = true
        failures = 0
        connect()
    }

    /// Kills ssh, cancels any pending retry and removes the local socket.
    /// Synchronous and idempotent, so it is safe on a target switch and from
    /// `applicationWillTerminate` alike.
    public func stop() {
        active = false
        attemptID += 1
        retryTask?.cancel()
        retryTask = nil
        teardownProcess()
        setState(.idle)
    }

    private func connect() {
        attemptID += 1
        let attempt = attemptID
        setState(.connecting)
        retryTask = nil

        let remote = remote
        let sshPath = sshPath
        Task { [weak self] in
            let remoteSocket: String
            do {
                remoteSocket = try await Self.resolveRemoteSocket(remote, sshPath: sshPath)
            } catch let error as TunnelError {
                self?.fail(attempt, message: error.message, permanent: error.permanent)
                return
            } catch {
                self?.fail(attempt, message: error.localizedDescription)
                return
            }
            self?.launch(attempt, remoteSocket: remoteSocket)
        }
    }

    private func launch(_ attempt: Int, remoteSocket: String) {
        guard active, attempt == attemptID else { return }

        // Clear whatever a crashed run left at the path (ssh would too, via
        // StreamLocalBindUnlink), so the readiness probe below can only ever
        // reach the listener this ssh binds.
        unlink(localSocket)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = Self.arguments(
            host: remote.host,
            localSocket: localSocket,
            remoteSocket: remoteSocket
        )
        // Held open for the life of the tunnel; see `arguments` for why.
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let tail = StderrTail(stderr.fileHandleForReading)
        stderrTail = tail

        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            // ssh's last words can still be in flight on the stderr pipe when
            // the exit is reported; give them a moment to land.
            tail.waitForEOF(timeout: 0.5)
            Task { @MainActor [weak self] in
                self?.processExited(attempt, status: status, lastLine: tail.lastLine)
            }
        }

        do {
            try process.run()
        } catch {
            tail.close()
            fail(attempt, message: "Could not run ssh: \(error.localizedDescription)")
            return
        }
        processBox.set(process, stdin: stdin.fileHandleForWriting)
        waitUntilReady(attempt, remoteSocket: remoteSocket)
    }

    /// Waits in two phases, each with its own deadline, so a slow login
    /// cannot eat into the time a Herdr gets to answer.
    ///
    /// 1. Login: ssh binds the local socket only once it has logged in, and
    ///    `launch` unlinked the path beforehand, so the file appearing means
    ///    authentication succeeded.
    /// 2. Probe: the forward is only useful once a Herdr answers through it.
    ///    The socket existing proves nothing about that: ssh binds it before
    ///    any remote connection is tried, and accepts (then drops)
    ///    connections even when nothing listens at the remote path.
    private func waitUntilReady(_ attempt: Int, remoteSocket: String) {
        let localSocket = localSocket
        let host = remote.host
        let loginTimeout = loginTimeout
        let readinessTimeout = readinessTimeout
        readinessTask = Task { [weak self] in
            let loginDeadline = Date().addingTimeInterval(loginTimeout)
            while !FileManager.default.fileExists(atPath: localSocket) {
                guard Date() < loginDeadline else {
                    self?.readinessTimedOut(attempt, remoteSocket: remoteSocket, fallback: "Timed out logging in to \(host).")
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.probeInterval * 1_000_000_000))
                if Task.isCancelled { return }
            }

            let probeDeadline = Date().addingTimeInterval(readinessTimeout)
            while Date() < probeDeadline {
                if Task.isCancelled { return }
                if await Self.probe(localSocket, timeout: Self.probeTimeout) {
                    self?.becameReady(attempt)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.probeInterval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.readinessTimedOut(
                attempt,
                remoteSocket: remoteSocket,
                fallback: "Logged in to \(host), but no Herdr answered at \(remoteSocket)."
            )
        }
    }

    /// ssh is still running but never got as far as needed; its last stderr
    /// line, if any, says more than the timeout does.
    private func readinessTimedOut(_ attempt: Int, remoteSocket: String, fallback: String) {
        let line = stderrTail?.lastLine
        fail(
            attempt,
            message: Self.describeFailure(line, host: remote.host, remoteSocket: remoteSocket) ?? fallback,
            permanent: Self.isPermanentFailure(line)
        )
    }

    private func becameReady(_ attempt: Int) {
        guard active, attempt == attemptID else { return }
        failures = 0
        setState(.connected)
    }

    private func processExited(_ attempt: Int, status: Int32, lastLine: String?) {
        guard active, attempt == attemptID else { return }
        let message = Self.describeFailure(lastLine, host: remote.host, remoteSocket: nil)
            ?? "ssh exited with status \(status)."
        fail(attempt, message: message, permanent: Self.isPermanentFailure(lastLine))
    }

    /// Ends the attempt — whatever is left of it — and schedules the next,
    /// unless the failure is permanent: then the run ends, so a rejected key
    /// is not retried forever (and fail2ban-style jails on the server don't
    /// ban this Mac for it).
    private func fail(_ attempt: Int, message: String, permanent: Bool = false) {
        guard active, attempt == attemptID else { return }
        attemptID += 1
        teardownProcess()
        setState(.failed(message))

        if permanent {
            active = false
            return
        }

        let delay = retryDelay(failures)
        failures += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.active else { return }
            self.connect()
        }
    }

    private func teardownProcess() {
        readinessTask?.cancel()
        readinessTask = nil
        processBox.terminate()
        stderrTail?.close()
        stderrTail = nil
        unlink(localSocket)
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Tuning

    nonisolated static let probeInterval: TimeInterval = 0.2
    nonisolated static let probeTimeout: TimeInterval = 2
    nonisolated static let homeLookupTimeout: TimeInterval = 10

    /// 3 s, 6 s, 12 s, 24 s, then every 30 s: quick enough to ride out a
    /// network blip, slow enough not to hammer a host that is down for good.
    nonisolated static func backoff(afterFailures failures: Int) -> TimeInterval {
        let exponent = min(max(failures, 0), 4)
        return min(3 * pow(2, Double(exponent)), 30)
    }

    // MARK: - ssh command line

    /// Options shared by the tunnel and the `$HOME` lookup.
    ///
    /// - `BatchMode=yes`: there is no terminal to type into, so a password or
    ///   host-key prompt would hang forever. Fail fast and show why instead.
    /// - `ConnectTimeout=10`: an unreachable host otherwise takes the TCP
    ///   stack's own minute-plus to give up, past the login window.
    /// - `ControlMaster=no`, `ControlPath=none`: with multiplexing configured,
    ///   the forward would be registered on a master this process does not
    ///   own, and the tunnel would outlive — or die with — someone else's ssh.
    /// - `RemoteCommand=none`: a `RemoteCommand` in the user's config would
    ///   make ssh refuse to run ours.
    /// - `ForwardAgent=no`: nothing here needs the agent on the other side,
    ///   so don't lend it to a host just because a config says `Host *`.
    nonisolated static let commonOptions: [String] = [
        "-T",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "RemoteCommand=none",
        "-o", "ForwardAgent=no",
    ]

    /// The full tunnel command line, `ssh` itself excluded.
    ///
    /// - `ExitOnForwardFailure=yes`: if the local socket cannot be bound, ssh
    ///   exits rather than idling as a connection that forwards nothing.
    /// - `ServerAliveInterval=15`, `ServerAliveCountMax=3`: notice a dead
    ///   network within ~45 s instead of waiting on TCP.
    /// - `StreamLocalBindUnlink=yes`: replace a stale socket file from a run
    ///   that did not clean up.
    /// - `--`: the host can never be read as an option, whatever reaches here
    ///   (`HerdrRemotes.parse` drops a leading `-` too, but this list must not
    ///   rely on that: `-oProxyCommand=…` would run a command).
    /// - `cat >/dev/null` rather than `-N`, with ssh's stdin a pipe the app
    ///   holds: when the app goes away for any reason, the pipe closes, `cat`
    ///   sees EOF, the session ends and ssh exits — no orphaned tunnels. It
    ///   reads the same in sh, bash, zsh and fish.
    nonisolated static func arguments(host: String, localSocket: String, remoteSocket: String) -> [String] {
        commonOptions + [
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            "-L", "\(localSocket):\(remoteSocket)",
            "--", host,
            "cat >/dev/null",
        ]
    }

    /// `printenv` is a program, not a builtin, so the answer does not depend
    /// on which login shell the remote account uses.
    nonisolated static func homeLookupArguments(host: String) -> [String] {
        commonOptions + ["--", host, "printenv HOME"]
    }

    // MARK: - Local socket path

    /// `<directory>/mm-<name>.sock`, kept short enough for `sun_path`: macOS
    /// allows 104 bytes including the terminator, and `$TMPDIR` alone is ~50.
    ///
    /// The name is reduced to `[A-Za-z0-9._-]`. Whenever that or truncation
    /// changed it, a hash of the original is appended, so `"a b"` and `"a_b"`
    /// still get sockets of their own.
    nonisolated static func localSocketPath(name: String, directory: String) -> String {
        let sanitized = String(name.unicodeScalars.map { scalar -> Character in
            allowedNameCharacters.contains(scalar) ? Character(scalar) : "_"
        })
        let hash = "-" + fnv1a(name)
        let fixedBytes = "/mm-".utf8.count + ".sock".utf8.count

        var base = directory
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        // A $TMPDIR this long leaves no room even for the hash; /tmp always does.
        if base.utf8.count + fixedBytes + hash.utf8.count > maxSocketPathBytes {
            base = "/tmp"
        }
        // Everything is ASCII from here on, so characters are bytes.
        let room = maxSocketPathBytes - base.utf8.count - fixedBytes

        let stem: String
        if sanitized == name, !name.isEmpty, name.utf8.count <= room {
            stem = name
        } else {
            stem = String(sanitized.prefix(room - hash.utf8.count)) + hash
        }
        return (base == "/" ? "" : base) + "/mm-\(stem).sock"
    }

    /// Headroom under the 104-byte `sun_path` (terminator included).
    nonisolated static let maxSocketPathBytes = 100

    private nonisolated static let allowedNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    /// Stable across launches, unlike `Hasher`, so a remote keeps its path.
    private nonisolated static func fnv1a(_ string: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    // MARK: - Remote home

    /// sshd connects a streamlocal forward to the path exactly as given — no
    /// `~` expansion, and a relative path resolves against sshd's own working
    /// directory, not the user's home — and the ssh client does not expand it
    /// either. So a `~/` path is rewritten here, with the home directory the
    /// remote reports.
    nonisolated static func needsRemoteHome(_ path: String) -> Bool {
        path == "~" || path.hasPrefix("~/")
    }

    nonisolated static func expandRemoteHome(_ path: String, home: String) -> String {
        guard needsRemoteHome(path) else { return path }
        var base = home
        while base.hasSuffix("/") { base.removeLast() }
        let expanded = base + path.dropFirst()
        return expanded.isEmpty ? "/" : expanded
    }

    private static let homeCache = HomeCache()

    /// The remote socket path with `~/` resolved, looking up the remote
    /// `$HOME` once per host per app run.
    private static func resolveRemoteSocket(_ remote: HerdrRemote, sshPath: String) async throws -> String {
        let path = remote.remoteSocket
        guard needsRemoteHome(path) else { return path }
        if let home = homeCache[remote.host] {
            return expandRemoteHome(path, home: home)
        }
        let output = try await run(
            sshPath,
            arguments: homeLookupArguments(host: remote.host),
            timeout: homeLookupTimeout
        )
        guard output.status == 0, let home = parseHome(output.stdout) else {
            let line = lastNonEmptyLine(output.stderr)
            throw TunnelError(
                describeFailure(line, host: remote.host, remoteSocket: nil)
                    ?? "Could not read the home directory on \(remote.host) (ssh exited with status \(output.status)).",
                permanent: isPermanentFailure(line)
            )
        }
        homeCache[remote.host] = home
        return expandRemoteHome(path, home: home)
    }

    /// sshd still runs `printenv HOME` through the user's login shell, which
    /// reads its startup files first (bash's `~/.bashrc` on Debian-style
    /// builds, zsh's `~/.zshenv`, fish's `config.fish`), so anything they
    /// echo lands on stdout ahead of the answer. The home is the last line
    /// that is an absolute path.
    nonisolated static func parseHome(_ stdout: String) -> String? {
        stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    private struct TunnelError: LocalizedError {
        let message: String
        /// See `isPermanentFailure`.
        let permanent: Bool
        init(_ message: String, permanent: Bool = false) {
            self.message = message
            self.permanent = permanent
        }
        var errorDescription: String? { message }
    }

    // MARK: - Messages

    /// Turns ssh's last stderr line into something a menu-bar user can act
    /// on, keeping the raw line for whoever needs to search for it. Nil when
    /// there is nothing to say, so the caller can fall back to the exit
    /// status.
    ///
    nonisolated static func describeFailure(_ line: String?, host: String, remoteSocket: String?) -> String? {
        guard let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            return nil
        }
        let hint: String?
        switch FailureKind(line) {
        case .forwardingProhibited:
            hint = "\(host) does not allow forwarding Unix sockets (AllowStreamLocalForwarding in sshd_config)."
        case .noRemoteListener:
            let socket = remoteSocket.map { " at \($0)" } ?? ""
            hint = "No Herdr is listening\(socket) on \(host). Is Herdr running there?"
        case .hostKey:
            hint = "Run `ssh \(host)` once in a terminal to trust the host key."
        case .auth:
            hint = "SSH key auth failed (no password prompts from a menu-bar app)."
        case nil:
            hint = nil
        }
        // ssh prefixes some of its own errors already ("ssh: Could not
        // resolve hostname …").
        let raw = line.hasPrefix("ssh: ") ? line : "ssh: \(line)"
        guard let hint else { return raw }
        return "\(hint) (\(raw))"
    }

    /// Whether ssh's last stderr line reports something that retrying cannot
    /// fix until the user changes their keys, `known_hosts` or the server's
    /// config. Network errors, timeouts and a missing Herdr are transient.
    nonisolated static func isPermanentFailure(_ line: String?) -> Bool {
        guard let line else { return false }
        return FailureKind(line)?.isPermanent ?? false
    }

    /// The ssh errors there is something specific to say about.
    ///
    /// Channel errors are matched first: `open failed: connect failed:
    /// Permission denied` is about the remote socket, not about logging in.
    private enum FailureKind {
        case forwardingProhibited
        case noRemoteListener
        case hostKey
        case auth

        init?(_ line: String) {
            if line.contains("open failed: administratively prohibited") {
                self = .forwardingProhibited
            } else if line.contains("open failed: connect failed") {
                self = .noRemoteListener
            } else if line.contains("Host key verification failed") {
                self = .hostKey
            } else if line.contains("Permission denied") {
                self = .auth
            } else {
                return nil
            }
        }

        /// Herdr may simply not be running yet; everything else needs the
        /// user to step in.
        var isPermanent: Bool { self != .noRemoteListener }
    }

    nonisolated static func lastNonEmptyLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    // MARK: - Plumbing

    /// One request through the forward. Any reply counts — even an error is
    /// proof that a Herdr is on the other end. `finish` holds `conn`
    /// strongly, as in `HerdrClient.request`; the connection breaks that
    /// cycle itself.
    private static func probe(_ path: String, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let conn = SocketConnection(path: path)
            let lock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { result in
                lock.lock()
                let first = !finished
                finished = true
                lock.unlock()
                guard first else { return }
                conn.close()
                continuation.resume(returning: result)
            }
            conn.onLine = { _ in finish(true) }
            conn.onClosed = { _ in finish(false) }
            do {
                try conn.open()
            } catch {
                finish(false)
                return
            }
            conn.write(Data("{\"id\":\"wl_probe\",\"method\":\"agent.list\",\"params\":{}}\n".utf8))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs a short-lived command to completion off the main thread, killing
    /// it after `timeout`.
    private static func run(_ executable: String, arguments: [String], timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: TunnelError("Could not run ssh: \(error.localizedDescription)"))
                    return
                }

                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Both outputs are a line or two, far below a pipe's buffer,
                // so reading them one after the other cannot deadlock.
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self)
                ))
            }
        }
    }

    /// The live ssh and the write end of its stdin. Closing that pipe is what
    /// ends the remote `cat`; terminating covers an ssh that is still
    /// connecting and has no session to end yet.
    private final class ProcessBox: @unchecked Sendable {
        private var process: Process?
        private var stdin: FileHandle?
        private let lock = NSLock()

        func set(_ process: Process, stdin: FileHandle) {
            lock.lock(); defer { lock.unlock() }
            self.process = process
            self.stdin = stdin
        }

        func terminate() {
            lock.lock()
            let process = process
            let stdin = stdin
            self.process = nil
            self.stdin = nil
            lock.unlock()

            try? stdin?.close()
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// Keeps the last non-empty line ssh wrote to stderr — on failure that is
    /// almost always the reason. Read through a readability handler rather
    /// than a blocking read, so a grandchild holding the pipe open (a
    /// `ProxyCommand`) cannot strand a thread.
    private final class StderrTail: @unchecked Sendable {
        private let handle: FileHandle
        private var partial = ""
        private var last: String?
        private var finished = false
        private let eof = DispatchSemaphore(value: 0)
        private let lock = NSLock()

        init(_ handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    self.close()
                } else {
                    self.append(String(decoding: data, as: UTF8.self))
                }
            }
        }

        var lastLine: String? {
            lock.lock(); defer { lock.unlock() }
            let pending = partial.trimmingCharacters(in: .whitespacesAndNewlines)
            return pending.isEmpty ? last : pending
        }

        func waitForEOF(timeout: TimeInterval) {
            _ = eof.wait(timeout: .now() + timeout)
        }

        func close() {
            lock.lock()
            let first = !finished
            finished = true
            lock.unlock()
            guard first else { return }
            handle.readabilityHandler = nil
            eof.signal()
        }

        /// ssh ends its stderr lines with `\r\n`, which Swift reads as one
        /// `Character` — so split on `isNewline`, never on `"\n"`.
        private func append(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            let lines = (partial + text).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            partial = String(lines.last ?? "")
            for line in lines.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { last = trimmed }
            }
        }
    }

    private final class HomeCache: @unchecked Sendable {
        private var homes: [String: String] = [:]
        private let lock = NSLock()
        subscript(host: String) -> String? {
            get { lock.lock(); defer { lock.unlock() }; return homes[host] }
            set { lock.lock(); homes[host] = newValue; lock.unlock() }
        }
    }
}
