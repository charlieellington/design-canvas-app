// Main view — removed. State now lives in DesignCanvasApp for menu command access.
// This file kept for potential future use but ContentView is no longer the entry point.

import SwiftUI

struct ContentView: View {
    let camera: CanvasCamera
    let document: DocumentModel
    let interactionRouter: InteractionRouter
    let interactHintCoordinator: InteractHintCoordinator

    var body: some View {
        CanvasContainerView(
            camera: camera,
            document: document,
            interactionRouter: interactionRouter,
            interactHintCoordinator: interactHintCoordinator,
            isInDemoMode: false
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
