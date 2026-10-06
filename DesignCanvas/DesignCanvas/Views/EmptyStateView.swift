// Empty state overlay — shown when canvas has no routes.
// Centred in viewport as a SwiftUI overlay. Design tokens: #888888 text, #666666 secondary.

import SwiftUI

struct EmptyStateView: View {

    var serverRunning: Bool = false
    var onOpenMCPSetup: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(serverRunning
                 ? "Press ⌘K to add routes"
                 : "Start a dev server to get started")
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundColor(Color(nsColor: NSColor(
                    red: 0x88 / 255.0,
                    green: 0x88 / 255.0,
                    blue: 0x88 / 255.0,
                    alpha: 1.0
                )))

            if !serverRunning {
                Text("or press ⌘K to add a URL manually")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundColor(Color(nsColor: NSColor(
                        red: 0x66 / 255.0,
                        green: 0x66 / 255.0,
                        blue: 0x66 / 255.0,
                        alpha: 1.0
                    )))
            }

            Text("or connect via MCP")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundColor(Color(nsColor: NSColor(
                    red: 0x66 / 255.0,
                    green: 0x66 / 255.0,
                    blue: 0x66 / 255.0,
                    alpha: 1.0
                )))
                .onTapGesture {
                    onOpenMCPSetup?()
                }
                .padding(.top, 4)

            Text("Questions? charlie@ellington.design")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundColor(Color(nsColor: NSColor(
                    red: 0x66 / 255.0,
                    green: 0x66 / 255.0,
                    blue: 0x66 / 255.0,
                    alpha: 1.0
                )))
                .onTapGesture {
                    if let url = URL(string: "mailto:charlie@ellington.design") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .padding(.top, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            AppServices.shared.paletteState.open()
        }
    }
}
