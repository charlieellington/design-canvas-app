// Tests for RouteFrame struct properties and computed values.

import XCTest
@testable import DesignCanvas

final class RouteFrameTests: XCTestCase {

    func testDefaultDimensions() {
        let frame = RouteFrame(id: UUID(), path: "/", x: 0, y: 0, zIndex: 0)
        XCTAssertEqual(frame.width, 1280)
        XCTAssertEqual(frame.height, 800)
    }

    func testEffectiveHeightEqualsHeight() {
        let frame = RouteFrame(id: UUID(), path: "/", x: 0, y: 0, width: 1280, height: 600, zIndex: 0)
        XCTAssertEqual(frame.effectiveHeight, 600)
    }

    func testLabelTextShowsPath() {
        let frame = RouteFrame(id: UUID(), path: "/dashboard", x: 0, y: 0, zIndex: 0)
        XCTAssertEqual(frame.labelText, "/dashboard")
    }

    func testLabelTextShowsDisplayName() {
        var frame = RouteFrame(id: UUID(), path: "/dashboard", x: 0, y: 0, zIndex: 0)
        frame.displayName = "Main Dashboard"
        XCTAssertEqual(frame.labelText, "Main Dashboard")
    }

    func testLabelTextIgnoresEmptyDisplayName() {
        var frame = RouteFrame(id: UUID(), path: "/dashboard", x: 0, y: 0, zIndex: 0)
        frame.displayName = "   "
        XCTAssertEqual(frame.labelText, "/dashboard")
    }

    func testUrlPathIsNilByDefault() {
        let frame = RouteFrame(id: UUID(), path: "/home", x: 0, y: 0, zIndex: 0)
        XCTAssertNil(frame.urlPath)
    }
}
