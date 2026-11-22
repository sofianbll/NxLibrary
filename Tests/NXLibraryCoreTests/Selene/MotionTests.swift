import NXLibraryCore
import XCTest

final class MotionTests: XCTestCase {
    func testReducedMotionStopsFocusRailsAndPagesButAllowsFades() {
        XCTAssertNil(Motion.focus(true))
        XCTAssertNil(Motion.focus(true, entering: false))
        XCTAssertNil(Motion.rail(true, .spotlight))
        XCTAssertNil(Motion.rail(true, .collection))
        XCTAssertNil(Motion.screen(true))
        XCTAssertNotNil(Motion.rail(false, .spotlight))
        XCTAssertNotNil(Motion.rail(false, .collection))
        XCTAssertNotNil(Motion.overlay(true))
        XCTAssertNotNil(Motion.anchoredCard(true))
        XCTAssertNotNil(Motion.toast(true))
    }
}
