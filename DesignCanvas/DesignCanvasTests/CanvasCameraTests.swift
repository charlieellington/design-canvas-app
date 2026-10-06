// Tests for CanvasCamera zoom clamping and coordinate math.

import XCTest
@testable import DesignCanvas

@MainActor
final class CanvasCameraTests: XCTestCase {

    func testClampedZoomAtMinimum() {
        let camera = CanvasCamera()
        XCTAssertEqual(camera.clampedZoom(0.05), 0.1)
    }

    func testClampedZoomAtMaximum() {
        let camera = CanvasCamera()
        XCTAssertEqual(camera.clampedZoom(5.0), 3.0)
    }

    func testClampedZoomPassthrough() {
        let camera = CanvasCamera()
        XCTAssertEqual(camera.clampedZoom(1.0), 1.0)
        XCTAssertEqual(camera.clampedZoom(0.5), 0.5)
        XCTAssertEqual(camera.clampedZoom(2.5), 2.5)
    }

    func testClampedZoomEdgeCases() {
        let camera = CanvasCamera()
        XCTAssertEqual(camera.clampedZoom(0.1), 0.1)
        XCTAssertEqual(camera.clampedZoom(3.0), 3.0)
        XCTAssertEqual(camera.clampedZoom(-1.0), 0.1)
    }

    func testVisibleRectScalesWithZoom() {
        let camera = CanvasCamera()
        camera.zoom = 1.0
        camera.viewportPixelSize = CGSize(width: 1200, height: 800)
        let rect = camera.visibleRect
        XCTAssertEqual(rect.width, 1200)
        XCTAssertEqual(rect.height, 800)
    }

    func testVisibleRectZoomedOut() {
        let camera = CanvasCamera()
        camera.zoom = 0.5
        camera.viewportPixelSize = CGSize(width: 1200, height: 800)
        let rect = camera.visibleRect
        XCTAssertEqual(rect.width, 2400)
        XCTAssertEqual(rect.height, 1600)
    }

    func testClampedOriginStaysInBounds() {
        let camera = CanvasCamera()
        camera.zoom = 1.0
        camera.viewportPixelSize = CGSize(width: 1200, height: 800)
        // Negative origin should clamp to zero
        let clamped = camera.clampedOrigin(CGPoint(x: -100, y: -200))
        XCTAssertEqual(clamped.x, 0)
        XCTAssertEqual(clamped.y, 0)
    }

    func testCanvasCenterIsExpectedValue() {
        XCTAssertEqual(CanvasCamera.canvasCenter.x, 25000)
        XCTAssertEqual(CanvasCamera.canvasCenter.y, 25000)
    }
}
