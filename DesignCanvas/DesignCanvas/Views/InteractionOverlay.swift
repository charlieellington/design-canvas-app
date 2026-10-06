// Transparent overlay above WKWebView inside each frame container. Intercepts mouse events
// for drag-to-move detection while letting scroll events reach NSScrollView for canvas pan.
// Default: scroll pans canvas, clicks forwarded to web page for links/buttons, drag moves
// frame. Focus mode (double-click): all events pass through including scroll and drag.
// Pinch always zooms canvas.

import AppKit

class InteractionOverlay: NSView {

    // MARK: - Dependencies (set by CanvasFrameContainer after creation)

    weak var interactionRouter: InteractionRouter?
    weak var interactHintCoordinator: InteractHintCoordinator?
    weak var documentView: NSView?  // The 50000x50000 canvas document view — for coordinate conversion
    var routeId: UUID = UUID()
    var routeOriginGetter: (() -> NSPoint)?  // Returns current route origin from model

    override var isFlipped: Bool { true }

    // MARK: - Drag state

    private struct DragState {
        let routeId: UUID
        let startWindowPoint: NSPoint
        let startDocPoint: NSPoint
        let originalOrigin: NSPoint
        let mouseDownEvent: NSEvent  // Stored to forward to WKWebView if not a drag
        var isDragging: Bool = false
        var peerOrigins: [UUID: NSPoint]?  // Non-nil during multi-drag
    }

    private var dragState: DragState?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let converted = convert(point, from: superview)
        guard bounds.contains(converted) else { return nil }

        guard let router = interactionRouter else { return self }
        let event = NSApp.currentEvent

        // Pinch-to-zoom: ALWAYS intercept → routes to NSScrollView for canvas zoom
        if let event, event.type == .magnify {
            if router.activeFrameId == routeId {
                router.deactivateAll()
            }
            return self
        }

        // Spacebar held (temporary pan mode): intercept everything → canvas pans
        if router.isTemporaryPanMode {
            return self
        }

        // Focus mode (double-clicked into frame): pass everything through to WKWebView
        // EXCEPT right-click — we intercept that to show our custom context menu
        if router.activeFrameId == routeId {
            if let event, event.type == .rightMouseDown || event.type == .rightMouseUp {
                return self
            }
            return nil
        }

        // Default mode: intercept mouse events (for drag detection), pass through scroll
        if let event {
            switch event.type {
            case .scrollWheel:
                // Default mode: intercept and forward to NSScrollView for canvas pan
                // (returning nil would send scroll to WKWebView underneath, not up)
                return self
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                 .rightMouseDown, .rightMouseUp:
                // Mouse events intercepted for drag-vs-click arbitration
                return self
            default:
                // Other events (mouseMoved, etc.) pass through
                return nil
            }
        }

