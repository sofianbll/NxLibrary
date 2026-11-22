import Foundation
import XCTest
@testable import ArcanePorting

final class NextendoOnlineCountsTests: XCTestCase {
    func testCountsIgnoreUnknownIDsAndZeroAndNormalizeCase() throws {
        let data = Data(#"{"counts":{"01000000000000AB":4,"01000000000000ab":2,"01000000000000bb":0,"+000000000000000":99,"other":42}}"#.utf8)
        XCTAssertEqual(try NextendoOnlineCounts.decode(data), ["01000000000000ab": 4])
        XCTAssertThrowsError(try NextendoOnlineCounts.decode(Data(#"{"counts":[]}"#.utf8)))
    }
}
