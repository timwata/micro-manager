import Foundation

/// A Herdr server on another machine, reached by forwarding its socket over
/// SSH. Declared under a top-level `"remotes"` array in the same
/// `config.json` that `KeyBindings` reads:
///
///     {
///       "remotes": [
///         { "name": "workbox", "host": "workbox" },
///         { "name": "gpu", "host": "me@gpu-box", "socket": "/run/user/1000/herdr.sock" }
///       ]
///     }
///
/// `host` is handed to the system `ssh` untouched, so anything it accepts as a
/// destination works — `~/.ssh/config` aliases, `ProxyJump`, identities.
public struct HerdrRemote: Equatable, Sendable, Identifiable {
    /// Label in the picker, and the key the selection is persisted under —
    /// hence unique.
    public var name: String
    public var host: String
    /// Socket path on the remote machine; nil means `defaultSocket`. A
    /// leading `~/` refers to the *remote* home directory.
    public var socket: String?

    public var id: String { name }

    /// Where Herdr puts its socket when `XDG_CONFIG_HOME` is unset, which is
    /// the common case on a server.
    public static let defaultSocket = "~/.config/herdr/herdr.sock"

    /// The remote socket path to forward to, default applied.
    public var remoteSocket: String { socket ?? Self.defaultSocket }

    public init(name: String, host: String, socket: String? = nil) {
        self.name = name
        self.host = host
        self.socket = socket
    }
}

/// Which single Herdr server the pad mirrors. One at a time: mixing agents
/// from several servers on one pad is deliberately out of scope.
public enum HerdrTarget: Equatable, Sendable {
    case local
    case remote(HerdrRemote)
}

public enum HerdrRemotes {

    /// Read fresh on every call so config edits show up without a relaunch.
    /// Reads the file independently of `KeyBindings` rather than growing that
    /// type: remotes are about where Herdr lives, not what the keys do.
    public static func load() -> [HerdrRemote] {
        guard let data = FileManager.default.contents(atPath: KeyBindings.configPath()) else {
            return []
        }
        return parse(data)
    }

    /// Same tolerance as `KeyBindings.parse`: a malformed file or entry is
    /// skipped rather than failing, since the worst outcome of a typo should
    /// be a missing picker entry, not a broken app.
    static func parse(_ data: Data) -> [HerdrRemote] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = json["remotes"] as? [Any]
        else { return [] }

        var remotes: [HerdrRemote] = []
        var seen = Set<String>()
        for entry in entries {
            guard let object = entry as? [String: Any],
                  let name = nonEmpty(object["name"]),
                  let host = nonEmpty(object["host"]),
                  // Names key the persisted selection, so a duplicate would be
                  // unreachable anyway; the first one wins, as in a dictionary
                  // literal read top to bottom.
                  seen.insert(name).inserted
            else { continue }
            remotes.append(HerdrRemote(name: name, host: host, socket: nonEmpty(object["socket"])))
        }
        return remotes
    }

    /// Whitespace-only counts as empty: `" "` is never a usable name, host or
    /// path, and a picker entry that renders as blank is worse than none.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return string
    }
}
