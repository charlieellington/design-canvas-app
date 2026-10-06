// Reusable frame container for route frames on the canvas. Holds a WKWebView with an
// InteractionOverlay on top, plus shimmer loading state and error overlay. Pool-ready API
// (attachWebView/detachWebView) supports tile lifecycle. "Ambient State" loading UX:
// queued (accent border) → loading (shimmer + accent label) → live (scale-settle).

import AppKit
import SwiftUI
import WebKit
import ImageIO

class CanvasFrameContainer: NSView {

    /// What kind of content this container hosts. Determines which attach*/ update*/ reload
    /// paths are valid. `routeId` / `routePath` are reused across all kinds — for markdown
    /// and image frames the "path" field holds the absolute file path.
    enum FrameKind {
        case route
        case markdown
        case image
    }

    var kind: FrameKind = .route
    let routeId: UUID
    private(set) var routePath: String
    private let label: NSTextField
    private let contentClip: NSView
    private(set) var webView: WKWebView?
    private var overlay: InteractionOverlay?
    /// NSImageView for kind == .image. Not used for route/markdown kinds.
    private var imageView: NSImageView?
    /// Dark fill shown while an image is decoding off-main, to avoid a missing-frame flash.
    private var imagePlaceholder: NSView?
    /// File path of the image currently attached — short-circuits redundant re-decode on updates.
    private var attachedImagePath: String?
    /// Bumped whenever attachImageView is called; in-flight decodes check this to drop stale results.
    private var imageAttachToken: UInt64 = 0
    /// Placeholder shown when a markdown frame is demoted by MarkdownTileManager's cap.
    private var markdownPlaceholder: NSView?
    /// Dark fill shown while a markdown WKWebView is spinning up + first-painting.
    /// Separate from `markdownPlaceholder` (LOD cap) so it's non-interactive.
    private var markdownLoadingPlaceholder: NSView?
    /// Bumped whenever attachMarkdownWebView is called; in-flight loads check this to drop stale results.
    private var markdownAttachToken: UInt64 = 0
    private var screenshotView: ScreenshotFrameView?
    private var shimmerLayer: CAGradientLayer?
    private var loadingDetailView: NSView?
    private var loadingDetailTimers: [DispatchWorkItem] = []
    private var errorLabel: NSTextField?
    private var navigationDelegate: WebViewCoordinator?
    private var metricsHandler: FrameMetricsHandler?
    private(set) var shadowHost: NSView?
    private var trackingArea: NSTrackingArea?

