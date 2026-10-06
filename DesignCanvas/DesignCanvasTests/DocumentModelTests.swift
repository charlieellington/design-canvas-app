// Tests for DocumentModel route management and URL building.

import XCTest
@testable import DesignCanvas

@MainActor
final class DocumentModelTests: XCTestCase {

    func testDemoUsesBundledScreenshotsWithoutLivePromotion() {
        let model = DocumentModel()
        model.loadDemoRoutes()
        XCTAssertEqual(model.routes.count, 6)
        XCTAssertEqual(model.screenshots.count, 6)
        let camera = CanvasCamera()
        let router = InteractionRouter()
        let lifecycle = TileLifecycle(camera: camera, document: model, router: router)
        let view = CanvasDocumentView(frame: .zero)
        view.addSubview(CanvasFrameContainer(route: model.routes[0]))
        router.canvasDocumentView = view
        router.document = model
        lifecycle.isInDemoMode = true
        let id = model.routes[0].id
        lifecycle.registerFrame(id)
        withExtendedLifetime((view, camera, router)) { lifecycle.promote(frameId: id) }
        XCTAssertEqual(lifecycle.frameStates[id], .screenshot)
    }

    func testDemoCaptureReturnsBundledImages() async {
        let model = DocumentModel()
        model.loadDemoRoutes()
        let original = AppServices.shared.demo.isInDemoMode
        AppServices.shared.demo.isInDemoMode = true
        defer { AppServices.shared.demo.isInDemoMode = original }
        let manager = CanvasManager(document: model, screenshotService: ScreenshotService(document: model))
        let captures = await manager.captureAll()
        XCTAssertEqual(captures.count, 6)
        XCTAssertTrue(captures.allSatisfy { $0["filePath"]?.hasPrefix(Bundle.main.bundlePath) == true })
    }

    func testEmptyByDefault() {
        let model = DocumentModel()
        XCTAssertTrue(model.routes.isEmpty)
        XCTAssertTrue(model.screenshots.isEmpty)
    }

    private func bindLocalServer(_ model: DocumentModel) {
        let binding = ServerBinding(
            id: UUID(), origin: URL(string: "http://localhost:3000")!, displayName: "Fictional demo",
            projectDir: nil, packageName: nil, gitRemote: nil, lastSeenAt: Date(), status: .connected
        )
        model.bindings = [binding]
        model.primaryBindingId = binding.id
    }

    func testURLForSimplePath() {
        let model = DocumentModel()
        bindLocalServer(model)
        let url = model.url(forPath: "/about")
        XCTAssertEqual(url?.absoluteString, "http://localhost:3000/about")
    }

    func testURLForAbsoluteURL() {
        let model = DocumentModel()
        let url = model.url(forPath: "https://example.com/page")
        XCTAssertEqual(url?.absoluteString, "https://example.com/page")
    }

    func testURLStripsMobileSuffix() {
        let model = DocumentModel()
        bindLocalServer(model)
        let url = model.url(forPath: "/ (mobile)")
        XCTAssertEqual(url?.absoluteString, "http://localhost:3000/")
    }

    func testURLUsesRouteUrlPath() {
        let model = DocumentModel()
        bindLocalServer(model)
        model.routes = [
            RouteFrame(id: UUID(), path: "/blog/[slug]", x: 0, y: 0, width: 1280, height: 800, zIndex: 0, urlPath: "/blog/mock-slug")
        ]
        let url = model.url(forPath: "/blog/[slug]")
        XCTAssertEqual(url?.absoluteString, "http://localhost:3000/blog/mock-slug")
    }

    func testMergeDiscoveredRoutesAddsNewRoutes() {
        let model = DocumentModel()
        let discovered = [
            DiscoveredRoute(label: "/home", urlPath: "/home"),
            DiscoveredRoute(label: "/about", urlPath: "/about"),
        ]
        model.mergeDiscoveredRoutes(discovered)
        // Wait briefly for stagger task
        let expectation = XCTestExpectation(description: "stagger")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(model.routes.count, 2)
    }

    func testMergeDiscoveredRoutesKeepsRemovedFrameForRecovery() {
        let model = DocumentModel()
        model.routes = [
            RouteFrame(id: UUID(), path: "/old-page", x: 0, y: 0, width: 1280, height: 800, zIndex: 0)
        ]
        let discovered = [
            DiscoveredRoute(label: "/home", urlPath: "/home"),
        ]
        model.mergeDiscoveredRoutes(discovered)
        // Discovery keeps a ghost frame so the layout can recover when its source returns.
        let old = model.routes.first(where: { $0.path == "/old-page" })
        XCTAssertNotNil(old)
        XCTAssertTrue(old?.isRemoved == true)
        let originalID = old?.id
        model.mergeDiscoveredRoutes([DiscoveredRoute(label: "/old-page", urlPath: "/old-page")])
        XCTAssertEqual(model.routes.first(where: { $0.path == "/old-page" })?.id, originalID)
        XCTAssertFalse(model.routes.first(where: { $0.path == "/old-page" })?.isRemoved ?? true)
    }

    func testMergeDiscoveredRoutesPreservesExistingPositions() {
        let model = DocumentModel()
        let existingRoute = RouteFrame(id: UUID(), path: "/home", x: 100, y: 200, width: 1280, height: 800, zIndex: 0)
        model.routes = [existingRoute]
        let discovered = [
            DiscoveredRoute(label: "/home", urlPath: "/home"),
            DiscoveredRoute(label: "/about", urlPath: "/about"),
        ]
        model.mergeDiscoveredRoutes(discovered)
        // /home should keep its position
        let home = model.routes.first(where: { $0.path == "/home" })
        XCTAssertEqual(home?.x, 100)
        XCTAssertEqual(home?.y, 200)
    }

    func testMergeIdempotent() {
        let model = DocumentModel()
        let discovered = [
            DiscoveredRoute(label: "/home", urlPath: "/home"),
        ]
        model.mergeDiscoveredRoutes(discovered)
        let expectation = XCTestExpectation(description: "stagger")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2.0)
        let countAfterFirst = model.routes.count

        // Merge same routes again
        model.mergeDiscoveredRoutes(discovered)
        let expectation2 = XCTestExpectation(description: "stagger2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expectation2.fulfill() }
        wait(for: [expectation2], timeout: 2.0)
        XCTAssertEqual(model.routes.count, countAfterFirst)
    }
}
