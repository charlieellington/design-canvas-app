// Visual chrome for a CanvasSection — a labelled rectangle rendered behind the
// frames it contains. Subtle border + tinted background + title bar so the section
// reads as "these frames belong together." Lives below CanvasFrameContainer
// instances in CanvasDocumentView's subview z-order so frames render on top.
//
// This is a passive view: no interaction yet. Drag-as-group, resize, and
// inline-rename are deliberately out of scope for the section MVP.

import AppKit

class CanvasSectionView: NSView {

    let sectionId: UUID
    private(set) var title: String
    private let titleLabel: NSTextField
    private let borderLayer: CAShapeLayer

    private static let backgroundColor = NSColor(white: 1, alpha: 0.025).cgColor
    private static let borderColor = NSColor(white: 1, alpha: 0.10).cgColor
    private static let titleTextColor = NSColor(white: 1, alpha: 0.80)
    private static let cornerRadius: CGFloat = 12
    private static let titleHeight: CGFloat = 36
    private static let titleInset: CGFloat = 16

    init(sectionId: UUID, title: String, frame: NSRect) {
        self.sectionId = sectionId
        self.title = title
        self.titleLabel = NSTextField(labelWithString: title)
        self.borderLayer = CAShapeLayer()
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor
        layer?.cornerRadius = Self.cornerRadius

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = Self.borderColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = Self.titleTextColor
        titleLabel.isBordered = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)

        layoutChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Sections are background chrome — they must let mouse events fall through to the
    /// frames in front and to the canvas behind (for marquee selection).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    func updateContent(title newTitle: String, frame newFrame: NSRect) {
        if newTitle != title {
            title = newTitle
            titleLabel.stringValue = newTitle
        }
        if newFrame != self.frame {
            self.frame = newFrame
            layoutChrome()
        }
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    private func layoutChrome() {
        let path = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        borderLayer.path = path
        borderLayer.frame = bounds

        let labelHeight: CGFloat = 22
        titleLabel.frame = NSRect(
            x: Self.titleInset,
            y: (Self.titleHeight - labelHeight) / 2,
            width: max(0, bounds.width - Self.titleInset * 2),
            height: labelHeight
        )
    }
}
