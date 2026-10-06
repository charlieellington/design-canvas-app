// Transparent SwiftUI overlay mounted while ShareModeCoordinator.state is
// .entering / .active / .exiting. Hosts the four mode signals: accent border,
// top-left pill, top-right action cluster, bottom-right recipient preview card.
// Cursor switching is done by the canvas-level NSView for now — see the
// Stage 14a §6 spec.

import AppKit
import SwiftUI

struct ShareModeWindow: View {
    @ObservedObject var coordinator: ShareModeCoordinator

    var body: some View {
        ZStack {
            // Accent border — 1pt inset, semi-transparent so the canvas
            // content still reads underneath.
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 0x5E / 255, green: 0x6A / 255, blue: 0xD2 / 255), lineWidth: 1)
                .padding(1)
                .allowsHitTesting(false)

            // Top-left pill
            VStack {
                HStack {
                    ShareModePill(coordinator: coordinator)
                        .padding(.leading, 16)
                        .padding(.top, 16)
                    Spacer()
                }
                Spacer()
            }

            // Top-right action cluster
            VStack {
                HStack {
                    Spacer()
                    ShareModeActionCluster(coordinator: coordinator)
                        .padding(.trailing, 16)
                        .padding(.top, 16)
                }
                Spacer()
            }

            // Bottom-right preview card
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    RecipientPreviewCard(coordinator: coordinator)
                        .padding(.trailing, 16)
                        .padding(.bottom, 16)
                }
            }
        }
        .opacity(coordinator.state == .inactive ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: coordinator.state)
    }
}
