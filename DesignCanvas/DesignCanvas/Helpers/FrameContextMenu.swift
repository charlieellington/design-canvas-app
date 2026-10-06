// Builds the right-click context menu for canvas frames. Replaces WKWebView's built-in
// light-themed menu with a dark, cache-busting version that works in both canvas and interact mode.
// Works for both live WKWebView frames and screenshot-only frames.
// Stage 10: "Remove from Canvas" menu item.

import AppKit
import ObjectiveC

@MainActor
enum FrameContextMenu {

    /// Build a dark context menu for the given frame overlay (live frames).
    /// Note: overlay lives inside contentClip, so walk up two levels to reach the container.
    static func build(for overlay: InteractionOverlay) -> NSMenu {
        guard let container = overlay.superview?.superview as? CanvasFrameContainer else { return NSMenu() }
        return build(for: container)
    }

    /// Build a dark context menu for any frame container (live or screenshot).
    static func build(for container: CanvasFrameContainer) -> NSMenu {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)

        let helper = ContextMenuHelper(container: container, router: container.interactionRouter)

        // Keep the helper alive for the lifetime of the menu
        objc_setAssociatedObject(menu, "contextMenuHelper", helper, .OBJC_ASSOCIATION_RETAIN)

        // Markdown / image frames — short menu (Show in Finder + Remove)
        if container.kind == .markdown || container.kind == .image {
            let showInFinder = NSMenuItem(
                title: "Show in Finder",
                action: #selector(ContextMenuHelper.showInFinder),
                keyEquivalent: ""
            )
            showInFinder.target = helper
            menu.addItem(showInFinder)

            menu.addItem(.separator())

            let remove = NSMenuItem(
                title: "Remove from Canvas",
                action: #selector(ContextMenuHelper.removeNonRouteFrame),
                keyEquivalent: ""
            )
            remove.target = helper
            menu.addItem(remove)
            return menu
        }

