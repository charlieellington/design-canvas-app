// Receives height measurements from JS ResizeObserver running inside WKWebViews.
// Clamps to min/max bounds and fires a callback to update the RouteFrame in DocumentModel.

import WebKit

class FrameMetricsHandler: NSObject, WKScriptMessageHandler {

    static let messageName = "frameMetrics"
    static let minHeight: CGFloat = 600
    static let maxHeight: CGFloat = 8000
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 8000

    var onHeightMeasured: ((CGFloat) -> Void)?

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let number = body["height"] as? NSNumber else { return }

        let rawHeight = CGFloat(number.doubleValue)
        let clamped = min(max(rawHeight, Self.minHeight), Self.maxHeight)
        onHeightMeasured?(clamped)
    }
}
