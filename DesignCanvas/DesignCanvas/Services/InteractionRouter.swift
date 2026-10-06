// Manages which frame is focused (drilled into) and drag state. Central coordinator for
// canvas interaction — scroll always pans canvas, clicks forwarded to web pages, drag
// moves frames. Double-click enters focus mode where all events (including scroll) pass
// through to the web page.

import AppKit
import Observation

@Observable
class InteractionRouter {

    // MARK: - State

    /// Frame in focus mode (double-clicked — all events including drag pass through to WKWebView)
    var activeFrameId: UUID? = nil

    /// Spacebar held — temporary pan override
    var isTemporaryPanMode = false

    /// True while a frame is being dragged (blocks other interactions)
    var isDragging = false

    /// Which frame is being dragged — protects it from TileLifecycle eviction
    var draggingFrameId: UUID? = nil

    /// All frames being moved during a multi-drag (superset includes draggingFrameId)
    var draggingFrameIds: Set<UUID> = []

    /// Frames currently selected (marquee or click). Mutually exclusive with focus mode.
    var selectedFrameIds: Set<UUID> = []

    /// Weak ref to DocumentModel for committing drag moves
    weak var document: DocumentModel?

    /// Weak ref to the canvas document view for focus management
    weak var canvasDocumentView: NSView?

    /// Weak ref to interact hint — suppressed when user double-clicks into a frame
    weak var interactHintCoordinator: InteractHintCoordinator?

    // MARK: - Focus mode (double-click to enter, Escape to exit)

    func activateFrame(_ id: UUID) {
        if activeFrameId != nil && activeFrameId != id {
            deactivateAll()
        }
        deselectAll()
        activeFrameId = id
        interactHintCoordinator?.markUserKnows()
    }

    func deactivateAll() {
        let previousId = activeFrameId
        activeFrameId = nil
        if let frameId = previousId {
            // Reset webview to original route URL if user navigated away during focus
            findContainer(withId: frameId)?.resetToOriginalURLIfNeeded()
            if let docView = canvasDocumentView {
                docView.window?.makeFirstResponder(docView)
            }
        }
    }

    // MARK: - Temporary pan mode (spacebar)

    func enterTemporaryPanMode() {
        isTemporaryPanMode = true
        NSCursor.openHand.push()
    }

    func exitTemporaryPanMode() {
        isTemporaryPanMode = false
        NSCursor.pop()
    }

    // MARK: - Drag commit

    func commitMove(routeId: UUID, x: CGFloat, y: CGFloat) {
        isDragging = false
        draggingFrameId = nil
        draggingFrameIds.removeAll()
        guard let document else { return }

        // Routes
        if let index = document.routes.firstIndex(where: { $0.id == routeId }) {
            let oldX = document.routes[index].x
            let oldY = document.routes[index].y
            document.undoManager.registerUndo(withTarget: document) { doc in
                doc.routes[index].x = oldX
                doc.routes[index].y = oldY
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.routes[index].x = x
                    doc.routes[index].y = y
                }
                doc.undoManager.setActionName("Move Frame")
            }
            document.undoManager.setActionName("Move Frame")
            document.routes[index].x = x
            document.routes[index].y = y
            CrashReporter.shared.breadcrumb(category: "canvas", action: "move", message: routeId.uuidString)
            scheduleMoveSave()
            return
        }

