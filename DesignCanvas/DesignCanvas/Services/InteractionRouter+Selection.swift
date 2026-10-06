// Selection and multi-drag extensions for InteractionRouter. Handles marquee selection,
// click-to-select (with Shift for extend), and batch position commits with grouped undo.

import AppKit

extension InteractionRouter {

    // MARK: - Selection (marquee + click)

    /// Select a single frame. If extending (Shift held), toggle in/out of selection set.
    func selectFrame(_ id: UUID, extending: Bool) {
        if activeFrameId != nil { deactivateAll() }
        if extending {
            if selectedFrameIds.contains(id) {
                selectedFrameIds.remove(id)
            } else {
                selectedFrameIds.insert(id)
            }
        } else {
            selectedFrameIds = [id]
        }
        refreshSelectionVisuals()
    }

    /// Clear all selected frames and refresh their visuals.
    func deselectAll() {
        guard !selectedFrameIds.isEmpty else { return }
        selectedFrameIds.removeAll()
        refreshSelectionVisuals()
    }

    /// Select all frames whose bounds intersect the given document-space rectangle.
    func selectFrames(intersecting rect: CGRect) {
        guard let document else { return }
        var newSelection = Set<UUID>()
        for route in document.routes {
            let frameRect = CGRect(x: route.x, y: route.y, width: route.width, height: route.effectiveHeight)
            if rect.intersects(frameRect) {
                newSelection.insert(route.id)
            }
        }
        for doc in document.documents {
            let frameRect = CGRect(x: doc.x, y: doc.y, width: doc.width, height: doc.effectiveHeight)
            if rect.intersects(frameRect) {
                newSelection.insert(doc.id)
            }
        }
        for img in document.images {
            let frameRect = CGRect(x: img.x, y: img.y, width: img.width, height: img.effectiveHeight)
            if rect.intersects(frameRect) {
                newSelection.insert(img.id)
            }
        }
        selectedFrameIds = newSelection
        refreshSelectionVisuals()
    }

    /// Refresh applyVisualState() on all visible frame containers.
    func refreshSelectionVisuals() {
        guard let docView = canvasDocumentView else { return }
        for subview in docView.subviews {
            (subview as? CanvasFrameContainer)?.applyVisualState()
        }
    }

    // MARK: - Multi-drag commit

    /// Which collection a multi-move position lives in.
    fileprivate enum FrameKind { case route, document, image }

    fileprivate typealias MultiMovePosition = (kind: FrameKind, index: Int, x: CGFloat, y: CGFloat)

    /// Commit positions for multiple frames as a single undo group. Handles routes,
    /// markdown documents, and images — multi-drag of any mix snaps to the dropped
    /// position and reverts together on ⌘Z.
    func commitMultiMove(moves: [(routeId: UUID, x: CGFloat, y: CGFloat)]) {
        isDragging = false
        draggingFrameId = nil
        draggingFrameIds.removeAll()
        guard let document else { return }

        var oldPositions: [MultiMovePosition] = []
        var newPositions: [MultiMovePosition] = []
        for move in moves {
            if let idx = document.routes.firstIndex(where: { $0.id == move.routeId }) {
                oldPositions.append((.route, idx, document.routes[idx].x, document.routes[idx].y))
                newPositions.append((.route, idx, move.x, move.y))
            } else if let idx = document.documents.firstIndex(where: { $0.id == move.routeId }) {
                oldPositions.append((.document, idx, document.documents[idx].x, document.documents[idx].y))
                newPositions.append((.document, idx, move.x, move.y))
            } else if let idx = document.images.firstIndex(where: { $0.id == move.routeId }) {
                oldPositions.append((.image, idx, document.images[idx].x, document.images[idx].y))
                newPositions.append((.image, idx, move.x, move.y))
            }
        }

        document.undoManager.beginUndoGrouping()
        document.undoManager.registerUndo(withTarget: document) { doc in
            doc.undoManager.beginUndoGrouping()
            for pos in oldPositions { Self.applyPosition(pos, to: doc) }
            doc.undoManager.registerUndo(withTarget: doc) { doc in
                for pos in newPositions { Self.applyPosition(pos, to: doc) }
            }
            doc.undoManager.setActionName("Move Frames")
            doc.undoManager.endUndoGrouping()
        }
        document.undoManager.setActionName("Move Frames")

        for pos in newPositions { Self.applyPosition(pos, to: document) }
        document.undoManager.endUndoGrouping()

        Task { @MainActor in
            AppServices.shared.sessionPersistence.scheduleSave(
                document: AppServices.shared.document, port: AppServices.shared.devServer.port
            )
        }
    }

    fileprivate static func applyPosition(_ pos: MultiMovePosition, to doc: DocumentModel) {
        switch pos.kind {
        case .route:
            doc.routes[pos.index].x = pos.x
            doc.routes[pos.index].y = pos.y
        case .document:
            doc.documents[pos.index].x = pos.x
            doc.documents[pos.index].y = pos.y
        case .image:
            doc.images[pos.index].x = pos.x
            doc.images[pos.index].y = pos.y
        }
    }
}