        // Removed frames: short menu — Dismiss / Dismiss All only
        if container.wasRemoved {
            let dismiss = NSMenuItem(title: "Dismiss", action: #selector(ContextMenuHelper.dismissRemoved), keyEquivalent: "")
            dismiss.target = helper
            menu.addItem(dismiss)

            let dismissAll = NSMenuItem(title: "Dismiss All Removed", action: #selector(ContextMenuHelper.dismissAllRemoved), keyEquivalent: "")
            dismissAll.target = helper
            menu.addItem(dismissAll)

            return menu
        }

        let isLive = container.webView != nil

        if isLive {
            // Live frame menu: Reload, Copy URL, Open in Browser, Interact Mode
            let reload = NSMenuItem(title: "Reload Page", action: #selector(ContextMenuHelper.reload), keyEquivalent: "r")
            reload.keyEquivalentModifierMask = .command
            reload.target = helper
            menu.addItem(reload)

            menu.addItem(.separator())
        }

        // Copy Page URL — works for both live and screenshot frames
        let copyURL = NSMenuItem(title: "Copy Page URL", action: #selector(ContextMenuHelper.copyURL), keyEquivalent: "")
        copyURL.target = helper
        menu.addItem(copyURL)

        // Open in Browser — works for both live and screenshot frames
        let openBrowser = NSMenuItem(title: "Open in Browser", action: #selector(ContextMenuHelper.openInBrowser), keyEquivalent: "")
        openBrowser.target = helper
        menu.addItem(openBrowser)

        if isLive {
            menu.addItem(.separator())

            let isFocused = container.interactionRouter?.activeFrameId == container.routeId
            let interact = NSMenuItem(
                title: isFocused ? "Exit Interact Mode" : "Enter Interact Mode",
                action: isFocused
                    ? #selector(ContextMenuHelper.exitInteract)
                    : #selector(ContextMenuHelper.enterInteract),
                keyEquivalent: ""
            )
            interact.target = helper
            menu.addItem(interact)

            let fitContent = NSMenuItem(title: "Fit to Content", action: #selector(ContextMenuHelper.fitToContent), keyEquivalent: "")
            fitContent.target = helper
            menu.addItem(fitContent)
        }

        // Stage 5: Screenshot frames get "Make Live" to manually promote to live view
        if !isLive {
            menu.insertItem(.separator(), at: 0)
            let makeLive = NSMenuItem(title: "Make Live", action: #selector(ContextMenuHelper.makeLive), keyEquivalent: "")
            makeLive.target = helper
            menu.insertItem(makeLive, at: 0)
        }

        // Stage 11: Change Route and Duplicate at 375px
        menu.addItem(.separator())
        let changeRoute = NSMenuItem(title: "Change Route…", action: #selector(ContextMenuHelper.changeRoute), keyEquivalent: "")
        changeRoute.target = helper
        menu.addItem(changeRoute)

        let duplicate375 = NSMenuItem(title: "Duplicate at 375px", action: #selector(ContextMenuHelper.duplicateMobile), keyEquivalent: "")
        duplicate375.target = helper
        menu.addItem(duplicate375)

        // Stage 10: Remove from Canvas — destructive action at the bottom
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from Canvas", action: #selector(ContextMenuHelper.removeFromCanvas), keyEquivalent: "")
        remove.target = helper
        menu.addItem(remove)

        return menu
    }
}

// MARK: - Action handler (target for NSMenuItem target-action)

@MainActor
private class ContextMenuHelper: NSObject {

    weak var container: CanvasFrameContainer?
    weak var router: InteractionRouter?

    init(container: CanvasFrameContainer, router: InteractionRouter?) {
        self.container = container
        self.router = router
    }

    @objc func reload() {
        container?.hardRefresh()
    }

    @objc func copyURL() {
        let url = resolveURL()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func openInBrowser() {
        NSWorkspace.shared.open(resolveURL())
    }

    @objc func enterInteract() {
        guard let container else { return }
        router?.activateFrame(container.routeId)
        if let webView = container.webView {
            container.window?.makeFirstResponder(webView)
        }
    }

    @objc func exitInteract() {
        router?.deactivateAll()
    }

    @objc func fitToContent() {
        guard let container else { return }
        let routeId = container.routeId
        let router = self.router
        Task { @MainActor in
            if let h = await container.measureFitToContentHeight() {
                router?.commitResize(routeId: routeId, width: container.frame.width, height: h)
            }
        }
    }

    @objc func makeLive() {
        guard let container else { return }
        container.tileLifecycle?.promoteToLive(frameId: container.routeId)
    }

    @objc func changeRoute() {
        guard let container else { return }
        AppServices.shared.paletteState.openForAssign(frameId: container.routeId)
    }

    @objc func duplicateMobile() {
        guard let container else { return }
        let doc = AppServices.shared.document
        guard let source = doc.routes.first(where: { $0.id == container.routeId }) else { return }
        _ = try? AppServices.shared.canvasManager?.addRoute(
            path: container.routePath,
            x: source.x + source.width + 100,
            y: source.y,
            width: 375,
            height: 812,
            serverId: source.serverBindingId
        )
    }

    @objc func removeFromCanvas() {
        guard let container else { return }
        let _ = AppServices.shared.canvasManager?.removeRoute(id: container.routeId)
    }

    @objc func dismissRemoved() {
        guard let container else { return }
        AppServices.shared.document.dismissRemovedRoute(id: container.routeId)
    }

    @objc func dismissAllRemoved() {
        AppServices.shared.document.dismissAllRemovedRoutes()
    }

    // MARK: - Markdown / image actions (non-route frames)

    @objc func showInFinder() {
        guard let container else { return }
        let path = container.routePath  // For markdown/image, routePath holds the file path.
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func removeNonRouteFrame() {
        guard let container else { return }
        // Route through the generalised handler so undo + kind dispatch are consistent.
        router?.handleRemoveFrame(frameId: container.routeId)
    }

    /// Get the URL from the live webview if available, otherwise construct from the
    /// frame's route (which carries its own binding in C0+).
    private func resolveURL() -> URL {
        if let url = container?.webView?.url { return url }
        let doc = AppServices.shared.document
        if let routeId = container?.routeId,
           let route = doc.routes.first(where: { $0.id == routeId }),
           let url = doc.url(for: route) {
            return url
        }
        let path = container?.routePath ?? "/"
        return doc.url(forPath: path) ?? URL(string: "http://localhost:3000")!
    }
}
