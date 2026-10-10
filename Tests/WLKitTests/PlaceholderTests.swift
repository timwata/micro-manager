import XCTest
@testable import WLKit

final class PlaceholderTests: XCTestCase {
    func testPadGeometry() {
        XCTAssertEqual(Pad.rows.flatMap { $0 }.count, Pad.keyCount)
        // Reading order: the top row is wired right to left.
        XCTAssertEqual(Pad.agentKeyIDs, [1, 0, 2, 3, 4, 5])
        XCTAssertEqual(Pad.displayRows.flatMap { $0 }.compactMap { $0 }.sorted(),
                       Pad.rows.flatMap { $0 }.sorted())
        // Every display row spans the pad's four columns, so gaps line up.
        XCTAssertEqual(Pad.displayRows.map(\.count), [4, 4, 4, 4])
        XCTAssertEqual(Pad.displayRows.first, [nil, 1, 0, nil])
        XCTAssertEqual(Pad.displayRows.last, [nil, 10, 11, 12])
    }
}
