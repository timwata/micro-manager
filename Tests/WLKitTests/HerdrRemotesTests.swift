import XCTest
@testable import WLKit

final class HerdrRemotesTests: XCTestCase {

    private func parse(_ json: String) -> [HerdrRemote] {
        HerdrRemotes.parse(Data(json.utf8))
    }

    func testParsesRemotesInFileOrder() {
        let remotes = parse(#"""
        {"remotes": [
          {"name": "workbox", "host": "workbox"},
          {"name": "gpu", "host": "me@gpu-box", "socket": "/run/user/1000/herdr.sock"}
        ]}
        """#)
        XCTAssertEqual(remotes, [
            HerdrRemote(name: "workbox", host: "workbox"),
            HerdrRemote(name: "gpu", host: "me@gpu-box", socket: "/run/user/1000/herdr.sock"),
        ])
    }

    func testSocketDefaultsToHerdrsOwnPath() {
        let remote = parse(#"{"remotes": [{"name": "a", "host": "a"}]}"#).first
        XCTAssertNil(remote?.socket)
        XCTAssertEqual(remote?.remoteSocket, "~/.config/herdr/herdr.sock")
        XCTAssertEqual(HerdrRemote.defaultSocket, "~/.config/herdr/herdr.sock")
    }

    /// An empty `socket` is a typo, not a request for an empty path.
    func testEmptySocketMeansDefault() {
        let remote = parse(#"{"remotes": [{"name": "a", "host": "a", "socket": ""}]}"#).first
        XCTAssertNil(remote?.socket)
        XCTAssertEqual(remote?.remoteSocket, HerdrRemote.defaultSocket)
    }

    func testEntriesWithoutNameOrHostAreSkipped() {
        let remotes = parse(#"""
        {"remotes": [
          {"host": "nameless"},
          {"name": "hostless"},
          {"name": "", "host": "empty-name"},
          {"name": "blank-host", "host": "  "},
          {"name": 3, "host": "numeric-name"},
          "not an object",
          {"name": "ok", "host": "ok"}
        ]}
        """#)
        XCTAssertEqual(remotes, [HerdrRemote(name: "ok", host: "ok")])
    }

    /// The name keys the persisted selection, so a second entry with the same
    /// name could never be chosen; the first one wins.
    func testDuplicateNamesKeepTheFirst() {
        let remotes = parse(#"""
        {"remotes": [
          {"name": "box", "host": "first"},
          {"name": "other", "host": "other"},
          {"name": "box", "host": "second"}
        ]}
        """#)
        XCTAssertEqual(remotes.map(\.host), ["first", "other"])
    }

    /// Stray spaces would otherwise reach ssh as part of the hostname or
    /// socket path, and make `"box "` a second, look-alike `"box"`.
    func testValuesAreTrimmed() {
        let remotes = parse(#"""
        {"remotes": [
          {"name": " box ", "host": " workbox\n", "socket": " /run/user/1000/herdr.sock "},
          {"name": "box", "host": "second"}
        ]}
        """#)
        XCTAssertEqual(remotes, [
            HerdrRemote(name: "box", host: "workbox", socket: "/run/user/1000/herdr.sock"),
        ])
    }

    /// ssh would read a leading `-` as an option — `-oProxyCommand=…` runs a
    /// command — so such a host is never a destination.
    func testHostsStartingWithADashAreSkipped() {
        let remotes = parse(#"""
        {"remotes": [
          {"name": "evil", "host": "-oProxyCommand=sh -c id"},
          {"name": "typo", "host": " -workbox"},
          {"name": "ok", "host": "me@ok-box"}
        ]}
        """#)
        XCTAssertEqual(remotes, [HerdrRemote(name: "ok", host: "me@ok-box")])
    }

    func testMalformedFileYieldsNoRemotes() {
        XCTAssertEqual(parse("not json"), [])
        XCTAssertEqual(parse(#"["remotes"]"#), [])
        XCTAssertEqual(parse(#"{"remotes": "workbox"}"#), [])
        XCTAssertEqual(parse(#"{"remotes": {"name": "a", "host": "a"}}"#), [])
    }

    /// A config that only binds keys — every config written before remotes
    /// existed — simply has none.
    func testAbsentKeyYieldsNoRemotes() {
        XCTAssertEqual(parse("{}"), [])
        XCTAssertEqual(parse(#"{"keys": {"9": "Ship it"}}"#), [])
    }

    /// Remotes sit in the same file as the key bindings; neither parser may
    /// trip over the other's section.
    func testKeyBindingsIgnoreTheRemotesSection() {
        let json = #"{"keys": {"9": "Ship it"}, "remotes": [{"name": "a", "host": "a"}]}"#
        XCTAssertEqual(KeyBindings.parse(Data(json.utf8)).text(for: 9), "Ship it")
        XCTAssertEqual(parse(json).map(\.name), ["a"])
    }

    func testRemoteIsIdentifiedByName() {
        XCTAssertEqual(HerdrRemote(name: "gpu", host: "me@gpu-box").id, "gpu")
    }

    // MARK: - Resolving the persisted selection

    private let configured = [
        HerdrRemote(name: "workbox", host: "workbox"),
        HerdrRemote(name: "gpu", host: "me@gpu-box"),
    ]

    func testNoSelectionIsThisMac() {
        XCTAssertEqual(HerdrRemotes.target(named: nil, in: configured), .local)
    }

    func testSelectionResolvesToTheConfiguredEntry() {
        XCTAssertEqual(HerdrRemotes.target(named: "gpu", in: configured), .remote(configured[1]))
    }

    /// Only the name is persisted, so an edit to the entry is picked up.
    func testSelectionFollowsAnEditedEntry() {
        let edited = [HerdrRemote(name: "gpu", host: "me@new-gpu-box", socket: "/tmp/h.sock")]
        XCTAssertEqual(HerdrRemotes.target(named: "gpu", in: edited), .remote(edited[0]))
    }

    /// A remote removed from the config, or no config at all, is this Mac
    /// rather than a host nobody configured any more.
    func testUnknownSelectionFallsBackToThisMac() {
        XCTAssertEqual(HerdrRemotes.target(named: "gone", in: configured), .local)
        XCTAssertEqual(HerdrRemotes.target(named: "gpu", in: []), .local)
    }

    func testTargetNameRoundTrips() {
        XCTAssertNil(HerdrTarget.local.remoteName)
        XCTAssertEqual(HerdrTarget.remote(configured[0]).remoteName, "workbox")
        for target in [HerdrTarget.local, .remote(configured[0]), .remote(configured[1])] {
            XCTAssertEqual(HerdrRemotes.target(named: target.remoteName, in: configured), target)
        }
    }
}