        return self
    }

    // MARK: - Scroll routing

    override func scrollWheel(with event: NSEvent) {
        // Focus mode scroll never reaches here (hitTest returns nil → WKWebView gets it).
        if event.modifierFlags.contains(.command) {
            // Cmd+scroll → scroll the web page without entering focus mode
            findWebView()?.scrollWheel(with: event)
        } else {
            // Normal scroll → canvas pan
            interactHintCoordinator?.recordScroll()
            nextResponder?.scrollWheel(with: event)
        }
    }

    // MARK: - Mouse event handling (drag detection + click forwarding)

    override func mouseDown(with event: NSEvent) {
        guard let router = interactionRouter else {
            super.mouseDown(with: event)
            return
        }

        // Spacebar held → pass to scroll view for panning
        if router.isTemporaryPanMode {
            super.mouseDown(with: event)
            return
        }

        // Record drag start state (including the event for forwarding if not a drag)
        guard let docView = documentView else { return }
        let docPoint = docView.convert(event.locationInWindow, from: nil)
        let origin = routeOriginGetter?() ?? .zero

        dragState = DragState(
            routeId: routeId,
            startWindowPoint: event.locationInWindow,
            startDocPoint: docPoint,
            originalOrigin: origin,
            mouseDownEvent: event
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = dragState, let docView = documentView else { return }
        guard let router = interactionRouter, !router.isTemporaryPanMode else { return }

        // Check 3pt threshold in window coords (zoom-independent feel)
        if !state.isDragging {
            let dx = event.locationInWindow.x - state.startWindowPoint.x
            let dy = event.locationInWindow.y - state.startWindowPoint.y
            guard hypot(dx, dy) > 3.0 else { return }
            state.isDragging = true
            router.isDragging = true
            router.draggingFrameId = state.routeId

            // Multi-drag: if this frame is selected, drag all selected frames
            if router.selectedFrameIds.contains(state.routeId) {
                router.draggingFrameIds = router.selectedFrameIds
                var origins: [UUID: NSPoint] = [:]
                for peerId in router.selectedFrameIds where peerId != state.routeId {
                    if let c = router.findContainer(withId: peerId) {
                        origins[peerId] = c.frame.origin
                    }
                }
                state.peerOrigins = origins
            } else {
                router.draggingFrameIds = [state.routeId]
            }
        }

        // Convert to document coords — automatically handles NSScrollView magnification
        let docPoint = docView.convert(event.locationInWindow, from: nil)
        let deltaX = docPoint.x - state.startDocPoint.x
        let deltaY = docPoint.y - state.startDocPoint.y

        // Move the CanvasFrameContainer directly (optimistic AppKit update, no SwiftUI churn)
        guard let frameContainer = self.superview?.superview as? CanvasFrameContainer else { return }
        frameContainer.frame.origin = NSPoint(
            x: state.originalOrigin.x + deltaX,
            y: state.originalOrigin.y + deltaY
        )
        frameContainer.shadowHost?.frame.origin = NSPoint(
            x: frameContainer.frame.origin.x - (frameContainer.shadowHost?.layer?.borderWidth ?? 0),
            y: frameContainer.frame.origin.y - (frameContainer.shadowHost?.layer?.borderWidth ?? 0)
        )

        // Move peer selected frames by the same delta
        if let peers = state.peerOrigins {
            for (peerId, peerOrigin) in peers {
                if let c = router.findContainer(withId: peerId) {
                    c.frame.origin = NSPoint(x: peerOrigin.x + deltaX, y: peerOrigin.y + deltaY)
                    c.shadowHost?.frame.origin = NSPoint(
                        x: c.frame.origin.x - (c.shadowHost?.layer?.borderWidth ?? 0),
                        y: c.frame.origin.y - (c.shadowHost?.layer?.borderWidth ?? 0)
                    )
                }
            }
        }

        dragState = state
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragState = nil }
        guard let state = dragState, let router = interactionRouter else { return }

        if state.isDragging {
            guard let frameContainer = self.superview?.superview as? CanvasFrameContainer else { return }
            if let peers = state.peerOrigins, !peers.isEmpty {
                // Multi-drag commit — all selected frames
                var moves: [(routeId: UUID, x: CGFloat, y: CGFloat)] = [
                    (state.routeId, round(frameContainer.frame.origin.x), round(frameContainer.frame.origin.y))
                ]
                for peerId in peers.keys {
                    if let c = router.findContainer(withId: peerId) {
                        moves.append((peerId, round(c.frame.origin.x), round(c.frame.origin.y)))
                    }
                }
                router.commitMultiMove(moves: moves)
            } else {
                let origin = frameContainer.frame.origin
                router.commitMove(routeId: state.routeId, x: round(origin.x), y: round(origin.y))
            }
        } else if event.clickCount == 2 {
            // Double-click → enter focus mode (all events pass through for drag interactions)
            router.activateFrame(state.routeId)
            if let webView = findWebView() {
                window?.makeFirstResponder(webView)
            }
        } else {
            // Single click — select frame, and forward to WKWebView if not multi-selected
            let extending = event.modifierFlags.contains(.shift)
            router.selectFrame(state.routeId, extending: extending)
            if router.selectedFrameIds.count <= 1 {
                forwardClickToWebView(mouseDown: state.mouseDownEvent, mouseUp: event)
            }
        }
    }

    // MARK: - Click forwarding

    /// Forward a click (mouseDown + mouseUp) to the WKWebView when the overlay intercepted
    /// for drag detection but the user just clicked without dragging.
    private func forwardClickToWebView(mouseDown: NSEvent, mouseUp: NSEvent) {
        guard let webView = findWebView() else { return }
        webView.mouseDown(with: mouseDown)
        webView.mouseUp(with: mouseUp)
    }

    // MARK: - Right-click context menu (canvas mode — overlay intercepts rightMouseDown)

    override func rightMouseDown(with event: NSEvent) {
        let menu = FrameContextMenu.build(for: self)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Helpers

    /// Find the WKWebView sibling in our parent container
    private func findWebView() -> NSView? {
        guard let container = superview else { return nil }
        for sibling in container.subviews {
            if String(describing: type(of: sibling)).contains("WKWebView") {
                return sibling
            }
        }
        return nil
    }
}
