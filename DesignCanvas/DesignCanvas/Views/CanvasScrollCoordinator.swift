// The ONLY place that converts between CanvasCamera state and NSScrollView state.
// Bridges NSScrollView events → CanvasCamera, and programmatic camera changes → NSScrollView.

import AppKit

class CanvasScrollCoordinator: NSObject {

    let camera: CanvasCamera
    var document: DocumentModel?
    weak var interactionRouter: InteractionRouter?
    private weak var scrollView: NSScrollView?

    /// Fired after each user-driven pan or zoom (filtered: programmatic camera updates and
    /// no-op bounds deltas are excluded). Used by the onboarding card's "first interaction"
    /// trigger. Guaranteed to run on the main thread.
    var onUserViewportChange: (() -> Void)?

    private var isUpdatingFromScrollView = false
    private var isUpdatingFromCamera = false
    private var velocityResetTask: DispatchWorkItem?
    private var lastBoundsOrigin: CGPoint = .zero
    private var lastBoundsTime: CFTimeInterval = 0
    private var hasCentered = false

    init(camera: CanvasCamera) {
        self.camera = camera
        super.init()
    }

    func attach(to scrollView: NSScrollView) {
        self.scrollView = scrollView

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cameraNeedsSync),
            name: .cameraNeedsSync,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResetZoomToFit),
            name: .resetZoomToFit,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        velocityResetTask?.cancel()
    }

    // MARK: - NSScrollView → Camera

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let scrollView, !isUpdatingFromCamera else { return }

        let newOrigin = scrollView.contentView.bounds.origin
        let newZoom = scrollView.magnification

        let originChanged = abs(newOrigin.x - camera.origin.x) > 0.5
            || abs(newOrigin.y - camera.origin.y) > 0.5
        let zoomChanged = abs(newZoom - camera.zoom) > 0.001

        guard originChanged || zoomChanged else { return }

        // Notify onboarding (or any other observer) that the user panned/zoomed.
        onUserViewportChange?()

        isUpdatingFromScrollView = true

        // Velocity tracking — only when magnification is stable (not during pinch-zoom)
        if !zoomChanged {
            let now = CACurrentMediaTime()
            let dt = now - lastBoundsTime
            if dt > 0.001 && lastBoundsTime > 0 {
                let dx = newOrigin.x - lastBoundsOrigin.x
                let dy = newOrigin.y - lastBoundsOrigin.y
                camera.velocity = CGVector(dx: dx / dt, dy: dy / dt)

                velocityResetTask?.cancel()
                let task = DispatchWorkItem { [weak self] in
                    self?.camera.velocity = .zero
                }
                velocityResetTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
            }
            lastBoundsOrigin = newOrigin
            lastBoundsTime = now
        }

        camera.origin = newOrigin
        camera.zoom = newZoom

        // Pinch-to-zoom exits interact mode — zooming implies returning to overview
        if zoomChanged, let router = interactionRouter, router.activeFrameId != nil {
            router.deactivateAll()
        }

        isUpdatingFromScrollView = false
    }

    @objc private func frameDidChange(_ notification: Notification) {
        guard let scrollView else { return }
        camera.viewportPixelSize = scrollView.contentView.frame.size
    }

    /// Called from updateNSView — waits for the window to be on screen before zooming.
    /// Retries once after a short delay if the window isn't ready yet but routes exist.
    func zoomToFitIfNeeded() {
        guard !hasCentered, let scrollView else { return }

        // Window must be on screen with real size
        guard scrollView.contentSize.width > 10, scrollView.window != nil else {
            // Retry once after the window appears
            if let document, !document.routes.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.zoomToFitIfNeeded()
                }
            }
            return
        }

        // Block boundsDidChange from interfering during the entire zoom-to-fit sequence
        isUpdatingFromCamera = true

        // Step 1: Set magnification now
        let targetRect = computeTargetRect()
        guard let targetRect else { isUpdatingFromCamera = false; return }
        hasCentered = true

        let contentSize = scrollView.contentSize
        let zoomX = contentSize.width / targetRect.width
        let zoomY = contentSize.height / targetRect.height
        let fitZoom = camera.clampedZoom(min(zoomX, zoomY))

        scrollView.magnification = fitZoom

        // Step 2: After magnification settles, scroll to center
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.scrollView,
                  let documentView = scrollView.documentView else {
                self?.isUpdatingFromCamera = false
                return
            }

            let cs = scrollView.contentSize
            let visibleDocW = cs.width / fitZoom
            let visibleDocH = cs.height / fitZoom
            let scrollPt = CGPoint(
                x: targetRect.midX - visibleDocW / 2,
                y: targetRect.midY - visibleDocH / 2
            )

            documentView.scroll(scrollPt)
            scrollView.reflectScrolledClipView(scrollView.contentView)

            self.camera.origin = scrollView.contentView.bounds.origin
            self.camera.zoom = fitZoom
            self.camera.viewportPixelSize = cs
            self.isUpdatingFromCamera = false

            print("Camera: zoom-to-fit — zoom: \(fitZoom), scroll: \(scrollPt), bounds: \(scrollView.contentView.bounds.origin)")
        }
    }

    private func computeTargetRect() -> CGRect? {
        guard let document else { return nil }
        if document.routes.isEmpty && document.documents.isEmpty && document.images.isEmpty {
            return nil
        }

        let labelHeight: CGFloat = 28
        let padding: CGFloat = 100

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for route in document.routes {
            minX = min(minX, route.x)
            minY = min(minY, route.y - labelHeight)
            maxX = max(maxX, route.x + route.width)
            maxY = max(maxY, route.y + route.effectiveHeight)
        }
        for doc in document.documents {
            minX = min(minX, doc.x)
            minY = min(minY, doc.y - labelHeight)
            maxX = max(maxX, doc.x + doc.width)
            maxY = max(maxY, doc.y + doc.effectiveHeight)
        }
        for img in document.images {
            minX = min(minX, img.x)
            minY = min(minY, img.y - labelHeight)
            maxX = max(maxX, img.x + img.width)
            maxY = max(maxY, img.y + img.effectiveHeight)
        }

        return CGRect(
            x: minX - padding,
            y: minY - padding,
            width: (maxX - minX) + padding * 2,
            height: (maxY - minY) + padding * 2
        )
    }

    @objc private func cameraNeedsSync(_ notification: Notification) {
        applyCameraToScrollView()
    }

    @objc private func handleResetZoomToFit(_ notification: Notification) {
        hasCentered = false
    }

    // MARK: - Camera → NSScrollView

    func applyCameraToScrollView() {
        guard let scrollView, !isUpdatingFromScrollView else { return }
        isUpdatingFromCamera = true
        scrollView.contentView.scroll(to: camera.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.setMagnification(camera.zoom, centeredAt: NSPoint(
            x: camera.origin.x + camera.visibleRect.width / 2,
            y: camera.origin.y + camera.visibleRect.height / 2
        ))
        isUpdatingFromCamera = false
    }

    /// Re-zoom to fit all frames. Callable from toolbar button (resets the "already centered" flag).
    func resetAndZoomToFit() {
        hasCentered = false
        zoomToFitIfNeeded()
    }
}
