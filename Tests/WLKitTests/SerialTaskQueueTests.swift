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

    /// The queue itself drops nothing, so an item still waiting when the
    /// target changes starts after the switch. `TuneController` handles that
    /// by taking its generation at enqueue time; this is that rule, with a
    /// blocked item ahead and the generation bumped while it is blocked.
    /// (`TuneController` lives in the app target and talks to Herdr and a
    /// panel singleton directly, so it is not driven here.)
    func testItemQueuedBeforeAGenerationBumpDropsItself() async {
        let queue = SerialTaskQueue()
        var generation = 0
        var log: [String] = []
        var release: CheckedContinuation<Void, Never>?

        let blocker = queue.enqueue {
            await withCheckedContinuation { release = $0 }
            log.append("blocker")
        }
        let staleGeneration = generation
        queue.enqueue {
            guard staleGeneration == generation else { return }
            log.append("stale")
        }
        while release == nil { await Task.yield() }

        generation += 1
        let freshGeneration = generation
        let fresh = queue.enqueue {
            guard freshGeneration == generation else { return }
            log.append("fresh")
        }

        release?.resume()
        await fresh.value

        XCTAssertEqual(log, ["blocker", "fresh"])
        await blocker.value
    }
}
