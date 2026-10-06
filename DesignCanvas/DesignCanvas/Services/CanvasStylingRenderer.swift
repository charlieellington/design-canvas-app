// Core Animation styling renderer. Owns the canvas background layer + per-frame
// style hooks; called whenever DocumentModel.styling changes. Updates are
// imperative CALayer property writes wrapped in CATransaction.setDisableActions
// so slider drags don't fight implicit animations.
//
// Two-layer shadow+corner architecture: shadow requires masksToBounds = false,
// corners require masksToBounds = true. CanvasFrameContainer's `shadowHost`
// (outer) carries the shadow; the inner `contentClip` carries the corners.
// Both layers come from existing Stage-5 code; this renderer just configures
// them.
//
// Y-axis convention (see Stage 14a rendering-semantics + Stage 14b spec):
//   0° = light from BOTTOM → shadow ABOVE
//   90° = LEFT → shadow RIGHT
//   180° = TOP → shadow BELOW
//   270° = RIGHT → shadow LEFT
// Web CSS: x = distance * sin(rad); y = -distance * cos(rad).
// CALayer Y is bottom-up so the Mac shadowOffset.height is the INVERTED web Y.

import AppKit
import QuartzCore

@MainActor
final class CanvasStylingRenderer {

    static let shared = CanvasStylingRenderer()

    /// The scroll-content layer ("canvas matte" — the 50000×50000 NSView's layer
    /// behind every frame). Set once at canvas-view setup.
    weak var canvasBackgroundView: NSView?

    private var bgGradientLayer: CAGradientLayer?
    private var bgSolidLayer: CALayer?
    private var bgImageLayer: CALayer?

    private init() {}

    // MARK: - Entry points

    /// Apply the styling config to the entire canvas (background only).
    /// Per-frame chrome (corners / shadow / padding) is applied by
    /// `applyFrameStyle` on each `CanvasFrameContainer`.
    func applyBackground(_ config: StylingConfig) {
        guard let host = canvasBackgroundView else { return }
        host.wantsLayer = true
        guard let hostLayer = host.layer else { return }

        ensureBackgroundLayers(on: hostLayer)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch config.background {
        case .color(let c):
            bgSolidLayer?.isHidden = false
            bgGradientLayer?.isHidden = true
            bgImageLayer?.isHidden = true
            bgSolidLayer?.backgroundColor = NSColor(hex: c.color)?.cgColor
        case .gradient(let g):
            bgSolidLayer?.isHidden = true
            bgGradientLayer?.isHidden = false
            bgImageLayer?.isHidden = true
            applyGradient(g, on: bgGradientLayer)
        case .wallpaper(let w):
            bgSolidLayer?.isHidden = true
            bgGradientLayer?.isHidden = true
            bgImageLayer?.isHidden = false
            applyWallpaper(slug: w.wallpaperName, on: bgImageLayer)
        case .image(let i):
            bgSolidLayer?.isHidden = true
            bgGradientLayer?.isHidden = true
            bgImageLayer?.isHidden = false
            applyImage(url: i.imageUrl, on: bgImageLayer)
        }
    }

    /// Apply per-frame chrome (corners + shadow + padding tint) to a frame
    /// container. The frame's WKWebView / screenshot stays in `inner`; the
    /// shadow lives on `outer`.
    func applyFrameStyle(
        outer: NSView,
        inner: NSView,
        config: StylingConfig,
        backingScale: CGFloat
    ) {
        outer.wantsLayer = true
        inner.wantsLayer = true
        guard let outerLayer = outer.layer, let innerLayer = inner.layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // contentsScale — re-applied here so window-drag between displays stays crisp.
        outerLayer.contentsScale = backingScale
        innerLayer.contentsScale = backingScale

        // Corners on the inner clip layer.
        innerLayer.cornerRadius = CGFloat(config.corners)
        innerLayer.masksToBounds = true

        // Shadow on the outer host. Explicit shadowPath for perf.
        outerLayer.masksToBounds = false
        updateShadow(layer: outerLayer, config: config)
        outerLayer.shadowPath = CGPath(
            roundedRect: outer.bounds,
            cornerWidth: CGFloat(config.corners),
            cornerHeight: CGFloat(config.corners),
            transform: nil
        )

        // Padding is a tinted layer between outer-shadow and inner-clip. We
        // represent it as a layer-only effect: inner is inset, and the outer's
        // background color carries the padding tint at the requested opacity.
        if config.padding.size > 0 {
            outerLayer.backgroundColor = NSColor(hex: config.padding.color)?
                .withAlphaComponent(CGFloat(config.padding.opacity))
                .cgColor
        } else {
            outerLayer.backgroundColor = .clear
        }
    }

    // MARK: - Shadow math (CSS angle convention → CALayer)

