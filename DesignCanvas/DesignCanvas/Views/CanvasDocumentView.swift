// The 50000x50000 canvas surface that lives inside NSScrollView. Flipped coordinate system
// (top-left origin) to match web conventions. Background: #111214 (design token: canvas).
// Handles rubber-band marquee selection on canvas background and click-to-deselect.

import AppKit

class CanvasDocumentView: NSView {

    weak var interactionRouter: InteractionRouter?
    weak var camera: CanvasCamera?

    override var isFlipped: Bool { true }

    // MARK: - Marquee state

    private var marqueeOrigin: NSPoint?
    private var startWindowPoint: NSPoint?
    private var marqueeOverlay: MarqueeOverlayView?
    private var isShiftExtending = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            red: 0x11 / 255.0,
            green: 0x12 / 255.0,
            blue: 0x14 / 255.0,
            alpha: 1.0
        ).cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Drag-and-drop from Finder

    // Documents are .md/.markdown (rendered via marked.js) or .html/.htm (loaded as-is).
    // Both flow through the same WKWebView pipeline — see MarkdownRenderer.render.
    private static let markdownExtensions: Set<String> = ["md", "markdown", "html", "htm"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "heic"]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = dragURLs(from: sender)
        return urls.contains(where: { isAccepted($0) }) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = dragURLs(from: sender).filter { isAccepted($0) }
        guard !urls.isEmpty else { return false }

        // sender.draggingLocation is in window coordinates. self is the flipped document view
        // (isFlipped: true), so convert(_:from:nil) yields document-space coords directly —
        // same pattern used for the marquee at line 45.
        let docPoint = self.convert(sender.draggingLocation, from: nil)

        // Stagger multiple files horizontally starting from the drop point.
        var dx: CGFloat = 0
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let x = docPoint.x + dx
            let y = docPoint.y
            if Self.markdownExtensions.contains(ext) {
                _ = AppServices.shared.canvasManager?.addDocument(
                    filePath: url.path, x: x, y: y, width: nil, height: nil)
                dx += 720  // default markdown width + gap
            } else if Self.imageExtensions.contains(ext) {
                _ = AppServices.shared.canvasManager?.addImage(
                    filePath: url.path, x: x, y: y, width: nil, height: nil)
                dx += 620  // default image width + gap
            }
        }
        return true
    }

    private func dragURLs(from sender: NSDraggingInfo) -> [URL] {
        // One dragged file = one pasteboard item. readObjects(forClasses: [NSURL.self])
        // returns one URL per conforming type, which duplicates for .md files (Finder
        // puts multiple URL representations on the pasteboard for text-type files).
        (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { item in
            guard let str = item.string(forType: .fileURL),
                  let url = URL(string: str) else { return nil }
            return url
        }
    }

    private func isAccepted(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.markdownExtensions.contains(ext) || Self.imageExtensions.contains(ext)
    }

    // MARK: - Mouse handling (marquee selection + click-to-deselect)

    override func mouseDown(with event: NSEvent) {
        // Spacebar pan mode — pass through to scroll view
        if interactionRouter?.isTemporaryPanMode == true {
            super.mouseDown(with: event)
            return
        }

        let docPoint = convert(event.locationInWindow, from: nil)
        marqueeOrigin = docPoint
        startWindowPoint = event.locationInWindow
        isShiftExtending = event.modifierFlags.contains(.shift)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = marqueeOrigin, let startWinPt = startWindowPoint else { return }
        guard interactionRouter?.isTemporaryPanMode != true else { return }

        // 3pt threshold in window coords (zoom-independent)
        if marqueeOverlay == nil {
            let dx = event.locationInWindow.x - startWinPt.x
            let dy = event.locationInWindow.y - startWinPt.y
            guard hypot(dx, dy) > 3.0 else { return }

            // Clear focus mode; if not Shift-extending, clear existing selection too
            interactionRouter?.deactivateAll()
            if !isShiftExtending {
                interactionRouter?.deselectAll()
            }

            let overlay = MarqueeOverlayView(frame: bounds)
            overlay.camera = camera
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            marqueeOverlay = overlay
        }

        // Compute normalised rect (handle drag in any direction)
        let docPoint = convert(event.locationInWindow, from: nil)
        let rect = CGRect(
            x: min(origin.x, docPoint.x),
            y: min(origin.y, docPoint.y),
            width: abs(docPoint.x - origin.x),
            height: abs(docPoint.y - origin.y)
        )
        marqueeOverlay?.marqueeRect = rect
        interactionRouter?.selectFrames(intersecting: rect)
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeOverlay != nil {
            marqueeOverlay?.removeFromSuperview()
            marqueeOverlay = nil
        } else if !isShiftExtending {
            // Plain click on canvas background — deselect all and exit focus
            interactionRouter?.deactivateAll()
            interactionRouter?.deselectAll()
        }
        marqueeOrigin = nil
        startWindowPoint = nil
    }
}
