// Sub-pane of the ⌘K palette — drop zone plus "Choose from disk" button for
// adding an image to the canvas. Supported types match the app's existing
// image frame support (FileWatcher.imageExtensions).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CommandPaletteImagePicker: View {
    @Bindable var state: CommandPaletteState

    @State private var isDropTargeted: Bool = false

    // Design tokens — mirrors CommandPalette.swift:12-19
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let textDimmed = Color(nsColor: NSColor(red: 0x55/255, green: 0x55/255, blue: 0x55/255, alpha: 1))
    private let accent = Color(nsColor: NSColor(red: 0x5E/255, green: 0x6A/255, blue: 0xD2/255, alpha: 1))

    private static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "heic"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            dropZone
            divider
            footer
        }
    }

    private var divider: some View {
        Rectangle().fill(border).frame(height: 1)
    }

    // MARK: - Header (back + title)

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                state.backToRoot()
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundColor(textMuted)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help("Back (⎋)")

            Image(systemName: "photo")
                .foregroundColor(textDimmed)
                .font(.system(size: 14))

            Text("Add image")
                .font(.system(size: 14))
                .foregroundColor(textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(isDropTargeted ? accent : textMuted)
            Text("Drop image here")
                .font(.system(size: 13))
                .foregroundColor(isDropTargeted ? textPrimary : textMuted)
            Text("PNG, JPG, GIF, SVG, HEIC")
                .font(.system(size: 11))
                .foregroundColor(textDimmed)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .foregroundColor(isDropTargeted ? accent : border)
                .padding(12)
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Footer (browse button)

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                presentOpenPanel()
            } label: {
                Text("Choose from disk…")
                    .font(.system(size: 13))
                    .foregroundColor(textPrimary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.08))
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Behavior

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
                    return
                }
                _ = AppServices.shared.canvasManager?.addImage(
                    filePath: url.path, x: nil, y: nil, width: nil, height: nil
                )
                state.close()
            }
        }
        return true
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.allowedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK, let url = panel.url {
            _ = AppServices.shared.canvasManager?.addImage(
                filePath: url.path, x: nil, y: nil, width: nil, height: nil
            )
            state.close()
        }
    }
}
