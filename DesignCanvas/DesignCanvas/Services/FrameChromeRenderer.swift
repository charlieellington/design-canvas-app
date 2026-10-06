// Paints `browser` / `device` / `none` chrome over each frame's outer wrapper.
// Geometry comes from preset-specs.md §5 (FINAL — not placeholder). Stage 16a's
// dropdown writes `StylingConfig.frame`; we re-render whatever the active
// config says. Chrome is a CALayer pyramid that lives ABOVE the WKWebView's
// content layer; corners + shadow apply to the chrome's outer bounds, NOT the
// screenshot.
//
// For `browser`: a titlebar with three traffic-light circles and an address
// bar containing the route path / display name. Screenshot inherits bottom
// corners only (top edges square, flush against the titlebar).
// For `device`: iPhone silhouette when aspect ratio ≥ thresholdAspectRatio
// (1.5), otherwise MacBook silhouette with a hinge stripe.
// For `none`: clear all chrome layers, no overlay.

import AppKit
import QuartzCore

@MainActor
final class FrameChromeRenderer {

    /// Address-bar content selector — mirrors preset-specs.md §5
    /// `addressBarContentByFrameKind`.
    struct FrameContext {
        let kind: StylingConfig.FrameChrome  // not used yet; reserved
        let frameKind: FrameKind
        let routePath: String?
        let displayName: String?
    }

    enum FrameKind {
        case route, markdown, image
    }

    /// Render chrome on the outer host view. Idempotent — re-running with the
    /// same config is cheap (CALayer property writes only).
    static func apply(
        outerHost: NSView,
        screenshotContainer: NSView,
        chrome: StylingConfig.FrameChrome,
        frame: FrameContext
    ) {
        guard let outerLayer = outerHost.layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Tear down any prior chrome before deciding what to re-add.
        outerLayer.sublayers?.removeAll { $0.name?.hasPrefix("dc.chrome.") == true }

        switch chrome {
        case .none:
            // No chrome — caller's screenshotContainer already fills outerHost.
            screenshotContainer.frame = outerHost.bounds
        case .browser:
            applyBrowserChrome(outerLayer: outerLayer, hostBounds: outerHost.bounds, frame: frame)
            inset(screenshotContainer, by: NSEdgeInsets(top: BrowserChrome.totalHeaderHeight, left: 0, bottom: 0, right: 0), in: outerHost)
        case .device:
            applyDeviceChrome(outerLayer: outerLayer, hostBounds: outerHost.bounds)
            inset(screenshotContainer, by: DeviceChrome.bezelInsets(for: outerHost.bounds.size), in: outerHost)
        }
    }

    // MARK: - Browser

    private struct BrowserChrome {
        static let titlebarHeight: CGFloat = 28
        static let addressBarHeight: CGFloat = 16
        static let totalHeaderHeight: CGFloat = titlebarHeight   // address bar overlaps inside titlebar
        static let titlebarBackground = "#1f2128"
        static let titlebarBorder = "#2a2d36"
        static let trafficLights: [String] = ["#FF5F57", "#FEBC2E", "#28C841"]
        static let trafficLightSize: CGFloat = 12
        static let trafficLightGap: CGFloat = 8
        static let trafficLightInset: CGFloat = 12
        static let addressBarRadius: CGFloat = 4
        static let addressBarBackground = "#2c2f38"
        static let addressBarMaxWidth: CGFloat = 360
        static let addressBarWidthRatio: CGFloat = 0.6
        static let addressBarTextColor = "#9ba0aa"
    }