    /// Single source of truth for shadow math. CSS blur → CA radius is `/ 2`
    /// (industry standard Gaussian approximation). Web alpha is `0.6 * intensity`;
    /// mirror it exactly.
    func updateShadow(layer: CALayer, config: StylingConfig) {
        guard config.shadow.enabled else {
            layer.shadowOpacity = 0
            return
        }
        layer.shadowOpacity = Float(config.shadow.intensity * 0.6)
        layer.shadowRadius = CGFloat(config.shadow.blur / 2.0)
        layer.shadowColor = NSColor.black.cgColor
        if config.shadow.directional {
            let rad = config.shadow.angle * .pi / 180.0
            let webX = config.shadow.distance * sin(rad)
            let webY = -config.shadow.distance * cos(rad)
            // Mac CALayer Y is bottom-up; flip the web Y component.
            layer.shadowOffset = CGSize(width: CGFloat(webX), height: CGFloat(-webY))
        } else {
            layer.shadowOffset = .zero
        }
    }

    // MARK: - Background layer pool

    private func ensureBackgroundLayers(on host: CALayer) {
        if bgSolidLayer == nil {
            let l = CALayer()
            l.zPosition = -100
            host.insertSublayer(l, at: 0)
            bgSolidLayer = l
        }
        if bgGradientLayer == nil {
            let l = CAGradientLayer()
            l.zPosition = -100
            host.insertSublayer(l, at: 0)
            bgGradientLayer = l
        }
        if bgImageLayer == nil {
            let l = CALayer()
            l.zPosition = -100
            l.contentsGravity = .resizeAspectFill
            host.insertSublayer(l, at: 0)
            bgImageLayer = l
        }
        let bounds = host.bounds
        bgSolidLayer?.frame = bounds
        bgGradientLayer?.frame = bounds
        bgImageLayer?.frame = bounds
    }

    private func applyGradient(_ g: StylingConfig.GradientBackground, on layer: CAGradientLayer?) {
        guard let layer = layer else { return }
        let from = NSColor(hex: g.gradientFrom) ?? .black
        let to = NSColor(hex: g.gradientTo) ?? .darkGray
        layer.colors = [from.cgColor, to.cgColor]
        // CSS gradientAngle: 0° = top (origin to top), 90° = right, 180° = bottom, 270° = left.
        // Convert to CAGradientLayer's unit-rect startPoint/endPoint.
        let rad = (g.gradientAngle - 90) * .pi / 180.0   // rotate 0° = top → 0° = right
        let dx = cos(rad)
        let dy = sin(rad)
        // CAGradientLayer Y is top-down here (it pre-flips internally on macOS); use
        // unit-vector centered on (0.5, 0.5) extending to the rect edges.
        layer.startPoint = CGPoint(x: 0.5 - dx * 0.5, y: 0.5 - dy * 0.5)
        layer.endPoint = CGPoint(x: 0.5 + dx * 0.5, y: 0.5 + dy * 0.5)
    }

    private func applyWallpaper(slug: String, on layer: CALayer?) {
        guard let layer = layer else { return }
        // Wallpapers are bundled assets keyed by slug → `wallpaper-<slug>.jpg`.
        // Stage 14e ships these. Until then, fall back to the canonical dark gradient.
        if let image = NSImage(named: slug) {
            layer.contents = image
        } else {
            // Per cross-stage rule: wallpaper-missing fallback renders the `dark`
            // preset's gradient. We bake the fallback into the background path
            // by clearing this layer; the higher-level renderer should re-route
            // to gradient when the asset is missing. For now, leave dark.
            layer.contents = nil
            layer.backgroundColor = NSColor(hex: "#0f1117")?.cgColor
        }
    }

    private func applyImage(url: String, on layer: CALayer?) {
        guard let layer = layer else { return }
        layer.contents = nil
        guard let parsed = URL(string: url) else { return }
        // Async fetch — best-effort; failure leaves the layer empty.
        Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: parsed),
                  let img = NSImage(data: data) else { return }
            await MainActor.run {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.contents = img
                CATransaction.commit()
            }
        }
    }

    // MARK: - Re-layout on host resize

    /// Called from CanvasContainerView when the document view's bounds change
    /// so the background layers stay glued to the canvas matte.
    func resizeBackgroundLayers() {
        guard let host = canvasBackgroundView, let hostLayer = host.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = hostLayer.bounds
        bgSolidLayer?.frame = bounds
        bgGradientLayer?.frame = bounds
        bgImageLayer?.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - NSColor(hex:)

extension NSColor {

    /// Parse `#RRGGBB` or `#RRGGBBAA`. Returns nil on malformed input.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255.0
            g = CGFloat((v >> 16) & 0xFF) / 255.0
            b = CGFloat((v >> 8) & 0xFF) / 255.0
            a = CGFloat(v & 0xFF) / 255.0
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255.0
            g = CGFloat((v >> 8) & 0xFF) / 255.0
            b = CGFloat(v & 0xFF) / 255.0
            a = 1.0
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
