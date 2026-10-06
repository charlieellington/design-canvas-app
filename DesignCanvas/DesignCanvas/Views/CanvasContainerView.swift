// NSViewRepresentable bridging NSScrollView into SwiftUI. Provides pan, zoom, momentum scrolling.
// Wires CanvasScrollCoordinator for camera sync and renders route frames from DocumentModel.
// Stage 5: TileLifecycle manages WKWebView pool and LOD state machine.
// Stage 10: HintCard management — shows/hides based on route count.

import SwiftUI
import AppKit
import WebKit

struct CanvasContainerView: NSViewRepresentable {

    let camera: CanvasCamera
    let document: DocumentModel
    let interactionRouter: InteractionRouter
    let interactHintCoordinator: InteractHintCoordinator
    /// Passed through so frame containers render demo chrome (watermark + accent border).
    let isInDemoMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(camera: camera, document: document, interactionRouter: interactionRouter, interactHintCoordinator: interactHintCoordinator)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let canvasColor = NSColor(
            red: 0x11 / 255.0,
            green: 0x12 / 255.0,
            blue: 0x14 / 255.0,
            alpha: 1.0
        )

        let documentView = CanvasDocumentView(
            frame: NSRect(x: 0, y: 0, width: 50000, height: 50000)
        )
        documentView.interactionRouter = interactionRouter
        documentView.camera = camera

        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 3.0
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = canvasColor

        context.coordinator.scrollCoordinator.document = document
        context.coordinator.scrollCoordinator.interactionRouter = interactionRouter
        context.coordinator.scrollCoordinator.attach(to: scrollView)
        context.coordinator.documentView = documentView

        // Stage 14b — wire the styling renderer to the canvas matte. applyBackground
        // paints the gradient / wallpaper / image layer behind every frame so the
        // user sees a live preview of what the exported share will look like.
        documentView.wantsLayer = true
        CanvasStylingRenderer.shared.canvasBackgroundView = documentView
        CanvasStylingRenderer.shared.applyBackground(document.styling)

        // Wire InteractionRouter's canvas document view reference for focus management
        interactionRouter.document = document
        interactionRouter.canvasDocumentView = documentView

        // Install EventInterceptor for Escape/Spacebar/Pinch/Return
        context.coordinator.eventInterceptor.install(router: interactionRouter)

        // Stage 5: Attach TileLifecycle to observe viewport changes
        context.coordinator.tileLifecycle.screenshotService = AppServices.shared.screenshotService
        context.coordinator.tileLifecycle.isInDemoMode = isInDemoMode
        context.coordinator.tileLifecycle.attach(to: scrollView)