    private static func applyBrowserChrome(outerLayer: CALayer, hostBounds: CGRect, frame: FrameContext) {
        let titlebar = CALayer()
        titlebar.name = "dc.chrome.titlebar"
        titlebar.frame = CGRect(x: 0, y: 0, width: hostBounds.width, height: BrowserChrome.titlebarHeight)
        titlebar.backgroundColor = NSColor(hex: BrowserChrome.titlebarBackground)?.cgColor
        titlebar.borderColor = NSColor(hex: BrowserChrome.titlebarBorder)?.cgColor
        titlebar.borderWidth = 1
        outerLayer.addSublayer(titlebar)

        // Traffic lights, left-aligned.
        var x = BrowserChrome.trafficLightInset
        let y = (BrowserChrome.titlebarHeight - BrowserChrome.trafficLightSize) / 2
        for color in BrowserChrome.trafficLights {
            let dot = CALayer()
            dot.name = "dc.chrome.trafficLight"
            dot.frame = CGRect(x: x, y: y, width: BrowserChrome.trafficLightSize, height: BrowserChrome.trafficLightSize)
            dot.cornerRadius = BrowserChrome.trafficLightSize / 2
            dot.backgroundColor = NSColor(hex: color)?.cgColor
            titlebar.addSublayer(dot)
            x += BrowserChrome.trafficLightSize + BrowserChrome.trafficLightGap
        }

        // Address bar — centred horizontally, ratio-bounded width.
        let barWidth = min(BrowserChrome.addressBarMaxWidth, hostBounds.width * BrowserChrome.addressBarWidthRatio)
        let bar = CALayer()
        bar.name = "dc.chrome.addressBar"
        bar.frame = CGRect(
            x: (hostBounds.width - barWidth) / 2,
            y: (BrowserChrome.titlebarHeight - BrowserChrome.addressBarHeight) / 2,
            width: barWidth,
            height: BrowserChrome.addressBarHeight
        )
        bar.cornerRadius = BrowserChrome.addressBarRadius
        bar.backgroundColor = NSColor(hex: BrowserChrome.addressBarBackground)?.cgColor
        titlebar.addSublayer(bar)

        // Address-bar text via CATextLayer.
        let text = addressText(for: frame)
        let label = CATextLayer()
        label.name = "dc.chrome.addressLabel"
        label.string = text
        label.fontSize = 11
        label.font = NSFont(name: "SF Mono", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.foregroundColor = NSColor(hex: BrowserChrome.addressBarTextColor)?.cgColor
        label.alignmentMode = .left
        label.truncationMode = .end
        label.contentsScale = outerLayer.contentsScale
        label.frame = bar.bounds.insetBy(dx: 6, dy: 0)
        bar.addSublayer(label)
    }

    private static func addressText(for frame: FrameContext) -> String {
        switch frame.frameKind {
        case .route:
            return frame.routePath ?? frame.displayName ?? "/"
        case .markdown:
            return "markdown://\(frame.displayName ?? "untitled")"
        case .image:
            return "image://\(frame.displayName ?? "untitled")"
        }
    }

    // MARK: - Device

    private struct DeviceChrome {
        static let thresholdAspectRatio: CGFloat = 1.5
        static let bezelColor = "#0a0a0a"
        static let phoneBezelInset: CGFloat = 12
        static let phoneOuterRadius: CGFloat = 48
        static let phoneNotchWidth: CGFloat = 28
        static let phoneNotchHeight: CGFloat = 8
        static let macBezelInsetH: CGFloat = 24
        static let macBezelInsetV: CGFloat = 24
        static let macOuterRadius: CGFloat = 16
        static let macHingeHeight: CGFloat = 4
        static let macHingeWidthRatio: CGFloat = 0.6
        static let macHingeColor = "#1a1a1a"

        static func bezelInsets(for size: CGSize) -> NSEdgeInsets {
            let aspect = size.height / max(size.width, 1)
            if aspect >= thresholdAspectRatio {
                return NSEdgeInsets(top: phoneBezelInset, left: phoneBezelInset, bottom: phoneBezelInset, right: phoneBezelInset)
            } else {
                return NSEdgeInsets(top: macBezelInsetV, left: macBezelInsetH, bottom: macBezelInsetV, right: macBezelInsetH)
            }
        }
    }

    private static func applyDeviceChrome(outerLayer: CALayer, hostBounds: CGRect) {
        let aspect = hostBounds.height / max(hostBounds.width, 1)
        let bezelColor = NSColor(hex: DeviceChrome.bezelColor)?.cgColor

        let bezel = CALayer()
        bezel.name = "dc.chrome.deviceBezel"
        bezel.frame = hostBounds
        bezel.backgroundColor = bezelColor
        bezel.cornerRadius = aspect >= DeviceChrome.thresholdAspectRatio
            ? DeviceChrome.phoneOuterRadius
            : DeviceChrome.macOuterRadius
        bezel.masksToBounds = true
        outerLayer.insertSublayer(bezel, at: 0)

        if aspect >= DeviceChrome.thresholdAspectRatio {
            // iPhone — notch at top centre.
            let notch = CALayer()
            notch.name = "dc.chrome.iphoneNotch"
            notch.frame = CGRect(
                x: (hostBounds.width - DeviceChrome.phoneNotchWidth) / 2,
                y: 0,
                width: DeviceChrome.phoneNotchWidth,
                height: DeviceChrome.phoneNotchHeight
            )
            notch.backgroundColor = bezelColor
            notch.cornerRadius = DeviceChrome.phoneNotchHeight / 2
            outerLayer.addSublayer(notch)
        } else {
            // MacBook — hinge stripe at bottom centre.
            let hingeWidth = hostBounds.width * DeviceChrome.macHingeWidthRatio
            let hinge = CALayer()
            hinge.name = "dc.chrome.macHinge"
            hinge.frame = CGRect(
                x: (hostBounds.width - hingeWidth) / 2,
                y: hostBounds.height - DeviceChrome.macHingeHeight,
                width: hingeWidth,
                height: DeviceChrome.macHingeHeight
            )
            hinge.backgroundColor = NSColor(hex: DeviceChrome.macHingeColor)?.cgColor
            outerLayer.addSublayer(hinge)
        }
    }

    // MARK: - Inset helper

    private static func inset(_ inner: NSView, by insets: NSEdgeInsets, in outer: NSView) {
        var f = outer.bounds
        f.origin.x += insets.left
        f.origin.y += insets.top
        f.size.width -= (insets.left + insets.right)
        f.size.height -= (insets.top + insets.bottom)
        inner.frame = f
    }
}
