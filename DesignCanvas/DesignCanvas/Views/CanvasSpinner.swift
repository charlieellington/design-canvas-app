// Custom arc spinner matching the dark Linear-inspired design. Replaces stock
// NSProgressIndicator with a 270-degree arc stroke that rotates continuously.
// Used in CanvasFrameContainer for both initial frame and webview loading states.

import AppKit
import QuartzCore

class CanvasSpinner: NSView {

    private let arcLayer = CAShapeLayer()

    // MARK: - Design tokens

    private static let strokeColor = NSColor(
        red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0, alpha: 1.0
    ).cgColor
    private static let strokeWidth: CGFloat = 2.5
    private static let arcFraction: CGFloat = 0.75  // 270 degrees
    private static let duration: CFTimeInterval = 0.9

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupArc()
        startAnimating()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Arc setup

    private func setupArc() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (min(bounds.width, bounds.height) - Self.strokeWidth) / 2
        let startAngle: CGFloat = 0
        let endAngle: CGFloat = .pi * 2 * Self.arcFraction

        let path = CGMutablePath()
        path.addArc(center: center, radius: radius,
                     startAngle: startAngle, endAngle: endAngle, clockwise: false)

        arcLayer.path = path
        arcLayer.strokeColor = Self.strokeColor
        arcLayer.fillColor = nil
        arcLayer.lineWidth = Self.strokeWidth
        arcLayer.lineCap = .round
        arcLayer.frame = bounds

        layer?.addSublayer(arcLayer)
    }

    // MARK: - Animation

    func startAnimating() {
        arcLayer.removeAnimation(forKey: "spin")

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = Self.duration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        spin.isRemovedOnCompletion = false

        arcLayer.add(spin, forKey: "spin")
    }

    func stopAnimating() {
        arcLayer.removeAllAnimations()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        // Re-center arc when frame changes
        arcLayer.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (min(bounds.width, bounds.height) - Self.strokeWidth) / 2
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius,
                     startAngle: 0, endAngle: .pi * 2 * Self.arcFraction, clockwise: false)
        arcLayer.path = path
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Re-start animation if the view was re-parented (animation gets removed)
        if superview != nil {
            startAnimating()
        }
    }
}