        // Listen for zoom-to-fit-all notification from toolbar
        NotificationCenter.default.addObserver(
            forName: Notification.Name("zoomToFitAll"),
            object: nil,
            queue: .main
        ) { [weak scrollCoord = context.coordinator.scrollCoordinator] _ in
            scrollCoord?.resetAndZoomToFit()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.tileLifecycle.isInDemoMode = isInDemoMode
        // Zoom to fit all frames on first layout pass with real contentSize
        context.coordinator.scrollCoordinator.zoomToFitIfNeeded()

        // Diff frames onto the canvas. We now track three kinds: .route (existing pool),
        // .markdown (separate MarkdownTileManager cap), .image (always live, lightweight).
        guard let documentView = context.coordinator.documentView else { return }
        let existingFrames = documentView.subviews.compactMap { $0 as? CanvasFrameContainer }
        let existingSections = documentView.subviews.compactMap { $0 as? CanvasSectionView }
        let routeIds = Set(document.routes.map(\.id))
        let documentIds = Set(document.documents.map(\.id))
        let imageIds = Set(document.images.map(\.id))
        let sectionIds = Set(document.sections.map(\.id))

        // Sections render UNDER frames — diff them first so newly added sections sit at
        // the back of the subview z-order. hitTest returns nil on CanvasSectionView so
        // mouse events fall through to frames + canvas background as expected.
        for sectionView in existingSections where !sectionIds.contains(sectionView.sectionId) {
            sectionView.removeFromSuperview()
        }
        for section in document.sections {
            let frame = NSRect(x: section.x, y: section.y, width: section.width, height: section.height)
            if let existing = existingSections.first(where: { $0.sectionId == section.id }) {
                existing.updateContent(title: section.title, frame: frame)
            } else {
                let view = CanvasSectionView(sectionId: section.id, title: section.title, frame: frame)
                // Insert at the bottom of the subview stack so frames render on top.
                documentView.addSubview(view, positioned: .below, relativeTo: nil)
            }
        }
        let tileLifecycle = context.coordinator.tileLifecycle
        let markdownTileManager = context.coordinator.markdownTileManager

        // Remove frames no longer in model — kind-aware so markdown/image containers
        // aren't mistakenly orphaned by the route-id check.
        for frame in existingFrames {
            let alive: Bool
            switch frame.kind {
            case .route:    alive = routeIds.contains(frame.routeId)
            case .markdown: alive = documentIds.contains(frame.routeId)
            case .image:    alive = imageIds.contains(frame.routeId)
            }
            if !alive {
                switch frame.kind {
                case .route:    tileLifecycle.unregisterFrame(frame.routeId)
                case .markdown: markdownTileManager.unregister(id: frame.routeId)
                case .image:    break
                }
                frame.shadowHost?.removeFromSuperview()
                frame.removeFromSuperview()
            }
        }

        // Add or update frames — TileLifecycle decides which get live WKWebViews
        for route in document.routes {
            if let existing = existingFrames.first(where: { $0.routeId == route.id }) {
                if !interactionRouter.draggingFrameIds.contains(route.id) {
                    existing.update(route: route)
                } else {
                    // During drag: still update route path (for Change Route), skip position
                    existing.updateContentOnly(route: route)
                }
                existing.tileLifecycle = tileLifecycle
                existing.isDemoMode = isInDemoMode
                // Show screenshot for non-live frames when available
                if tileLifecycle.frameStates[route.id] == .screenshot,
                   let url = document.screenshots[route.id] {
                    existing.showScreenshot(fileURL: url)
                }

                // React to route removal/restoration transitions
                if route.isRemoved && !existing.wasRemoved {
                    tileLifecycle.handleRouteRemoved(frameId: route.id)
                    existing.wasRemoved = true
                    existing.applyVisualState()
                } else if !route.isRemoved && existing.wasRemoved {
                    tileLifecycle.handleRouteRestored(frameId: route.id)
                    existing.wasRemoved = false
                    existing.applyVisualState()
                }
            } else {
                let container = CanvasFrameContainer(route: route)
                container.interactionRouter = interactionRouter
                container.documentView = documentView
                container.camera = camera
                container.tileLifecycle = tileLifecycle
                container.interactHintCoordinator = context.coordinator.interactHintCoordinator
                container.isDemoMode = isInDemoMode
                container.update(route: route)
                documentView.addSubview(container)
                tileLifecycle.registerFrame(route.id)

                // Show screenshot if available (Stage 4)
                if let url = document.screenshots[route.id] {
                    container.showScreenshot(fileURL: url)
                }

                // New frames for already-removed routes start in ghost state
                if route.isRemoved {
                    container.wasRemoved = true
                    container.applyVisualState()
                }
            }
        }

        // Markdown documents — add or update. NOT registered with tileLifecycle (they use
        // their own MarkdownTileManager cap).
        for doc in document.documents {
            if let existing = existingFrames.first(where: { $0.kind == .markdown && $0.routeId == doc.id }) {
                existing.update(markdown: doc)
            } else {
                let container = CanvasFrameContainer(markdown: doc)
                container.interactionRouter = interactionRouter
                container.documentView = documentView
                container.camera = camera
                container.interactHintCoordinator = context.coordinator.interactHintCoordinator
                documentView.addSubview(container)
            }
        }

        // Images — add or update. No pool at all (NSImageView is cheap).
        for img in document.images {
            if let existing = existingFrames.first(where: { $0.kind == .image && $0.routeId == img.id }) {
                existing.update(image: img)
            } else {
                let container = CanvasFrameContainer(image: img)
                container.interactionRouter = interactionRouter
                container.documentView = documentView
                container.camera = camera
                container.interactHintCoordinator = context.coordinator.interactHintCoordinator
                documentView.addSubview(container)
            }
        }

        // TileLifecycle decides promotions/demotions based on viewport.
        // Use scheduleRecalc() — not recalculate() — to debounce the frequent
        // SwiftUI re-renders that updateNSView receives. Calling recalculate()
        // directly here caused a promote→demote→re-render→recalculate storm.
        tileLifecycle.scheduleRecalc()

        // Markdown LOD cap: promote visible markdown frames to live, evict over-cap ones
        // to "click to load" placeholders. Runs every update cycle — cheap O(n) over
        // markdown containers only.
        let containers = documentView.subviews.compactMap { $0 as? CanvasFrameContainer }
        let visibleRect = scrollView.documentVisibleRect
        markdownTileManager.recalculate(visibleRect: visibleRect, containers: containers)

        // Stage 14b — re-apply styling on every update so preset cycles + Update
        // Share edits show up live. Background touches the canvas matte; per-frame
        // touches every CanvasFrameContainer's two-layer stack.
        CanvasStylingRenderer.shared.applyBackground(document.styling)
        let backingScale = scrollView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        for container in documentView.subviews.compactMap({ $0 as? CanvasFrameContainer }) {
            container.applyStyling(document.styling, backingScale: backingScale)
        }

        // Stage 10: Manage hint card — show when only auto-loaded root is on canvas
        manageHintCard(on: documentView, coordinator: context.coordinator)
    }

    /// Show or hide the hint card based on route count.
    private func manageHintCard(on documentView: CanvasDocumentView, coordinator: Coordinator) {
        let shouldShow = document.routes.count == 1
            && document.routes.first?.path == "/"
            && AppServices.shared.didAutoLoadRoot

        if shouldShow {
            if coordinator.hintCard == nil {
                let rootFrame = document.routes[0]
                let card = HintCard(frame: NSRect(
                    x: rootFrame.x + rootFrame.width + 100,
                    y: rootFrame.y + (rootFrame.effectiveHeight - 200) / 2,
                    width: 400,
                    height: 200
                ))
                card.onClick = {
                    AppServices.shared.paletteState.open()
                }
                documentView.addSubview(card)
                coordinator.hintCard = card
            }
        } else {
            coordinator.hintCard?.removeFromSuperview()
            coordinator.hintCard = nil
        }
    }

    class Coordinator {
        let scrollCoordinator: CanvasScrollCoordinator
        let eventInterceptor = EventInterceptor()
        let tileLifecycle: TileLifecycle
        let markdownTileManager: MarkdownTileManager
        let interactHintCoordinator: InteractHintCoordinator
        var documentView: CanvasDocumentView?
        var hintCard: HintCard?

        init(camera: CanvasCamera, document: DocumentModel, interactionRouter: InteractionRouter, interactHintCoordinator: InteractHintCoordinator) {
            self.scrollCoordinator = CanvasScrollCoordinator(camera: camera)
            self.tileLifecycle = TileLifecycle(camera: camera, document: document, router: interactionRouter)
            self.markdownTileManager = MarkdownTileManager()
            self.interactHintCoordinator = interactHintCoordinator
        }
    }
}
