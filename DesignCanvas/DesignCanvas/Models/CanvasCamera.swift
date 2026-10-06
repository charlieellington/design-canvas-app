// Single source of truth for viewport state. The UI observes this, not the other way around.
// NSScrollView provides physics; CanvasCamera provides the API all other app logic reads.

import Foundation
import Observation

@Observable
class CanvasCamera {
    var origin: CGPoint = .zero
    var zoom: CGFloat = 0.5
    var velocity: CGVector = .zero
    var documentSize: CGSize = CGSize(width: 50000, height: 50000)
    var viewportPixelSize: CGSize = CGSize(width: 1200, height: 800)

    var visibleRect: CGRect {
        CGRect(
            origin: origin,
            size: CGSize(
                width: viewportPixelSize.width / zoom,
                height: viewportPixelSize.height / zoom
            )
        )
    }

    static let canvasCenter = CGPoint(x: 25000, y: 25000)

    func clampedOrigin(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: max(0, min(point.x, documentSize.width - visibleRect.width)),
            y: max(0, min(point.y, documentSize.height - visibleRect.height))
        )
    }

    func clampedZoom(_ value: CGFloat) -> CGFloat {
        max(0.1, min(3.0, value))
    }
}
