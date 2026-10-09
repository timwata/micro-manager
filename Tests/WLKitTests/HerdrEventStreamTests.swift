import XCTest
@testable import WLKit

final class HerdrEventStreamTests: XCTestCase {

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

    /// A subscription the server refuses would otherwise sit forever with no
    /// events; it must close, with the server's reason, so the bridge's retry
    /// and poll take over.
    func testARejectedSubscriptionClosesWithTheAPIErrorAndIsNeverReady() async throws {
        let server = try FakeHerdrServer()
        HerdrClient.setSocketPath(server.path)

        // Counted rather than an inverted expectation: a fulfilled inverted
        // expectation ends `fulfillment(of:)` early without reporting it.
        var readyCalls = 0
        let closed = expectation(description: "onClosed")
        var closeError: Error?

        let stream = HerdrEventStream(subscriptions: [["type": "pane.created"]])
        stream.onReady = { readyCalls += 1 }
        stream.onEvent = { _ in XCTFail("an event arrived on a rejected subscription") }
        stream.onClosed = { error in
            closeError = error
            closed.fulfill()
        }
        stream.start()

        await server.receiveRequest()
        server.reply(#"{"id":"wl_sub","error":{"message":"nope"}}"#)
        // A pushed line after the refusal must not be taken as an event.
        server.reply(#"{"event":"pane.created"}"#)

        await fulfillment(of: [closed], timeout: 1)
        // Every callback is dispatched to main in socket order, so an
        // `onReady` sent before the close has run by now.
        XCTAssertEqual(readyCalls, 0, "a rejected subscription was reported ready")
        guard case HerdrError.api(let message)? = closeError else {
            return XCTFail("closed with \(String(describing: closeError)), not .api")
        }
        XCTAssertEqual(message, "nope")
        stream.stop()
    }

    /// The control for the test above: a successful acknowledgement makes the
    /// stream ready, and the next line is delivered as an event.
    func testAnAcknowledgedSubscriptionIsReadyAndDeliversEvents() async throws {
        let server = try FakeHerdrServer()
        HerdrClient.setSocketPath(server.path)

        let ready = expectation(description: "onReady")
        let event = expectation(description: "onEvent")
        var received: [String: Any]?

        let stream = HerdrEventStream(subscriptions: [["type": "pane.created"]])
        stream.onReady = { ready.fulfill() }
        stream.onEvent = { object in
            received = object
            event.fulfill()
        }
        stream.onClosed = { error in XCTFail("closed: \(String(describing: error))") }
        stream.start()

        await server.receiveRequest()
        server.reply(#"{"id":"wl_sub","result":{}}"#)
        server.reply(#"{"event":"pane.created"}"#)

        await fulfillment(of: [ready, event], timeout: 1, enforceOrder: true)
        XCTAssertEqual(received?["event"] as? String, "pane.created")
        stream.stop()
    }
}
