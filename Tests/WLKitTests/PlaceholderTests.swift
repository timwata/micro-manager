import XCTest
@testable import WLKit

final class PlaceholderTests: XCTestCase {
    func testPadGeometry() {
        XCTAssertEqual(Pad.rows.flatMap { $0 }.count, Pad.keyCount)
        // Reading order is index order: key 0 is the top-left key.
        XCTAssertEqual(Pad.agentKeyIDs, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(Pad.displayRows.flatMap { $0 }.compactMap { $0 }.sorted(),
                       Pad.rows.flatMap { $0 }.sorted())
        // Every display row spans the pad's four columns, so gaps line up.
        XCTAssertEqual(Pad.displayRows.map(\.count), [4, 4, 4, 4])
        XCTAssertEqual(Pad.displayRows.first, [nil, 0, 1, nil])
        XCTAssertEqual(Pad.displayRows.last, [nil, 10, 11, 12])
    }
}
