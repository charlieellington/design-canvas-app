// "Add more frames" hint card — appears to the right of the auto-loaded root frame.
// Lives in canvas coordinates (NSView, not SwiftUI) so it pans/zooms with the canvas.
// Disappears once the user adds a second route. Clickable — triggers command palette.
// Design tokens: #191A1D surface, dashed 1px #2C2D30 border, 8px radius.

import AppKit

class HintCard: NSView {

    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }

    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField

    override init(frame frameRect: NSRect) {
        titleLabel = NSTextField(labelWithString: "+ Add more frames")
        subtitleLabel = NSTextField(labelWithString: "⌘K")
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            red: 0x19 / 255.0,
            green: 0x1A / 255.0,
            blue: 0x1D / 255.0,
            alpha: 1.0
        ).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        // Dashed border — the only dashed border in the app
        let borderLayer = CAShapeLayer()
        borderLayer.strokeColor = NSColor(
            red: 0x2C / 255.0,
            green: 0x2D / 255.0,
            blue: 0x30 / 255.0,
            alpha: 1.0
        ).cgColor
        borderLayer.fillColor = nil
        borderLayer.lineDashPattern = [6, 4]
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        // Title: "+ Add more frames"
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        titleLabel.textColor = NSColor(
            red: 0x88 / 255.0,
            green: 0x88 / 255.0,
            blue: 0x88 / 255.0,
            alpha: 1.0
        )
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.alignment = .center
        titleLabel.sizeToFit()
        addSubview(titleLabel)

        // Subtitle: "⌘K"
        subtitleLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = NSColor(
            red: 0x55 / 255.0,
            green: 0x55 / 255.0,
            blue: 0x55 / 255.0,
            alpha: 1.0
        )
        subtitleLabel.backgroundColor = .clear
        subtitleLabel.isBezeled = false
        subtitleLabel.isEditable = false
        subtitleLabel.alignment = .center
        subtitleLabel.sizeToFit()
        addSubview(subtitleLabel)

        // Tracking area for hover cursor
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func layout() {
        super.layout()

        // Update dashed border path to match current bounds
        if let borderLayer = layer?.sublayers?.first(where: { $0 is CAShapeLayer }) as? CAShapeLayer {
            let inset = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - 1)
            borderLayer.path = CGPath(roundedRect: inset, cornerWidth: 8, cornerHeight: 8, transform: nil)
        }

        // Centre labels vertically
        let totalHeight = titleLabel.frame.height + 8 + subtitleLabel.frame.height
        let startY = (bounds.height - totalHeight) / 2

        titleLabel.frame = NSRect(
            x: 0, y: startY,
            width: bounds.width,
            height: titleLabel.frame.height
        )
        subtitleLabel.frame = NSRect(
            x: 0, y: startY + titleLabel.frame.height + 8,
            width: bounds.width,
            height: subtitleLabel.frame.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }
}