        // Markdown documents
        if let index = document.documents.firstIndex(where: { $0.id == routeId }) {
            let oldX = document.documents[index].x
            let oldY = document.documents[index].y
            document.undoManager.registerUndo(withTarget: document) { doc in
                doc.documents[index].x = oldX
                doc.documents[index].y = oldY
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.documents[index].x = x
                    doc.documents[index].y = y
                }
                doc.undoManager.setActionName("Move Document")
            }
            document.undoManager.setActionName("Move Document")
            document.documents[index].x = x
            document.documents[index].y = y
            scheduleMoveSave()
            return
        }

        // Images
        if let index = document.images.firstIndex(where: { $0.id == routeId }) {
            let oldX = document.images[index].x
            let oldY = document.images[index].y
            document.undoManager.registerUndo(withTarget: document) { doc in
                doc.images[index].x = oldX
                doc.images[index].y = oldY
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.images[index].x = x
                    doc.images[index].y = y
                }
                doc.undoManager.setActionName("Move Image")
            }
            document.undoManager.setActionName("Move Image")
            document.images[index].x = x
            document.images[index].y = y
            scheduleMoveSave()
            return
        }
    }

    private func scheduleMoveSave() {
        Task { @MainActor in
            AppServices.shared.sessionPersistence.scheduleSave(
                document: AppServices.shared.document, port: AppServices.shared.devServer.port
            )
        }
    }

    // MARK: - Resize commit

    func isImageFrame(_ id: UUID) -> Bool {
        document?.images.contains(where: { $0.id == id }) ?? false
    }

    func commitResize(routeId: UUID, width: CGFloat, height: CGFloat) {
        guard let document else { return }
        let w = min(max(width, FrameMetricsHandler.minWidth), FrameMetricsHandler.maxWidth)
        let h = min(max(height, FrameMetricsHandler.minHeight), FrameMetricsHandler.maxHeight)

        // Routes
        if let index = document.routes.firstIndex(where: { $0.id == routeId }) {
            let oldWidth = document.routes[index].width
            let oldHeight = document.routes[index].height
            document.undoManager.registerUndo(withTarget: document) { doc in
                doc.routes[index].width = oldWidth
                doc.routes[index].height = oldHeight
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.routes[index].width = w
                    doc.routes[index].height = h
                }
                doc.undoManager.setActionName("Resize Frame")
            }
            document.undoManager.setActionName("Resize Frame")
            document.routes[index].width = w
            document.routes[index].height = h
            CrashReporter.shared.breadcrumb(category: "canvas", action: "resize", message: routeId.uuidString)
            scheduleMoveSave()
            return
        }

        // Markdown documents
        if let index = document.documents.firstIndex(where: { $0.id == routeId }) {
            let oldWidth = document.documents[index].width
            let oldHeight = document.documents[index].height
            document.undoManager.registerUndo(withTarget: document) { doc in
                doc.documents[index].width = oldWidth
                doc.documents[index].height = oldHeight
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.documents[index].width = w
                    doc.documents[index].height = h
                }
                doc.undoManager.setActionName("Resize Document")
            }
            document.undoManager.setActionName("Resize Document")
            document.documents[index].width = w
            document.documents[index].height = h
            scheduleMoveSave()
            return
        }

        // Images
        if let index = document.images.firstIndex(where: { $0.id == routeId }) {
            let oldWidth = document.images[index].width
            let oldHeight = document.images[index].height
            document.undoManager.registerUndo(withTarget: document) { doc in
                doc.images[index].width = oldWidth
                doc.images[index].height = oldHeight
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.images[index].width = w
                    doc.images[index].height = h
                }
                doc.undoManager.setActionName("Resize Image")
            }
            document.undoManager.setActionName("Resize Image")
            document.images[index].width = w
            document.images[index].height = h
            scheduleMoveSave()
            return
        }
    }

    // MARK: - Escape key

    func handleEscape() {
        if activeFrameId != nil {
            deactivateAll()
        } else if !selectedFrameIds.isEmpty {
            deselectAll()
        }
    }

    // MARK: - Hard refresh (Cmd+R)

    /// Refresh the targeted frame. Priority: focused frame first, hovered frame second.
    func handleRefresh() {
        // Priority 1: frame in focus/interact mode
        if let focusedId = activeFrameId {
            findContainer(withId: focusedId)?.hardRefresh()
            return
        }

        // Priority 2: frame under the mouse cursor
        guard let docView = canvasDocumentView, let window = docView.window else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let docPoint = docView.convert(windowPoint, from: nil)
        if let hitView = docView.hitTest(docPoint),
           let container = hitView.ancestorOfType(CanvasFrameContainer.self) {
            container.hardRefresh()
        }
    }

    /// Find a CanvasFrameContainer by route ID on the canvas.
    func findContainer(withId id: UUID) -> CanvasFrameContainer? {
        canvasDocumentView?.subviews
            .compactMap { $0 as? CanvasFrameContainer }
            .first { $0.routeId == id }
    }

    // MARK: - Remove frame from canvas (Stage 10: Delete/Backspace)

    func handleRemoveFrame(frameId: UUID) {
        deactivateAll()
        Task { @MainActor in
            guard let doc = document else { return }

            // Routes — existing path with undo
            if let index = doc.routes.firstIndex(where: { $0.id == frameId }) {
                let removed = doc.routes[index]
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.routes.insert(removed, at: min(index, doc.routes.count))
                    doc.undoManager.setActionName("Remove Route")
                }
                doc.undoManager.setActionName("Remove Route")
                let _ = AppServices.shared.canvasManager?.removeRoute(id: frameId)
                return
            }

            // Markdown documents
            if let index = doc.documents.firstIndex(where: { $0.id == frameId }) {
                let removed = doc.documents[index]
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.documents.insert(removed, at: min(index, doc.documents.count))
                    doc.undoManager.setActionName("Remove Document")
                }
                doc.undoManager.setActionName("Remove Document")
                let _ = AppServices.shared.canvasManager?.removeDocument(id: frameId)
                return
            }

            // Images
            if let index = doc.images.firstIndex(where: { $0.id == frameId }) {
                let removed = doc.images[index]
                doc.undoManager.registerUndo(withTarget: doc) { doc in
                    doc.images.insert(removed, at: min(index, doc.images.count))
                    doc.undoManager.setActionName("Remove Image")
                }
                doc.undoManager.setActionName("Remove Image")
                let _ = AppServices.shared.canvasManager?.removeImage(id: frameId)
                return
            }
            // Fell through — id doesn't match any frame kind. Stale selection or already removed.
        }
    }

    // MARK: - Stage 5 contract: called before TileLifecycle demotes Live → Screenshot

    func onFrameWillDetach(frameId: UUID) {
        if activeFrameId == frameId {
            deactivateAll()
        }
    }
}

// MARK: - NSView helper

extension NSView {
    /// Walk up the superview chain to find the nearest ancestor of a given type.
    func ancestorOfType<T: NSView>(_ type: T.Type) -> T? {
        var current: NSView? = self
        while let view = current {
            if let match = view as? T { return match }
            current = view.superview
        }
        return nil
    }
}