    /// Live "W × H" badge shown while the user drags any resize zone. Lazy so it only
    /// materializes on first resize drag. Positioned above the frame, right-aligned
    /// (opposite the top-left route label).
    private lazy var dimensionReadout: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        tf.textColor = .white
        tf.alignment = .center
        tf.isBordered = false
        tf.isEditable = false
        tf.isSelectable = false
        tf.drawsBackground = false
        tf.wantsLayer = true
        tf.layer?.backgroundColor = NSColor(white: 0, alpha: 0.75).cgColor
        tf.layer?.cornerRadius = 4
        tf.layer?.masksToBounds = true
        tf.isHidden = true
        addSubview(tf)
        return tf
    }()

    // MARK: - Focus navigation (back + home when navigated away from route)

    /// The URL originally loaded for this route — set by TileLifecycle on promote.
    var originalURL: URL?
    private var urlObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var hasNavigatedAway: Bool = false
    private var navChangeHandler: NavChangeHandler?

    /// The current navigated URL, observed live from the WKWebView (KVO + SPA push-state).
    /// Drives the label text so it shows where the frame is actually pointing, not
    /// just the path it was added with. Cleared on detach.
    private var currentLiveURL: URL?

    /// Cached displayName from the last update so the label-text helper can apply
    /// precedence (displayName > liveURL > routePath) without re-reading the model.
    private var currentDisplayName: String?

    /// Last height measured by the JS ResizeObserver. Used by "Fit to Content".
    var lastMeasuredContentHeight: CGFloat?

    /// Tracks whether this frame was showing as removed on the last updateNSView cycle.
    /// Used by CanvasContainerView to detect transitions into/out of removed state.
    var wasRemoved: Bool = false

    /// Demo-mode flag — toggles provisional chrome (accent-tinted border) and shows the
    /// DEMO APP watermark overlay. Set by CanvasContainerView when updating frames.
    /// Phase 2b.
    var isDemoMode: Bool = false {
        didSet {
            if oldValue != isDemoMode {
                applyDemoWatermark()
                applyVisualState()
            }
        }
    }

    private var demoWatermarkHost: NSHostingView<DemoWatermarkOverlay>?

    /// References set after creation for interaction wiring. didSet propagates to the
    /// overlay because markdown frames create the overlay during init (before these are
    /// set); for routes the overlay is created later, so the didSet is a harmless no-op.
    weak var interactionRouter: InteractionRouter? {
        didSet { overlay?.interactionRouter = interactionRouter }
    }
    weak var documentView: NSView? {
        didSet { overlay?.documentView = documentView }
    }
    weak var camera: CanvasCamera?
    weak var tileLifecycle: TileLifecycle?
    weak var interactHintCoordinator: InteractHintCoordinator? {
        didSet { overlay?.interactHintCoordinator = interactHintCoordinator }
    }
    override var isFlipped: Bool { true }

    // MARK: - Design tokens

    private static let borderDefault = NSColor(red: 0x2C / 255.0, green: 0x2D / 255.0, blue: 0x30 / 255.0, alpha: 1.0)
    private static let borderHover = NSColor(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0, alpha: 1.0)
    /// Demo-mode chrome — accent-tinted border at 45% alpha, visually distinct from default grey.
    /// Phase 2b (documentation/onboarding-update-implementation.md § 5.5).
    private static let borderDemo = NSColor(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0, alpha: 0.45)
    private static let selectionColor = NSColor.white
    private static let labelMuted = NSColor(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0, alpha: 1.0)
    private static let labelPrimary = NSColor(red: 0xEE / 255.0, green: 0xEE / 255.0, blue: 0xEE / 255.0, alpha: 1.0)
    private static let accentColor = NSColor(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0, alpha: 1.0)
    private static let accentBorderQueued = NSColor(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0, alpha: 0.05)
    private static let accentBorderHoverQ = NSColor(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0, alpha: 0.12)
    private static let accentBorderLoading = NSColor(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0, alpha: 0.10)
    private static let borderStormPaused = NSColor(red: 0x5E / 255.0, green: 0x6A / 255.0, blue: 0xD2 / 255.0, alpha: 0.55)
    private static let removedBorderColor = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 0.15)
    private static let removedLabelColor = NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 0.6)
    private static let removedOverlayColor = NSColor(red: 0x11 / 255.0, green: 0x12 / 255.0, blue: 0x14 / 255.0, alpha: 0.6)

    // MARK: - Removed route overlay

    private var removedOverlay: NSView?
    private var removedBadge: NSView?

    /// Show a semi-transparent dark overlay + "Route removed" badge over the screenshot.
    func showRemovedOverlay() {
        guard removedOverlay == nil else { return }
        let ov = NSView(frame: contentClip.bounds)
        ov.wantsLayer = true
        ov.layer?.backgroundColor = Self.removedOverlayColor.cgColor
        ov.autoresizingMask = [.width, .height]
        contentClip.addSubview(ov, positioned: .above, relativeTo: screenshotView)
        removedOverlay = ov

        // Badge: "Route removed" pill centered on the frame
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor(white: 1.0, alpha: 0.06).cgColor
        badge.layer?.cornerRadius = 12

        let badgeLabel = NSTextField(labelWithString: "Route removed")
        badgeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        badgeLabel.textColor = NSColor(white: 1.0, alpha: 0.6)
        badgeLabel.sizeToFit()

        let padding: CGFloat = 16
        let badgeWidth = badgeLabel.frame.width + padding * 2
        let badgeHeight: CGFloat = 24
        badge.frame = NSRect(
            x: (contentClip.bounds.width - badgeWidth) / 2,
            y: (contentClip.bounds.height - badgeHeight) / 2,
            width: badgeWidth,
            height: badgeHeight
        )
        badge.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        badgeLabel.frame = NSRect(x: padding, y: (badgeHeight - badgeLabel.frame.height) / 2,
                                   width: badgeLabel.frame.width, height: badgeLabel.frame.height)
        badge.addSubview(badgeLabel)
        contentClip.addSubview(badge, positioned: .above, relativeTo: ov)
        removedBadge = badge
    }

    /// Remove the overlay and badge (e.g. when route is restored).
    func hideRemovedOverlay() {
        removedOverlay?.removeFromSuperview()
        removedOverlay = nil
        removedBadge?.removeFromSuperview()
        removedBadge = nil
    }

    // MARK: - Demo watermark (Phase 2b)

    /// Mount/unmount the "DEMO APP" watermark above the frame content.
    /// Non-interactive, zoom-stable via the frame's own coordinate space.
    private func applyDemoWatermark() {
        if isDemoMode {
            guard demoWatermarkHost == nil else { return }
            let host = NSHostingView(rootView: DemoWatermarkOverlay())
            host.frame = contentClip.bounds
            host.autoresizingMask = [.width, .height]
            // Allow clicks to pass through to the webview / screenshot below.
            host.isHidden = false
            contentClip.addSubview(host, positioned: .above, relativeTo: nil)
            demoWatermarkHost = host
        } else {
            demoWatermarkHost?.removeFromSuperview()
            demoWatermarkHost = nil
        }
    }

    // MARK: - Hit testing (expand to include label area + resize zones)

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Back chevron above frame — return the button directly for click handling
        if let chevron = backChevron, !chevron.isHidden, chevron.frame.contains(local) {
            return chevron
        }
        // Active-state chrome buttons (above frame, alongside label) — clicks must hit
        // the buttons themselves, otherwise self.mouseDown starts a drag.
        if let close = closeButton, !close.isHidden, close.frame.contains(local) {
            return close
        }
        if let refresh = refreshButton, !refresh.isHidden, refresh.frame.contains(local) {
            return refresh
        }
        if let dot = divergenceDot, !dot.isHidden, dot.frame.contains(local) {
            return dot
        }
        // While URL editing, the label is the editable field — let NSTextField's editor handle hits.
        if isURLEditing, label.frame.contains(local) {
            return label
        }
        // Label sits at negative y (above bounds) — return self so drag handlers fire
        if label.frame.contains(local) {
            return self
        }
        // Resize zones — intercept before overlay so resize works on live frames
        if isBottomResizeZone(local) || isRightResizeZone(local) || isCornerResizeZone(local) {
            return self
        }
        return super.hitTest(point)
    }

    init(route: RouteFrame) {
        self.routeId = route.id
        self.routePath = route.path
        self.currentDisplayName = route.displayName
        self.label = NSTextField(labelWithString: route.labelText)
        self.contentClip = NSView(frame: .zero)
        super.init(frame: .zero)

        wantsLayer = true

        // Content clip: rounded corners + clipping for webview/screenshot content.
        // Lives inside self so label (which sits above bounds) is not clipped.
        contentClip.wantsLayer = true
        contentClip.layer?.cornerRadius = 8
        contentClip.layer?.masksToBounds = true
        contentClip.layer?.backgroundColor = NSColor(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0, alpha: 1.0).cgColor
        contentClip.autoresizingMask = [.width, .height]
        addSubview(contentClip)

        // Route label: monospace 12px #888888, positioned 8px above frame (unclipped)
        // Font size is recalculated in update() to stay constant in screen pixels
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = Self.labelMuted
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Markdown / Image convenience inits

    /// Create a container for a markdown document. Attaches a WKWebView loaded with the
    /// rendered HTML via loadHTMLString + baseURL (no route pool involvement).
    convenience init(markdown doc: MarkdownFrame) {
        // Reuse the route init's chrome setup by passing a stand-in RouteFrame; immediately
        // override the fields that differ. This avoids duplicating the ~20 lines of chrome
        // setup that would otherwise fall out of sync with route frames.
        let stand = RouteFrame(id: doc.id, path: doc.filePath,
                               x: doc.x, y: doc.y, width: doc.width, height: doc.height,
                               zIndex: 0, displayName: doc.labelText)
        self.init(route: stand)
        self.kind = .markdown
        self.routePath = doc.filePath
        self.label.stringValue = doc.labelText
        self.label.sizeToFit()
        attachMarkdownWebView(filePath: doc.filePath)
    }

    /// Create a container for an image. Attaches an NSImageView (no WKWebView).
    convenience init(image img: ImageFrame) {
        let stand = RouteFrame(id: img.id, path: img.filePath,
                               x: img.x, y: img.y, width: img.width, height: img.height,
                               zIndex: 0, displayName: img.labelText)
        self.init(route: stand)
        self.kind = .image
        self.routePath = img.filePath
        self.label.stringValue = img.labelText
        self.label.sizeToFit()
        attachImageView(filePath: img.filePath)
    }

    // MARK: - Update paths for markdown / image

    func update(markdown doc: MarkdownFrame) {
        let pathChanged = routePath != doc.filePath
        routePath = doc.filePath
        label.stringValue = doc.labelText
        layoutLabel()
        frame = NSRect(x: doc.x, y: doc.y, width: doc.width, height: doc.height)
        contentClip.frame = bounds
        webView?.frame = contentClip.bounds
        updateShadowHost()
        applyVisualState()
        window?.invalidateCursorRects(for: self)
        if pathChanged {
            // File swapped under this frame — reload content.
            attachMarkdownWebView(filePath: doc.filePath)
        }
    }

    func update(image img: ImageFrame) {
        let pathChanged = routePath != img.filePath
        routePath = img.filePath
        label.stringValue = img.labelText
        layoutLabel()
        frame = NSRect(x: img.x, y: img.y, width: img.width, height: img.height)
        contentClip.frame = bounds
        imageView?.frame = contentClip.bounds
        updateShadowHost()
        applyVisualState()
        window?.invalidateCursorRects(for: self)
        if pathChanged {
            attachImageView(filePath: img.filePath)
        }
    }

    // MARK: - Markdown WKWebView attach (async with loading placeholder + fade-in)

    private func attachMarkdownWebView(filePath: String) {
        markdownAttachToken &+= 1
        let myToken = markdownAttachToken

        removeMarkdownPlaceholder()
        webView?.removeFromSuperview()
        webView = nil
        overlay?.removeFromSuperview()
        overlay = nil

        // Render the template synchronously (fast — file read + string substitution).
        // If that fails, skip the whole WebView spin-up and show the error directly.
        let html: String
        let baseURL: URL
        do {
            (html, baseURL) = try MarkdownRenderer.render(filePath: filePath)
        } catch {
            showError("Failed to render \((filePath as NSString).lastPathComponent)\n\(error)")
            return
        }

        // Seed the heal cache so a later move/rename can be matched by content hash.
        AppServices.shared.markdownPathHealer.recordHash(frameId: routeId, filePath: filePath)

        showMarkdownLoadingPlaceholder()

        let config = WebKitConfig.shared.makeConfiguration()
        let wv = WKWebView(frame: contentClip.bounds, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.autoresizingMask = [.width, .height]
        wv.alphaValue = 0
        contentClip.addSubview(wv)
        self.webView = wv

        let coordinator = WebViewCoordinator()
        coordinator.onLoadingFinished = { [weak self, weak wv] in
            guard let self, let wv else { return }
            guard self.markdownAttachToken == myToken else { return }
            self.removeMarkdownLoadingPlaceholder()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                wv.animator().alphaValue = 1.0
            }
        }
        coordinator.onLoadingFailed = { [weak self] message in
            guard let self else { return }
            guard self.markdownAttachToken == myToken else { return }
            self.removeMarkdownLoadingPlaceholder()
            self.showError("Failed to render \((filePath as NSString).lastPathComponent)\n\(message)")
        }
        wv.navigationDelegate = coordinator
        self.navigationDelegate = coordinator

        wv.loadHTMLString(html, baseURL: baseURL)

        // Interaction overlay — without it the WKWebView swallows clicks/right-click,
        // breaking selection, drag, and the "Remove from Canvas" context menu.
        let ov = InteractionOverlay(frame: contentClip.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.interactionRouter = interactionRouter
        ov.documentView = documentView
        ov.routeId = routeId
        ov.interactHintCoordinator = interactHintCoordinator
        ov.routeOriginGetter = { [weak self] in
            guard let self else { return .zero }
            return self.frame.origin
        }
        contentClip.addSubview(ov, positioned: .above, relativeTo: wv)
        self.overlay = ov
    }

    private func showMarkdownLoadingPlaceholder() {
        guard markdownLoadingPlaceholder == nil else { return }
        let p = NSView(frame: contentClip.bounds)
        p.wantsLayer = true
        p.layer?.backgroundColor = NSColor(red: 0x19/255.0, green: 0x1A/255.0,
                                           blue: 0x1D/255.0, alpha: 1.0).cgColor
        p.autoresizingMask = [.width, .height]
        contentClip.addSubview(p)
        markdownLoadingPlaceholder = p
    }

    private func removeMarkdownLoadingPlaceholder() {
        markdownLoadingPlaceholder?.removeFromSuperview()
        markdownLoadingPlaceholder = nil
    }

    // MARK: - Image view attach (NSImage, downsampled off-main via CGImageSource)

    private func attachImageView(filePath: String) {
        // Same file already attached — nothing to do. NSImageView rescales on bounds change,
        // so frame resizes don't need a re-decode.
        if attachedImagePath == filePath, imageView?.image != nil, imagePlaceholder == nil {
            imageView?.frame = contentClip.bounds
            return
        }

        imageAttachToken &+= 1
        let myToken = imageAttachToken

        imageView?.removeFromSuperview()
        imageView = nil
        attachedImagePath = filePath
        showImagePlaceholder()

        let maxPx = max(contentClip.bounds.width, contentClip.bounds.height) *
                    (NSScreen.main?.backingScaleFactor ?? 2.0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.downsampledImage(at: filePath, maxPixelSize: maxPx)
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.imageAttachToken == myToken else { return }
                guard self.attachedImagePath == filePath else { return }
                self.removeImagePlaceholder()
                let iv = NSImageView(frame: self.contentClip.bounds)
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.imageAlignment = .alignCenter
                iv.autoresizingMask = [.width, .height]
                iv.animates = false
                iv.image = image
                iv.alphaValue = 0
                self.contentClip.addSubview(iv)
                self.imageView = iv
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    iv.animator().alphaValue = 1.0
                }
            }
        }
    }

    private func showImagePlaceholder() {
        guard imagePlaceholder == nil else { return }
        let p = NSView(frame: contentClip.bounds)
        p.wantsLayer = true
        p.layer?.backgroundColor = NSColor(red: 0x19/255.0, green: 0x1A/255.0,
                                           blue: 0x1D/255.0, alpha: 1.0).cgColor
        p.autoresizingMask = [.width, .height]
        contentClip.addSubview(p)
        imagePlaceholder = p
    }

    private func removeImagePlaceholder() {
        imagePlaceholder?.removeFromSuperview()
        imagePlaceholder = nil
    }

    /// Downsample an image to display size via CGImageSource to avoid loading the full
    /// uncompressed bitmap into memory. Falls back to NSImage(contentsOfFile:) for SVG
    /// or anything CGImageSource can't thumbnail.
    static func downsampledImage(at filePath: String, maxPixelSize: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) {
            return NSImage(cgImage: cg, size: .zero)
        }
        // Fallback: vector formats (SVG) and anything CGImageSource skips.
        return NSImage(contentsOfFile: filePath)
    }

    // MARK: - Markdown placeholder (LOD cap)

    /// Swap the markdown WKWebView for a "click to load" placeholder. Called by
    /// MarkdownTileManager when this frame is the least-recently-viewed over the live cap.
    func showMarkdownPlaceholder() {
        guard kind == .markdown else { return }
        webView?.removeFromSuperview()
        webView = nil
        overlay?.removeFromSuperview()
        overlay = nil

        guard markdownPlaceholder == nil else { return }
        let placeholder = NSView(frame: contentClip.bounds)
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor(red: 0x19/255.0, green: 0x1A/255.0,
                                                     blue: 0x1D/255.0, alpha: 1.0).cgColor
        placeholder.autoresizingMask = [.width, .height]

        let message = NSTextField(labelWithString: "Click to load\n\((routePath as NSString).lastPathComponent)")
        message.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        message.textColor = NSColor(red: 0x88/255.0, green: 0x88/255.0, blue: 0x88/255.0, alpha: 1.0)
        message.alignment = .center
        message.isBordered = false
        message.backgroundColor = .clear
        message.usesSingleLineMode = false
        message.sizeToFit()
        message.frame = NSRect(x: 0,
                               y: (placeholder.bounds.height - message.frame.height) / 2,
                               width: placeholder.bounds.width,
                               height: message.frame.height)
        message.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        placeholder.addSubview(message)
        contentClip.addSubview(placeholder)
        self.markdownPlaceholder = placeholder
    }

    private func removeMarkdownPlaceholder() {
        markdownPlaceholder?.removeFromSuperview()
        markdownPlaceholder = nil
    }

    /// True when this markdown frame is currently in "click to load" state.
    var isMarkdownPlaceholder: Bool {
        kind == .markdown && markdownPlaceholder != nil
    }

    /// Re-attach the live WKWebView (caller = MarkdownTileManager promoting this frame).
    func promoteMarkdownFromPlaceholder() {
        guard kind == .markdown else { return }
        attachMarkdownWebView(filePath: routePath)
    }

    // MARK: - Reload (FileWatcher integration — Stage 7)

    /// Reload the content. For markdown: re-render HTML and loadHTMLString again.
    /// For image: re-downsample and re-assign.
    /// For route: re-navigate live frames to their configured path (handles
    /// SPA drift during dev-server outages). Screenshot/queued frames stay as-is.
    func reload() {
        // Clear any error overlay up front. Without this, a successful re-render
        // would attach behind a persistent errorLabel and the user would still see
        // the stale error (showError() is gated by `errorLabel == nil`).
        hideError()

        switch kind {
        case .route:
            let state = tileLifecycle?.frameStates[routeId]
            if state == .live || state == .loadingLive {
                tileLifecycle?.reloadRoute(frameId: routeId)
            }
            return
        case .markdown:
            if markdownPlaceholder != nil { return }  // stays in placeholder state; will reload on promote
            attachMarkdownWebView(filePath: routePath)
        case .image:
            imageView?.image = nil
            attachImageView(filePath: routePath)
        }
    }

    // MARK: - Pool-ready WebView API

    /// Show placeholder state (no webview). Used when frame is outside viewport.
    func showPlaceholder() {
        removeMetricsHandler()
        webView?.removeFromSuperview()
        webView = nil
        overlay?.removeFromSuperview()
        overlay = nil
        navigationDelegate = nil
        removeShimmer()
        hideError()
        // Reset to dark background for unloaded state
        contentClip.layer?.backgroundColor = NSColor(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0, alpha: 1.0).cgColor
    }

    /// Attach a live WKWebView into this container. Places InteractionOverlay on top.
    /// Registers the FrameMetricsHandler for auto-height measurement (Stage 3c).
    func attachWebView(_ wv: WKWebView) {
        // Remove any existing webview first
        self.webView?.removeFromSuperview()
        self.overlay?.removeFromSuperview()
        removeMetricsHandler()

        self.webView = wv
        wv.frame = contentClip.bounds
        wv.autoresizingMask = [.width, .height]
        contentClip.addSubview(wv)

        // Disable WKWebView internal rubber-banding (find the INTERNAL scroll view)
        disableWebViewRubberBanding(wv)

        // Interaction overlay — blocks events so canvas panning works
        let ov = InteractionOverlay(frame: contentClip.bounds)
        ov.autoresizingMask = [.width, .height]
        ov.interactionRouter = interactionRouter
        ov.documentView = documentView
        ov.routeId = routeId
        ov.interactHintCoordinator = interactHintCoordinator
        ov.routeOriginGetter = { [weak self] in
            guard let self else { return .zero }
            return self.frame.origin
        }
        contentClip.addSubview(ov, positioned: .above, relativeTo: wv)
        self.overlay = ov

        // URL change tracking for focus navigation capsule
        urlObservation = wv.observe(\.url, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async { self?.handleURLChange(webView.url) }
        }
        canGoBackObservation = wv.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateNavigationControls() }
        }
        // SPA navigation handler (pushState/replaceState)
        // Safety: remove any stale dcNavChange handler (pool webview may still carry one
        // if a previous demote's async snapshot raced with a re-promote)
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "dcNavChange")
        let handler = NavChangeHandler { [weak self] url in self?.handleURLChange(url) }
        wv.configuration.userContentController.add(handler, name: "dcNavChange")
        navChangeHandler = handler

        showLoading()
    }

    /// Callback set by CanvasContainerView to update DocumentModel when height is measured.
    var onHeightMeasured: ((CGFloat) -> Void)?

    /// Store a pre-registered FrameMetricsHandler (registered on config before webview creation).
    func storeMetricsHandler(_ handler: FrameMetricsHandler) {
        self.metricsHandler = handler
    }

    /// Detach and return the WKWebView for reuse in another container (Stage 5 pooling).
    func detachWebView() -> WKWebView? {
        // Tear down focus navigation tracking
        urlObservation?.invalidate()
        urlObservation = nil
        canGoBackObservation?.invalidate()
        canGoBackObservation = nil
        if navChangeHandler != nil {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "dcNavChange")
            navChangeHandler = nil
        }
        hasNavigatedAway = false
        currentLiveURL = nil
        applyLabelText()
        updateNavigationControls()

        removeMetricsHandler()
        let wv = webView
        webView?.removeFromSuperview()
        webView = nil
        overlay?.removeFromSuperview()
        overlay = nil
        navigationDelegate = nil
        removeShimmer()
        hideError()
        // Reset to dark placeholder bg — frame has no live content after detach
        contentClip.layer?.backgroundColor = NSColor(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0, alpha: 1.0).cgColor
        return wv
    }

    // MARK: - Screenshot display

    /// Show a cached screenshot in this container (for non-live frames).
    /// The screenshot sits behind the webview layer so it's visible when no webview is attached.
    func showScreenshot(fileURL: URL) {
        removeShimmer()

        if screenshotView == nil {
            let sv = ScreenshotFrameView(frame: contentClip.bounds)
            sv.autoresizingMask = [.width, .height]
            // Insert below webview/overlay inside the clipped content area
            contentClip.addSubview(sv, positioned: .below, relativeTo: webView ?? overlay)
            screenshotView = sv
        }
        screenshotView?.setScreenshot(fileURL: fileURL)
    }

    /// Remove the screenshot view (e.g., when a live webview fully covers the frame).
    func clearScreenshot() {
        screenshotView?.removeFromSuperview()
        screenshotView = nil
    }

    // MARK: - Edge + corner resize (Figma-style drag)

    private enum ResizeMode { case bottom, right, corner }

    private struct ResizeState {
        let mode: ResizeMode
        let startDocX: CGFloat
        let startDocY: CGFloat
        let originalWidth: CGFloat
        let originalHeight: CGFloat
        let aspectRatio: CGFloat
        let isImageFrame: Bool
    }

    private var resizeState: ResizeState?
    private var isResizeCursorActive = false

    /// Check if a point (in local/flipped coordinates) is within the bottom resize zone
    /// (excluding the bottom-right corner square, which has its own zone).
    private func isBottomResizeZone(_ localPoint: NSPoint) -> Bool {
        let zone = 8.0 / max(camera?.zoom ?? 1.0, 0.1)
        return localPoint.y >= bounds.height - zone && localPoint.y <= bounds.height
            && localPoint.x >= 0 && localPoint.x < bounds.width - zone
    }

    /// Right-edge resize zone (excludes the bottom-right corner square).
    private func isRightResizeZone(_ localPoint: NSPoint) -> Bool {
        let zone = 8.0 / max(camera?.zoom ?? 1.0, 0.1)
        return localPoint.x >= bounds.width - zone && localPoint.x <= bounds.width
            && localPoint.y >= 0 && localPoint.y < bounds.height - zone
    }

    /// Bottom-right corner resize zone — drives both width and height together.
    private func isCornerResizeZone(_ localPoint: NSPoint) -> Bool {
        let zone = 8.0 / max(camera?.zoom ?? 1.0, 0.1)
        return localPoint.x >= bounds.width - zone && localPoint.y >= bounds.height - zone
            && localPoint.x <= bounds.width && localPoint.y <= bounds.height
    }

    // MARK: - Drag handling (screenshot frames + label-area drag for all frames)

    private struct FrameDragState {
        let startWindowPoint: NSPoint
        let startDocPoint: NSPoint
        let originalOrigin: NSPoint
        var isDragging: Bool = false
        var peerOrigins: [UUID: NSPoint]?  // Non-nil during multi-drag
    }

    private var frameDragState: FrameDragState?

    /// Check if an event location falls in the label area (above the frame content).
    private func isLabelAreaHit(_ event: NSEvent) -> Bool {
        let local = convert(event.locationInWindow, from: nil)
        return label.frame.contains(local)
    }

    override func mouseDown(with event: NSEvent) {
        if interactionRouter?.isTemporaryPanMode == true {
            super.mouseDown(with: event)
            return
        }

        guard let docView = documentView else { return }
        let local = convert(event.locationInWindow, from: nil)
        let docPoint = docView.convert(event.locationInWindow, from: nil)

        // Removed frames: only allow label-area drag (repositioning). Block everything else.
        if wasRemoved {
            if isLabelAreaHit(event) {
                frameDragState = FrameDragState(
                    startWindowPoint: event.locationInWindow,
                    startDocPoint: docPoint,
                    originalOrigin: frame.origin
                )
            }
            return
        }

        // Resize zones take priority over everything else. Order: corner > right > bottom
        // so the most specific zone (corner overlap) wins.
        let isImg = interactionRouter?.isImageFrame(routeId) ?? false
        let aspect = frame.width / max(frame.height, 1)

        if isCornerResizeZone(local) {
            resizeState = ResizeState(mode: .corner,
                                      startDocX: docPoint.x, startDocY: docPoint.y,
                                      originalWidth: frame.width, originalHeight: frame.height,
                                      aspectRatio: aspect, isImageFrame: isImg)
            showDimensionReadout()
            return
        }
        if isRightResizeZone(local) {
            resizeState = ResizeState(mode: .right,
                                      startDocX: docPoint.x, startDocY: docPoint.y,
                                      originalWidth: frame.width, originalHeight: frame.height,
                                      aspectRatio: aspect, isImageFrame: isImg)
            showDimensionReadout()
            return
        }
        if isBottomResizeZone(local) {
            resizeState = ResizeState(mode: .bottom,
                                      startDocX: docPoint.x, startDocY: docPoint.y,
                                      originalWidth: frame.width, originalHeight: frame.height,
                                      aspectRatio: aspect, isImageFrame: isImg)
            showDimensionReadout()
            return
        }

        // Click-to-promote: clicking a queued frame jumps the queue
        if tileLifecycle?.frameStates[routeId] == .queued, overlay == nil, !isLabelAreaHit(event) {
            tileLifecycle?.promoteToLive(frameId: routeId)
            return
        }

        // Label-area clicks start a drag even on live frames (which have an overlay)
        let labelHit = isLabelAreaHit(event)
        guard overlay == nil || labelHit else { super.mouseDown(with: event); return }

        // Focus mode: clicking on the label area opens the URL editor instead of dragging.
        // To drag the frame, exit focus (click outside or Escape).
        if labelHit, handleLabelClickIfFocused(at: local) { return }

        frameDragState = FrameDragState(
            startWindowPoint: event.locationInWindow,
            startDocPoint: docPoint,
            originalOrigin: frame.origin
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let docView = documentView else { return }

        // Edge + corner resize drag
        if let state = resizeState {
            let docPoint = docView.convert(event.locationInWindow, from: nil)
            let deltaX = docPoint.x - state.startDocX
            let deltaY = docPoint.y - state.startDocY
            var newW = state.originalWidth
            var newH = state.originalHeight

            switch state.mode {
            case .bottom:
                newH = state.originalHeight + deltaY
            case .right:
                newW = state.originalWidth + deltaX
            case .corner:
                newW = state.originalWidth + deltaX
                newH = state.originalHeight + deltaY
                // Image corner drag defaults to aspect-locked to avoid letterboxing.
                // Shift breaks the lock for free resize.
                let shiftHeld = event.modifierFlags.contains(.shift)
                if state.isImageFrame && !shiftHeld {
                    if abs(deltaX) >= abs(deltaY) {
                        newH = newW / state.aspectRatio
                    } else {
                        newW = newH * state.aspectRatio
                    }
                }
            }

            newW = min(max(newW, FrameMetricsHandler.minWidth), FrameMetricsHandler.maxWidth)
            newH = min(max(newH, FrameMetricsHandler.minHeight), FrameMetricsHandler.maxHeight)

            frame.size = NSSize(width: newW, height: newH)
            contentClip.frame = bounds
            webView?.frame = contentClip.bounds
            overlay?.frame = contentClip.bounds
            if state.mode != .bottom { layoutLabel() }
            updateShadowHost()
            updateShadowHostFrame()
            updateDimensionReadout()
            return
        }

        // Frame move drag
        guard var state = frameDragState, let router = interactionRouter else { return }

        if !state.isDragging {
            let dx = event.locationInWindow.x - state.startWindowPoint.x
            let dy = event.locationInWindow.y - state.startWindowPoint.y
            guard hypot(dx, dy) > 3.0 else { return }
            state.isDragging = true
            router.isDragging = true
            router.draggingFrameId = routeId

            // Multi-drag: if this frame is selected, drag all selected frames
            if router.selectedFrameIds.contains(routeId) {
                router.draggingFrameIds = router.selectedFrameIds
                var origins: [UUID: NSPoint] = [:]
                for peerId in router.selectedFrameIds where peerId != routeId {
                    if let c = router.findContainer(withId: peerId) {
                        origins[peerId] = c.frame.origin
                    }
                }
                state.peerOrigins = origins
            } else {
                router.draggingFrameIds = [routeId]
            }
        }

        let docPoint = docView.convert(event.locationInWindow, from: nil)
        let deltaX = docPoint.x - state.startDocPoint.x
        let deltaY = docPoint.y - state.startDocPoint.y

        frame.origin = NSPoint(
            x: state.originalOrigin.x + deltaX,
            y: state.originalOrigin.y + deltaY
        )
        shadowHost?.frame.origin = NSPoint(
            x: frame.origin.x - (shadowHost?.layer?.borderWidth ?? 0),
            y: frame.origin.y - (shadowHost?.layer?.borderWidth ?? 0)
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

        frameDragState = state
    }

    override func mouseUp(with event: NSEvent) {
        // Edge/corner resize commit
        if resizeState != nil {
            interactionRouter?.commitResize(routeId: routeId,
                                            width: round(frame.width),
                                            height: round(frame.height))
            resizeState = nil
            hideDimensionReadout()
            return
        }

        guard overlay == nil || frameDragState != nil else { super.mouseUp(with: event); return }
        defer { frameDragState = nil }
        guard let state = frameDragState, let router = interactionRouter else { return }

        if state.isDragging {
            if let peers = state.peerOrigins, !peers.isEmpty {
                // Multi-drag commit — all selected frames
                var moves: [(routeId: UUID, x: CGFloat, y: CGFloat)] = [
                    (routeId, round(frame.origin.x), round(frame.origin.y))
                ]
                for peerId in peers.keys {
                    if let c = router.findContainer(withId: peerId) {
                        moves.append((peerId, round(c.frame.origin.x), round(c.frame.origin.y)))
                    }
                }
                router.commitMultiMove(moves: moves)
            } else {
                router.commitMove(routeId: routeId, x: round(frame.origin.x), y: round(frame.origin.y))
            }
        } else {
            // Click (no drag) — select frame.
            // (Note: the old "click label to go home" gesture was replaced by the
            // divergence-dot menu in focus mode; clicks on the label there enter
            // the URL editor via mouseDown.)
            let extending = event.modifierFlags.contains(.shift)
            router.selectFrame(routeId, extending: extending)
        }
    }

    // MARK: - Right-click context menu (screenshot frames without overlay)

    override func rightMouseDown(with event: NSEvent) {
        guard overlay == nil else { super.rightMouseDown(with: event); return }
        let menu = FrameContextMenu.build(for: self)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: - Hard refresh (cache-busting reload)

    /// Reload the page bypassing WKWebView's cache. Uses reloadIgnoringLocalCacheData
    /// so each frame is refreshed independently without nuking cookies/sessions for others.
    /// Markdown frames are loaded via `loadHTMLString` (so `webView.url` is nil) and image
    /// frames have no WKWebView at all — both route through `reload()` to re-read from disk.
    func hardRefresh() {
        switch kind {
        case .markdown, .image:
            reload()
            return
        case .route:
            break
        }
        guard let webView, let url = webView.url else { return }
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))

        // Re-capture screenshot once the page finishes loading so zoomed-out
        // thumbnail reflects the fresh content.
        let frameId = routeId
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak webView] in
            webView?.takeSnapshot(with: nil) { image, _ in
                guard let image else { return }
                self?.tileLifecycle?.saveFreshScreenshot(image, frameId: frameId)
            }
        }
    }

    /// Remove the WKScriptMessageHandler to avoid retain cycles (WKUserContentController retains handlers).
    private func removeMetricsHandler() {
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: FrameMetricsHandler.messageName
        )
        metricsHandler = nil
    }

    /// Trigger height measurement. Calls the global function if setup, otherwise runs full script.
    func triggerHeightMeasurement(_ wv: WKWebView? = nil) {
        let target = wv ?? webView
        target?.evaluateJavaScript(
            "if (window.__dcReportHeight) window.__dcReportHeight(); else { \(WebKitConfig.heightMeasurementJS) }",
            completionHandler: nil
        )
    }

    /// On-demand intrinsic height measurement for "Fit to Content".
    /// Neutralises viewport-relative CSS, measures, restores. Returns clamped height.
    func measureFitToContentHeight() async -> CGFloat? {
        guard let wv = webView else { return nil }
        do {
            let result = try await wv.evaluateJavaScript(WebKitConfig.fitToContentJS)
            guard let raw = result as? NSNumber else { return nil }
            let h = CGFloat(raw.doubleValue)
            guard h > 0 else { return nil }
            return min(max(h, FrameMetricsHandler.minHeight), FrameMetricsHandler.maxHeight)
        } catch {
            return nil
        }
    }

    // MARK: - Visual frame states

    /// Compute border width that stays consistent in screen pixels regardless of zoom.
    private func scaledBorder(_ screenPx: CGFloat) -> CGFloat {
        let zoom = max(camera?.zoom ?? 1.0, 0.1)
        return max(screenPx / zoom, 0.5)
    }

    /// Apply visual state based on InteractionRouter state. Called from updateNSView.
    /// Border is rendered on the shadowHost (outside the frame content area).
    /// Two states: default and focus (double-clicked). No selection state.
    func applyVisualState() {
        guard let router = interactionRouter, let host = shadowHost else { return }

        let isFocused = router.activeFrameId == routeId
        let state = tileLifecycle?.frameStates[routeId]

        if wasRemoved {
            // Removed: muted red border, red label, dim overlay + badge
            let bw = scaledBorder(1.5)
            host.layer?.borderWidth = bw
            host.layer?.borderColor = Self.removedBorderColor.cgColor
            host.layer?.cornerRadius = 8 + bw
            label.textColor = Self.removedLabelColor
            host.layer?.shadowColor = NSColor(white: 0, alpha: 0.2).cgColor
            host.layer?.shadowRadius = 8
            host.layer?.shadowOpacity = 1.0
            showRemovedOverlay()
        } else if isFocused {
            // Focus mode: 4 screen-px white outside border, primary label, white glow
            let bw = scaledBorder(4.0)
            host.layer?.borderWidth = bw
            host.layer?.borderColor = Self.selectionColor.cgColor
            host.layer?.cornerRadius = 8 + bw
            label.textColor = Self.labelPrimary
            host.layer?.shadowColor = NSColor(white: 1.0, alpha: 0.15).cgColor
            host.layer?.shadowRadius = 20
            host.layer?.shadowOpacity = 1.0
            hideRemovedOverlay()
        } else if router.selectedFrameIds.contains(routeId) {
            // Selected (multi-select): 2 screen-px white border, primary label, subtle glow
            let bw = scaledBorder(2.0)
            host.layer?.borderWidth = bw
            host.layer?.borderColor = Self.selectionColor.cgColor
            host.layer?.cornerRadius = 8 + bw
            label.textColor = Self.labelPrimary
            host.layer?.shadowColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            host.layer?.shadowRadius = 12
            host.layer?.shadowOpacity = 1.0
            hideRemovedOverlay()
        } else if state == .queued {
            // Queued: hairline accent border, muted label
            let bw = scaledBorder(1.5)
            host.layer?.borderWidth = bw
            host.layer?.borderColor = Self.accentBorderQueued.cgColor
            host.layer?.cornerRadius = 8 + bw
            label.textColor = Self.labelMuted
            host.layer?.shadowColor = NSColor(white: 0, alpha: 0.4).cgColor
            host.layer?.shadowRadius = 12
            host.layer?.shadowOpacity = 1.0
        } else if state == .loadingLive {
            // Loading: accent border at 10%, accent-tinted label
            let bw = scaledBorder(1.5)
            host.layer?.borderWidth = bw
            host.layer?.borderColor = Self.accentBorderLoading.cgColor
            host.layer?.cornerRadius = 8 + bw
            label.textColor = Self.accentColor
            host.layer?.shadowColor = NSColor(white: 0, alpha: 0.4).cgColor
            host.layer?.shadowRadius = 12
            host.layer?.shadowOpacity = 1.0
        } else {
            // Default / live / screenshot: standard grey border, muted label.
            // Demo mode (Phase 2b): swap the border colour to accent-tinted 45% alpha.
            // Storm pause: route frames in live/loadingLive get the accent halo so
            // the paused state is visible canvas-wide, not just at the top-left card.
            let bw = scaledBorder(1.5)
            host.layer?.borderWidth = bw
            let stormPaused = AppServices.shared.stormDetector.isPaused
                && kind == .route
                && (state == .live || state == .loadingLive)
            host.layer?.borderColor = stormPaused
                ? Self.borderStormPaused.cgColor
                : (isDemoMode ? Self.borderDemo.cgColor : Self.borderDefault.cgColor)
            host.layer?.cornerRadius = 8 + bw
            label.textColor = Self.labelMuted
            host.layer?.shadowColor = NSColor(white: 0, alpha: 0.4).cgColor
            host.layer?.shadowRadius = 12
            host.layer?.shadowOpacity = 1.0
            hideRemovedOverlay()
        }

        // Expand shadow host outward by the border width so border sits outside the frame
        updateShadowHostFrame()
        updateNavigationControls()
        updateChromeVisibility()
    }

    /// Position shadowHost so its border extends outside the container frame.
    private func updateShadowHostFrame() {
        guard let host = shadowHost else { return }
        let bw = host.layer?.borderWidth ?? 0
        host.frame = NSRect(
            x: frame.origin.x - bw,
            y: frame.origin.y - bw,
            width: frame.width + bw * 2,
            height: frame.height + bw * 2
        )
    }

    // MARK: - Focus navigation (label-area back chevron + clickable label)

    private var backChevron: NSButton?
    /// True when the label is acting as a clickable "go home" control.
    private var labelIsClickable = false

    // MARK: - Active-state chrome controls (Phase 2)
    //
    // These augment the label area into a thin browser-like row when the frame is
    // hovered or focused. Default state is unchanged from the static label.
    //   - closeButton: visible on hover or focus. Removes the frame.
    //   - refreshButton: visible on focus. Reloads the WKWebView.
    //   - divergenceDot: visible on focus when the live URL has diverged from the
    //                    saved route path. Click opens a menu (Reset / Pin).

    private var closeButton: NSButton?
    private var refreshButton: NSButton?
    private var divergenceDot: NSButton?

    /// Updated by mouseEntered / mouseExited so chrome visibility can react.
    private var isHovered: Bool = false

    /// True while the URL label is acting as an editable URL field.
    private var isURLEditing: Bool = false

    /// Last known good URL string — used to revert on Escape.
    private var urlEditPreviousValue: String = ""

    private func handleURLChange(_ newURL: URL?) {
        guard let newURL else { return }
        currentLiveURL = newURL
        if let originalURL {
            hasNavigatedAway = (normalizedURL(originalURL) != normalizedURL(newURL))
        }
        applyLabelText()
        layoutLabel()
        updateNavigationControls()
    }

    /// Compute the label text from current state. Precedence:
    /// 1. user-set displayName (if any)
    /// 2. live navigated URL path (+ query, no fragment)
    /// 3. routePath fallback
    private func applyLabelText() {
        if let name = currentDisplayName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            label.stringValue = name
            return
        }
        if let url = currentLiveURL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let path = components?.path ?? url.path
            let pathOrSlash = path.isEmpty ? "/" : path
            if let q = components?.query, !q.isEmpty {
                label.stringValue = "\(pathOrSlash)?\(q)"
            } else {
                label.stringValue = pathOrSlash
            }
            return
        }
        label.stringValue = routePath
    }

    private func normalizedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let str = components?.url?.absoluteString ?? url.absoluteString
        return str.hasSuffix("/") ? String(str.dropLast()) : str
    }

    /// Show/hide the back chevron and make label clickable based on focus + navigation state.
    private func updateNavigationControls() {
        let isFocused = interactionRouter?.activeFrameId == routeId
        let showBack = isFocused && hasNavigatedAway && (webView?.canGoBack ?? false)
        let showHome = isFocused && hasNavigatedAway

        if showBack {
            if backChevron == nil {
                let btn = NSButton(frame: .zero)
                btn.bezelStyle = .inline
                btn.isBordered = false
                btn.title = "‹"
                btn.contentTintColor = Self.labelMuted
                btn.target = self
                btn.action = #selector(backChevronTapped)
                addSubview(btn)
                backChevron = btn
            }
            backChevron?.isHidden = false
        } else {
            backChevron?.isHidden = true
        }

        labelIsClickable = showHome
        // Brighter label when clickable to hint at interactivity
        if showHome {
            label.textColor = Self.labelPrimary
        }
        // Label position is updated in layoutLabel() called from update(route:)
        layoutLabel()
    }

    @objc private func backChevronTapped() {
        webView?.goBack()
    }

    /// Handle click on the label text — go home if navigated away in focus mode.
    func handleLabelClick() {
        guard labelIsClickable else { return }
        resetToOriginalURLIfNeeded()
    }

    /// If the webview has navigated away from the original route URL, reload it.
    func resetToOriginalURLIfNeeded() {
        guard hasNavigatedAway, let originalURL, let webView else { return }
        webView.load(URLRequest(url: originalURL))
        hasNavigatedAway = false
    }

    // MARK: - Active-state chrome controls

    /// True when divergence indicator should show (live URL ≠ saved route path).
    private var isDiverged: Bool {
        guard kind == .route, hasNavigatedAway, let originalURL, let liveURL = currentLiveURL else {
            return false
        }
        return normalizedURL(originalURL) != normalizedURL(liveURL)
    }

    /// Lazily create the chrome buttons. Called the first time we need them.
    private func setupChromeControlsIfNeeded() {
        guard kind == .route else { return }

        if closeButton == nil {
            let btn = makeSymbolButton(symbolName: "xmark", action: #selector(closeButtonTapped))
            addSubview(btn)
            btn.alphaValue = 0
            btn.isHidden = true
            closeButton = btn
        }
        if refreshButton == nil {
            let btn = makeSymbolButton(symbolName: "arrow.clockwise", action: #selector(refreshButtonTapped))
            addSubview(btn)
            btn.alphaValue = 0
            btn.isHidden = true
            refreshButton = btn
        }
        if divergenceDot == nil {
            let btn = makeSymbolButton(symbolName: "circle.fill", action: #selector(divergenceDotTapped))
            btn.contentTintColor = Self.accentColor
            addSubview(btn)
            btn.alphaValue = 0
            btn.isHidden = true
            divergenceDot = btn
        }
    }

    private func makeSymbolButton(symbolName: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: .zero)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.contentTintColor = Self.labelMuted
        btn.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName)
        btn.target = self
        btn.action = action
        return btn
    }

    /// Position chrome buttons within the label area. Called from layoutLabel().
    private func layoutChromeControls(zoom: CGFloat, labelY: CGFloat, labelHeight: CGFloat) {
        let buttonSize = ceil(14.0 / zoom)
        let buttonGap = ceil(6.0 / zoom)
        let dotSize = ceil(6.0 / zoom)
        let buttonY = labelY + (labelHeight - buttonSize) / 2
        let dotY = labelY + (labelHeight - dotSize) / 2

        var rightX = frame.width
        if let close = closeButton, !close.isHidden {
            rightX -= buttonSize
            close.frame = NSRect(x: rightX, y: buttonY, width: buttonSize, height: buttonSize)
            rightX -= buttonGap
        }
        if let refresh = refreshButton, !refresh.isHidden {
            rightX -= buttonSize
            refresh.frame = NSRect(x: rightX, y: buttonY, width: buttonSize, height: buttonSize)
            rightX -= buttonGap
        }
        if let dot = divergenceDot, !dot.isHidden {
            rightX -= dotSize
            dot.frame = NSRect(x: rightX, y: dotY, width: dotSize, height: dotSize)
            rightX -= buttonGap
        }

        // Clip the label so it doesn't overlap the right-aligned buttons.
        let maxLabelRight = max(rightX, label.frame.minX)
        if label.frame.maxX > maxLabelRight {
            let newWidth = max(0, maxLabelRight - label.frame.minX)
            label.frame = NSRect(x: label.frame.minX, y: label.frame.minY,
                                 width: newWidth, height: label.frame.height)
        }
    }

    /// Compute and apply chrome visibility for the current focus / hover / divergence state.
    private func updateChromeVisibility() {
        guard kind == .route else {
            closeButton?.isHidden = true
            refreshButton?.isHidden = true
            divergenceDot?.isHidden = true
            return
        }
        let isFocused = (interactionRouter?.activeFrameId == routeId)
        let showClose = !wasRemoved && (isFocused || isHovered)
        let showRefresh = !wasRemoved && isFocused
        let showDot = !wasRemoved && isFocused && isDiverged

        if showClose || showRefresh || showDot {
            setupChromeControlsIfNeeded()
        }

        animateButtonVisibility(closeButton, visible: showClose)
        animateButtonVisibility(refreshButton, visible: showRefresh)
        animateButtonVisibility(divergenceDot, visible: showDot)
        layoutLabel()
    }

    private func animateButtonVisibility(_ button: NSButton?, visible: Bool) {
        guard let button else { return }
        if visible {
            button.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                button.animator().alphaValue = 1
            }
        } else if !button.isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                button.animator().alphaValue = 0
            }, completionHandler: { [weak button] in
                button?.isHidden = true
            })
        }
    }

    // MARK: - Chrome actions

    @objc private func closeButtonTapped() {
        AppServices.shared.canvasManager?.removeRoute(id: routeId)
    }

    @objc private func refreshButtonTapped() {
        hardRefresh()
    }

    @objc private func divergenceDotTapped() {
        guard isDiverged, let dot = divergenceDot else { return }
        let menu = NSMenu()

        let originalPath = originalURL?.path ?? routePath
        let resetItem = NSMenuItem(
            title: "Reset to \(originalPath.isEmpty ? "/" : originalPath)",
            action: #selector(divergenceMenuReset),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        if let liveURL = currentLiveURL {
            let livePath = liveURL.path.isEmpty ? "/" : liveURL.path
            let pinItem = NSMenuItem(
                title: "Pin \(livePath) as route",
                action: #selector(divergenceMenuPin),
                keyEquivalent: ""
            )
            pinItem.target = self
            menu.addItem(pinItem)
        }

        let pt = NSPoint(x: 0, y: dot.bounds.height + 4)
        menu.popUp(positioning: nil, at: pt, in: dot)
    }

    @objc private func divergenceMenuReset() {
        resetToOriginalURLIfNeeded()
    }

    @objc private func divergenceMenuPin() {
        guard let liveURL = currentLiveURL else { return }
        let newPath = liveURL.path.isEmpty ? "/" : liveURL.path
        _ = AppServices.shared.canvasManager?.updateRoute(id: routeId, newPath: newPath)
    }

    // MARK: - URL editing (click label in focus to edit)

    /// Returns true if a click at `point` (frame-local) hit the label area while focused
    /// and should open the URL editor instead of dragging.
    func handleLabelClickIfFocused(at point: NSPoint) -> Bool {
        guard kind == .route, !isURLEditing else { return false }
        guard interactionRouter?.activeFrameId == routeId else { return false }
        guard label.frame.contains(point) else { return false }
        beginURLEditing()
        return true
    }

    private func beginURLEditing() {
        isURLEditing = true
        urlEditPreviousValue = label.stringValue
        label.isEditable = true
        label.isSelectable = true
        label.delegate = self
        label.target = self
        label.action = #selector(urlFieldDidCommit)
        label.window?.makeFirstResponder(label)
        if let editor = label.currentEditor() as? NSTextView {
            editor.selectAll(nil)
            editor.insertionPointColor = Self.labelPrimary
        }
    }

    private func endURLEditing(commit: Bool) {
        guard isURLEditing else { return }
        isURLEditing = false
        let raw = label.stringValue
        label.isEditable = false
        label.isSelectable = false
        label.window?.makeFirstResponder(nil)
        if commit {
            commitURLEdit(raw)
        } else {
            label.stringValue = urlEditPreviousValue
        }
        applyLabelText()
        layoutLabel()
    }

    @objc private func urlFieldDidCommit() {
        endURLEditing(commit: true)
    }

    private func commitURLEdit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let target: URL?
        if trimmed.hasPrefix("/") {
            // Use this frame's binding so editing a /3001-frame's URL bar resolves to :3001,
            // not the document's primary binding.
            let doc = AppServices.shared.document
            let bindingId = doc.routes.first(where: { $0.id == routeId })?.serverBindingId
            target = doc.url(forPath: trimmed, bindingId: bindingId)
        } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            target = URL(string: trimmed)
        } else {
            target = URL(string: "http://\(trimmed)")
        }
        guard let url = target, let webView else { return }
        webView.load(URLRequest(url: url))
    }

    /// Position label (and back chevron if visible) above the frame.
    private func layoutLabel() {
        let zoom = max(camera?.zoom ?? 1.0, 0.1)
        let fontSize = 12.0 / zoom
        label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)

        let labelHeight = ceil(16.0 / zoom)
        let labelGap = ceil(8.0 / zoom)
        let labelY = -(labelHeight + labelGap)

        var labelX: CGFloat = 0
        if let chevron = backChevron, !chevron.isHidden {
            let chevronFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
            chevron.font = chevronFont
            let chevronW = ceil(fontSize * 0.8) + ceil(4.0 / zoom)
            let gap = ceil(4.0 / zoom)
            chevron.frame = NSRect(x: 0, y: labelY, width: chevronW, height: labelHeight)
            labelX = chevronW + gap
        }

        let routeWidth = frame.width
        let labelWidth = min(measuredLabelWidth() + ceil(4.0 / zoom), routeWidth - labelX)
        label.frame = NSRect(x: labelX, y: labelY, width: max(labelWidth, 0), height: labelHeight)

        // Position chrome buttons in the same row (right-aligned), and clip the label
        // so it doesn't overlap them.
        layoutChromeControls(zoom: zoom, labelY: labelY, labelHeight: labelHeight)
    }

    // MARK: - Dimension readout (live "W × H" during resize)

    /// Position the dimension readout above the frame, right-aligned (opposite the label).
    private func layoutDimensionReadout() {
        let zoom = max(camera?.zoom ?? 1.0, 0.1)
        let fontSize = 12.0 / zoom
        dimensionReadout.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let labelHeight = ceil(16.0 / zoom)
        let labelGap = ceil(8.0 / zoom)
        let padX = ceil(6.0 / zoom)
        dimensionReadout.sizeToFit()
        let w = dimensionReadout.frame.width + padX * 2
        dimensionReadout.frame = NSRect(
            x: frame.width - w,
            y: -(labelHeight + labelGap),
            width: w,
            height: labelHeight
        )
        dimensionReadout.layer?.cornerRadius = ceil(4.0 / zoom)
    }

    private func updateDimensionReadout() {
        dimensionReadout.stringValue = "\(Int(round(frame.width))) × \(Int(round(frame.height)))"
        layoutDimensionReadout()
    }

    private func showDimensionReadout() {
        updateDimensionReadout()
        dimensionReadout.isHidden = false
    }

    private func hideDimensionReadout() {
        dimensionReadout.isHidden = true
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        // Expand tracking rect to include the label + chevron area above bounds,
        // and the dimension readout (visible only during active resize drag).
        var trackingRect = bounds.union(label.frame)
        if let chevron = backChevron, !chevron.isHidden {
            trackingRect = trackingRect.union(chevron.frame)
        }
        if let close = closeButton, !close.isHidden {
            trackingRect = trackingRect.union(close.frame)
        }
        if let refresh = refreshButton, !refresh.isHidden {
            trackingRect = trackingRect.union(refresh.frame)
        }
        if let dot = divergenceDot, !dot.isHidden {
            trackingRect = trackingRect.union(dot.frame)
        }
        if !dimensionReadout.isHidden {
            trackingRect = trackingRect.union(dimensionReadout.frame)
        }
        let area = NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let zone = 8.0 / max(camera?.zoom ?? 1.0, 0.1)
        let bottomRect = NSRect(x: 0, y: bounds.height - zone,
                                width: bounds.width - zone, height: zone)
        let rightRect = NSRect(x: bounds.width - zone, y: 0,
                               width: zone, height: bounds.height - zone)
        let cornerRect = NSRect(x: bounds.width - zone, y: bounds.height - zone,
                                width: zone, height: zone)
        addCursorRect(bottomRect, cursor: .resizeUpDown)
        addCursorRect(rightRect, cursor: .resizeLeftRight)
        addCursorRect(cornerRect, cursor: .resizeLeftRight)
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let overClickableLabel = labelIsClickable && label.frame.contains(local)
        let overChevron = backChevron.map { !$0.isHidden && $0.frame.contains(local) } ?? false

        if overClickableLabel || overChevron {
            if !isResizeCursorActive {
                NSCursor.pointingHand.push()
                isResizeCursorActive = true
            }
        } else if isCornerResizeZone(local) {
            if isResizeCursorActive { NSCursor.pop() }
            NSCursor.resizeLeftRight.push()
            isResizeCursorActive = true
        } else if isRightResizeZone(local) {
            if isResizeCursorActive { NSCursor.pop() }
            NSCursor.resizeLeftRight.push()
            isResizeCursorActive = true
        } else if isBottomResizeZone(local) {
            if isResizeCursorActive { NSCursor.pop() }
            NSCursor.resizeUpDown.push()
            isResizeCursorActive = true
        } else if isResizeCursorActive {
            NSCursor.pop()
            isResizeCursorActive = false
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let router = interactionRouter, let host = shadowHost else { return }
        isHovered = true
        updateChromeVisibility()
        // Removed frames keep their red border on hover — don't change to grey/accent
        guard !wasRemoved else {
            tileLifecycle?.onHoverEnter(frameId: routeId)
            return
        }
        if router.activeFrameId != routeId && !router.selectedFrameIds.contains(routeId) {
            let state = tileLifecycle?.frameStates[routeId]
            let bw = scaledBorder(1.5)
            host.layer?.borderWidth = bw
            if state == .queued {
                // Queued hover: warm accent border — teaches "click to jump the queue"
                host.layer?.borderColor = Self.accentBorderHoverQ.cgColor
            } else {
                // Default hover: grey border
                host.layer?.borderColor = Self.borderHover.cgColor
            }
            host.layer?.cornerRadius = 8 + bw
            updateShadowHostFrame()
        }
        tileLifecycle?.onHoverEnter(frameId: routeId)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        // Revert to correct state
        applyVisualState()
        // Reset resize cursor if active
        if isResizeCursorActive {
            NSCursor.pop()
            isResizeCursorActive = false
        }
        // Stage 5: cancel pending hover promotion
        tileLifecycle?.onHoverExit(frameId: routeId)
    }

    // MARK: - Loading & Error Overlays

    private func showLoading() {
        hideError()
        addShimmer()
        scheduleLoadingDetail()
    }

    func hideLoading() {
        removeShimmer()
        removeLoadingDetail()
        // Page loaded — switch to white background so web content looks correct
        contentClip.layer?.backgroundColor = NSColor.white.cgColor
        playScaleSettle()
    }

    // MARK: - Shimmer (replaces spinner for ambient loading state)

    private func addShimmer() {
        guard shimmerLayer == nil else { return }
        let dark = NSColor(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0, alpha: 1.0).cgColor
        let light = NSColor(red: 0x22 / 255.0, green: 0x22 / 255.0, blue: 0x22 / 255.0, alpha: 1.0).cgColor
        let g = CAGradientLayer()
        g.colors = [dark, light, dark]
        g.locations = [0, 0.5, 1]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        g.frame = contentClip.bounds

        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-1.0, -0.5, 0.0] as [NSNumber]
        anim.toValue = [1.0, 1.5, 2.0] as [NSNumber]
        anim.duration = 2.0
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        g.add(anim, forKey: "shimmer")

        // Insert below webview/overlay so it's a background effect
        contentClip.layer?.insertSublayer(g, at: 0)
        shimmerLayer = g
    }

    private func removeShimmer() {
        shimmerLayer?.removeAllAnimations()
        shimmerLayer?.removeFromSuperlayer()
        shimmerLayer = nil
    }

    // MARK: - Scale-settle (micro spring on load complete)

    private func playScaleSettle() {
        guard let layer = contentClip.layer else { return }
        let anim = CASpringAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.995
        anim.toValue = 1.0
        anim.stiffness = 400
        anim.damping = 28
        anim.initialVelocity = 0
        anim.duration = anim.settlingDuration
        anim.isRemovedOnCompletion = true
        layer.add(anim, forKey: "scaleSettle")
    }

    // MARK: - Loading detail message (route-specific, escalating)

    /// Tag for the status label inside loadingDetailView so we can update it.
    private static let statusLabelTag = 9001

    private func scheduleLoadingDetail() {
        loadingDetailTimers.forEach { $0.cancel() }
        loadingDetailTimers.removeAll()

        let path = routePath
        let work3s = DispatchWorkItem { [weak self] in
            self?.showLoadingDetail(status: "Building \(path)\u{2026}")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work3s)
        loadingDetailTimers.append(work3s)

        let work10s = DispatchWorkItem { [weak self] in
            self?.updateLoadingDetailStatus("Your dev server may be compiling this route\u{2026}")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work10s)
        loadingDetailTimers.append(work10s)
    }

    private func showLoadingDetail(status: String) {
        guard loadingDetailView == nil, shimmerLayer != nil else { return }

        let zoom = max(camera?.zoom ?? 1.0, 0.1)
        let statusFontSize = 13.0 / zoom
        let totalWidth = 420.0 / zoom

        let container = NSView(frame: .zero)
        container.wantsLayer = true

        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.tag = Self.statusLabelTag
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: statusFontSize, weight: .medium)
        statusLabel.textColor = Self.labelMuted
        statusLabel.backgroundColor = .clear
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = totalWidth
        statusLabel.sizeToFit()

        let statusH = statusLabel.frame.height
        let clipBounds = contentClip.bounds

        container.frame = NSRect(
            x: (clipBounds.width - totalWidth) / 2,
            y: (clipBounds.height - statusH) / 2,
            width: totalWidth,
            height: statusH
        )
        container.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        statusLabel.frame = NSRect(x: 0, y: 0, width: totalWidth, height: statusH)
        container.addSubview(statusLabel)

        container.alphaValue = 0
        contentClip.addSubview(container, positioned: .above, relativeTo: overlay)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            container.animator().alphaValue = 1.0
        }
        loadingDetailView = container
    }

    private func updateLoadingDetailStatus(_ text: String) {
        guard let container = loadingDetailView,
              let statusLabel = container.viewWithTag(Self.statusLabelTag) as? NSTextField else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            container.animator().alphaValue = 0.3
        }, completionHandler: {
            statusLabel.stringValue = text
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                container.animator().alphaValue = 1.0
            }
        })
    }

    private func removeLoadingDetail() {
        loadingDetailTimers.forEach { $0.cancel() }
        loadingDetailTimers.removeAll()
        loadingDetailView?.removeFromSuperview()
        loadingDetailView = nil
    }

    func showError(_ message: String) {
        hideLoading()
        guard errorLabel == nil else { return }

        let errLabel = NSTextField(labelWithString: message)
        errLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        errLabel.textColor = Self.labelMuted
        errLabel.backgroundColor = .clear
        errLabel.alignment = .center
        errLabel.maximumNumberOfLines = 3
        errLabel.lineBreakMode = .byWordWrapping

        let clipBounds = contentClip.bounds
        errLabel.frame = NSRect(x: 16, y: (clipBounds.height - 60) / 2, width: clipBounds.width - 32, height: 60)
        errLabel.autoresizingMask = [.width, .minYMargin, .maxYMargin]

        // Dark surface behind error text so it's visible against white frame bg
        let bg = NSView(frame: clipBounds)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(
            red: 0x19 / 255.0,
            green: 0x1A / 255.0,
            blue: 0x1D / 255.0,
            alpha: 1.0
        ).cgColor
        bg.autoresizingMask = [.width, .height]
        bg.addSubview(errLabel)

        contentClip.addSubview(bg, positioned: .above, relativeTo: overlay)
        errorLabel = errLabel
    }

    func hideError() {
        errorLabel?.superview?.removeFromSuperview()
        errorLabel = nil
    }

    // MARK: - WKWebView rubber-banding fix

    /// Find and disable the INTERNAL scroll view inside WKWebView (not the outer canvas one).
    private func disableWebViewRubberBanding(_ webView: WKWebView) {
        func findInternalScrollView(in view: NSView) -> NSScrollView? {
            for subview in view.subviews {
                if let scrollView = subview as? NSScrollView {
                    return scrollView
                }
                if let found = findInternalScrollView(in: subview) {
                    return found
                }
            }
            return nil
        }

        // WKWebView may not have its subview hierarchy ready immediately — defer slightly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let internalScroll = findInternalScrollView(in: webView) {
                internalScroll.verticalScrollElasticity = .none
                internalScroll.horizontalScrollElasticity = .none
                // Hide native overlay scrollbars (CSS only hides WebKit-rendered ones)
                internalScroll.hasVerticalScroller = false
                internalScroll.hasHorizontalScroller = false
            }
        }
    }

    // MARK: - Layout

    /// Content bounds within the frame (excludes label area above)
    private var contentBounds: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }

    /// Measure the label text width using the label's font, ignoring lineBreakMode constraints.
    private func measuredLabelWidth() -> CGFloat {
        let str = label.stringValue as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: label.font as Any]
        return ceil(str.size(withAttributes: attrs).width)
    }

    func update(route: RouteFrame) {
        // Track whether the route path actually changed (for webview reload)
        let pathChanged = routePath != route.path
        routePath = route.path
        currentDisplayName = route.displayName

        // If the route's path was mutated under us (e.g. "Pin as route"), the live URL
        // we cached for the previous path is no longer authoritative. Clear it so the
        // label falls back to the new routePath until KVO re-fires after the reload.
        // Also refresh originalURL so divergence checks work against the new path.
        if pathChanged {
            currentLiveURL = nil
            if let newOriginal = AppServices.shared.document.url(for: route) {
                originalURL = newOriginal
            }
            hasNavigatedAway = false
        }

        // Update label text from model (custom name or route path or live URL)
        applyLabelText()
        layoutLabel()

        // Position the container on the canvas — use effectiveHeight for auto-sized frames
        frame = NSRect(
            x: route.x,
            y: route.y,
            width: route.width,
            height: route.effectiveHeight
        )

        // Size contentClip to fill the frame bounds
        contentClip.frame = bounds

        // Resize webview and overlay to match content clip
        let cb = contentClip.bounds
        webView?.frame = cb
        overlay?.frame = cb

        // Update shadow host to match our frame
        updateShadowHost()

        // Apply visual state (selection/activation borders)
        applyVisualState()

        // Refresh cursor rects (resize zone depends on zoom level)
        window?.invalidateCursorRects(for: self)

        // If the route path changed, reload the webview content
        if pathChanged {
            tileLifecycle?.reloadRoute(frameId: routeId)
        }
    }

    /// Lightweight update: only path + label, no layout. Used during drag so position isn't reset.
    func updateContentOnly(route: RouteFrame) {
        let pathChanged = routePath != route.path
        routePath = route.path
        currentDisplayName = route.displayName
        if pathChanged {
            currentLiveURL = nil
        }
        applyLabelText()
        if pathChanged {
            tileLifecycle?.reloadRoute(frameId: routeId)
        }
    }

    // MARK: - Stage 14b — styling apply

    /// Apply a `StylingConfig` to this frame's two-layer hierarchy. Idempotent;
    /// re-running with the same config is cheap (CALayer property writes wrapped
    /// in disabled-actions). Cross-stage §3 — the snapshot styling on the
    /// active canvas drives this; per-frame override is Phase 5 v2.
    ///
    /// The frame chrome (`browser` / `device` / `none`) paints sublayers on the
    /// inner clip's layer ABOVE the WKWebView's content. Both layers share the
    /// rounded-corner masksToBounds, so chrome corners track the styling.corners
    /// value for free.
    func applyStyling(_ config: StylingConfig, backingScale: CGFloat) {
        guard let shadow = shadowHost else { return }
        CanvasStylingRenderer.shared.applyFrameStyle(
            outer: shadow,
            inner: contentClip,
            config: config,
            backingScale: backingScale
        )
        let chromeKind: FrameChromeRenderer.FrameKind
        switch kind {
        case .route:    chromeKind = .route
        case .markdown: chromeKind = .markdown
        case .image:    chromeKind = .image
        }
        FrameChromeRenderer.apply(
            outerHost: contentClip,
            screenshotContainer: contentClip,
            chrome: config.frame,
            frame: FrameChromeRenderer.FrameContext(
                kind: config.frame,
                frameKind: chromeKind,
                routePath: routePath,
                displayName: currentDisplayName
            )
        )
    }

    /// Shadow host sits behind the container. Provides outside border + shadow
    /// (can't have masksToBounds + shadow + outside border on the same layer).
    private func updateShadowHost() {
        guard let parent = superview else { return }

        if shadowHost == nil {
            let h = NSView(frame: frame)
            h.wantsLayer = true
            h.layer?.cornerRadius = 8
            h.layer?.shadowColor = NSColor(white: 0, alpha: 0.4).cgColor
            h.layer?.shadowOffset = CGSize(width: 0, height: -4)
            h.layer?.shadowRadius = 12
            h.layer?.shadowOpacity = 1.0
            h.layer?.masksToBounds = false
            // Solid fill so shadow has something to cast from (dark to match canvas)
            h.layer?.backgroundColor = NSColor(red: 0x19 / 255.0, green: 0x1A / 255.0, blue: 0x1D / 255.0, alpha: 1.0).cgColor
            // Default border (will be updated by applyVisualState)
            h.layer?.borderWidth = 1
            h.layer?.borderColor = Self.borderDefault.cgColor
            parent.addSubview(h, positioned: .below, relativeTo: self)
            shadowHost = h
        }
        // Frame is expanded outward by applyVisualState → updateShadowHostFrame
        shadowHost?.frame = frame
    }

    // MARK: - Navigation delegate wiring

    /// Create and wire a WebViewCoordinator for loading/error state management.
    func wireNavigationDelegate(for wv: WKWebView, path: String) {
        let coordinator = WebViewCoordinator()
        coordinator.onLoadingStarted = { [weak self] in
            self?.showLoading()
        }
        coordinator.onLoadingFinished = { [weak self] in
            self?.hideLoading()
            self?.hideError()
            // Re-trigger height measurement after page finishes loading (Stage 3c)
            self?.triggerHeightMeasurement()
        }
        coordinator.onLoadingFailed = { [weak self] message in
            self?.showError("Failed to load \(path)\n\(message)")
        }
        coordinator.onProcessTerminated = { [weak self, weak wv] in
            self?.showError("Process terminated for \(path)")
            // Attempt to reload after a content process crash
            if let url = wv?.url {
                wv?.load(URLRequest(url: url))
            }
        }
        wv.navigationDelegate = coordinator
        self.navigationDelegate = coordinator
    }
}

// MARK: - NSTextFieldDelegate (URL editing)

extension CanvasFrameContainer: NSTextFieldDelegate {

    /// Handle Escape (cancel) and blur (commit) for the URL editor.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endURLEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // urlFieldDidCommit (action target) ran first on Enter, leaving isURLEditing=false.
        // This catches blur (click outside): commit the current value.
        if isURLEditing {
            endURLEditing(commit: true)
        }
    }
}

// MARK: - SPA navigation message handler

/// Receives pushState/replaceState URL change messages from the injected JS hook.
class NavChangeHandler: NSObject, WKScriptMessageHandler {
    private let onChange: (URL) -> Void

    init(onChange: @escaping (URL) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }
        onChange(url)
    }
}
