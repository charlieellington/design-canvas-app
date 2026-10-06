// Window-level event monitors for Escape, Spacebar, Delete/Backspace. Uses NSEvent local
// monitors because WKWebView swallows key events through the standard responder chain.
// Stage 10: Delete/Backspace removes focused frame from canvas.

import AppKit

class EventInterceptor {

    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    func install(router: InteractionRouter) {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak router] event in
            guard let router else { return event }

            // Cmd+R — hard refresh the targeted frame (focused or hovered)
            if event.keyCode == 15
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                router.handleRefresh()
                return nil
            }

            // Escape — close palette first, then exit focus mode, then clear selection
            if event.keyCode == 53 {
                let shouldSwallow = MainActor.assumeIsolated {
                    if AppServices.shared.paletteState.isOpen {
                        AppServices.shared.paletteState.close()
                        return true
                    }
                    return false
                }
                if shouldSwallow { return nil }
                router.handleEscape()
                return nil
            }

            // Spacebar down (not repeat) — enter temporary pan mode
            if event.keyCode == 49 && !event.isARepeat {
                router.enterTemporaryPanMode()
                return nil
            }

            // Delete (51) or Forward Delete (117) — remove selected frames only when the
            // user is NOT in focus mode. When a frame is "entered" (activeFrameId set via
            // double-click), the user is typing inside the iframe — Delete must pass
            // through to the page (form inputs, etc.) rather than nuke the frame they're
            // working in. Bug repro: click into a route, press Backspace in a form → the
            // entire route disappears. Fix: only act on selection, never on activeFrameId.
            if (event.keyCode == 51 || event.keyCode == 117)
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                && router.activeFrameId == nil {
                if !router.selectedFrameIds.isEmpty {
                    let ids = router.selectedFrameIds
                    router.deselectAll()
                    for id in ids {
                        router.handleRemoveFrame(frameId: id)
                    }
                    return nil
                }
            }

            return event
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak router] event in
            guard let router else { return event }

            // Spacebar up — exit temporary pan mode
            if event.keyCode == 49 {
                router.exitTemporaryPanMode()
            }

            return event
        }

    }

    func uninstall() {
        if let m = keyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = keyUpMonitor { NSEvent.removeMonitor(m) }
        keyDownMonitor = nil
        keyUpMonitor = nil
    }

    deinit {
        uninstall()
    }
}
