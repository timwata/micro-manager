import XCTest
@testable import WLKit

/// `nextLandStep` is what keeps a confirmed land from pushing branches the
/// user never saw: the plan is re-read after every land, and anything new in
/// it must be left alone.
final class GitButlerLandStepTests: XCTestCase {

    /// A confirmed stack lands bottom up, one re-read plan at a time, and
    /// finishes once the plan is empty.
    func testConfirmedStackLandsBottomUp() {
        let confirmed = ["bottom", "middle", "top"]
        var landed = Set<String>()
        var plan = confirmed
        var order: [String] = []

        while case .land(let branch) = GitButler.nextLandStep(
            plan: plan, confirmed: confirmed, landed: landed
        ) {
            order.append(branch)
            landed.insert(branch)
            plan.removeFirst()
        }

        XCTAssertEqual(order, confirmed)
        XCTAssertEqual(GitButler.nextLandStep(plan: plan, confirmed: confirmed, landed: landed), .done)
    }

    /// A branch that appeared under the confirmed ones must not be landed,
    /// and must not be skipped either: landing past it would go out of order.
    func testNewBranchInFrontOfConfirmedOnesStops() {
        let step = GitButler.nextLandStep(
            plan: ["sneaky", "middle", "top"],
            confirmed: ["bottom", "middle", "top"],
            landed: ["bottom"]
        )
        XCTAssertEqual(step, .stop(
            "`sneaky` was not in the confirmed plan; stopping before it. Not landed: middle, top."
        ))
    }

    /// Once everything confirmed has landed, a branch that showed up since is
    /// simply left in the workspace.
    func testNewBranchAfterEveryConfirmedOneIsLeftAlone() {
        let step = GitButler.nextLandStep(
            plan: ["later"],
            confirmed: ["bottom", "top"],
            landed: ["bottom", "top"]
        )
        XCTAssertEqual(step, .done)
    }

    /// A land that reported success but left its branch in place must not be
    /// retried in a loop.
    func testBranchStillPresentAfterLandingStops() {
        let step = GitButler.nextLandStep(
            plan: ["bottom", "top"],
            confirmed: ["bottom", "top"],
            landed: ["bottom"]
        )
        XCTAssertEqual(step, .stop("`bottom` is still in the workspace after landing it; stopping here."))
    }

    func testEmptyPlanIsDone() {
        XCTAssertEqual(GitButler.nextLandStep(plan: [], confirmed: ["a"], landed: []), .done)
    }
}
