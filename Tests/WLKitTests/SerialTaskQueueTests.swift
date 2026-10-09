import XCTest
@testable import WLKit

/// `SerialTaskQueue` is what keeps two dial detents from typing their slash
/// commands into one line: each item must finish before the next starts.
@MainActor
final class SerialTaskQueueTests: XCTestCase {

    /// Items that sleep for different times — the first longest — still
    /// finish in the order they were enqueued, and never overlap.
    func testItemsRunInOrderWithoutOverlap() async {
        let queue = SerialTaskQueue()
        let sleeps: [UInt64] = [40, 5, 25, 0, 10, 1]
        var finished: [Int] = []
        var inFlight = 0
        var maxInFlight = 0

        var last: Task<Void, Never>?
        for (index, millis) in sleeps.enumerated() {
            last = queue.enqueue {
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                try? await Task.sleep(nanoseconds: millis * 1_000_000)
                finished.append(index)
                inFlight -= 1
            }
        }
        await last?.value

        XCTAssertEqual(finished, Array(sleeps.indices))
        XCTAssertEqual(maxInFlight, 1)
    }

    /// An item enqueued after the queue has drained starts on its own, and
    /// one enqueued while another runs waits for it.
    func testQueueKeepsWorkingAfterDraining() async {
        let queue = SerialTaskQueue()
        var log: [String] = []

        await queue.enqueue { log.append("a") }.value

        let first = queue.enqueue {
            try? await Task.sleep(nanoseconds: 20_000_000)
            log.append("b")
        }
        let second = queue.enqueue { log.append("c") }
        await second.value

        XCTAssertEqual(log, ["a", "b", "c"])
        await first.value
    }
}
