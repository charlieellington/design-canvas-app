// Draws a rubber-band selection rectangle on the canvas during marquee drag.
// Visual-only — hitTest returns nil so it never intercepts events.

import AppKit

class MarqueeOverlayView: NSView {

    var marqueeRect: CGRect? {
        didSet { needsDisplay = true }
    }

    weak var camera: CanvasCamera?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = marqueeRect else { return }

        // Fill: white at 4% opacity
        NSColor(white: 1.0, alpha: 0.04).setFill()
        let path = NSBezierPath(rect: rect)
        path.fill()

        // Stroke: white at 20% opacity, 1px in screen space
        let zoom = max(camera?.zoom ?? 1.0, 0.1)
        let strokeWidth = 1.0 / zoom
        NSColor(white: 1.0, alpha: 0.20).setStroke()
        path.lineWidth = strokeWidth
        path.stroke()
    }
}
