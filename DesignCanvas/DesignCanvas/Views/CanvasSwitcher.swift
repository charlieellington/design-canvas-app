// A1 — canvas dropdown. Opens from the top-left CanvasChip (or ⌘T). Lists every
// canvas, search-filterable, with Working Canvas pinned first. Right-click rename /
// duplicate / delete. "+ New Canvas" creates an empty canvas and switches to it.
//
// Implementation note: switching = snapshot current flat slots into the previous
// canvas, restore target snapshot into the flat slots. Per-canvas camera/undo
// preservation is best-effort in v1 (camera position carried via the snapshot's
// optional camera fields).

import SwiftUI

struct CanvasSwitcher: View {
    @Bindable var document: DocumentModel
    var onSwitchCanvas: (UUID) -> Void
    var onCreateCanvas: () -> Void
    var onRenameCanvas: (Canvas) -> Void
    var onDuplicateCanvas: (Canvas) -> Void
    var onDeleteCanvas: (Canvas) -> Void
    var onDismiss: () -> Void

    @State private var searchText: String = ""
    @State private var hovered: String? = nil
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            divider
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredCanvases) { canvas in
                        canvasRow(canvas)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
            divider
            newCanvasRow
        }
        .frame(width: 320)
        .background(Color(hex: 0x191A1D))
        .onAppear { searchFocused = true }
    }

    private var filteredCanvases: [Canvas] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        // Working Canvas pinned first, then user canvases in creation order.
        let sorted = document.canvases.sorted { l, r in
            if l.isDefault != r.isDefault { return l.isDefault }
            return l.createdAt < r.createdAt
        }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.name.lowercased().contains(q) }
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color(hex: 0x666666))
                .font(.system(size: 12))
            TextField("Search canvases…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0xEEEEEE))
                .focused($searchFocused)
                .onSubmit {
                    if let first = filteredCanvases.first {
                        onDismiss()
                        onSwitchCanvas(first.id)
                    }
                }
            Text("⌘T")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: 0x555555))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func canvasRow(_ canvas: Canvas) -> some View {
        let id = "canvas:\(canvas.id.uuidString)"
        let isActive = canvas.id == document.activeCanvasId
        return Button {
            onDismiss()
            if !isActive { onSwitchCanvas(canvas.id) }
        } label: {
            HStack(spacing: 8) {
                if canvas.isDefault {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(hex: 0xC1A227))
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                Text(canvas.name)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                    .lineLimit(1)
                Spacer()
                if canvas.shareStatus != .notShared {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x888888))
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(hex: 0x888888))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered == id ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
        .contextMenu {
            if !canvas.isDefault {
                Button("Rename") { onRenameCanvas(canvas) }
            } else {
                Button("Rename") { onRenameCanvas(canvas) }.disabled(true)
            }
            Button("Duplicate") { onDuplicateCanvas(canvas) }
            Divider()
            if !canvas.isDefault {
                Button("Delete", role: .destructive) { onDeleteCanvas(canvas) }
            } else {
                Button("Delete", role: .destructive) { onDeleteCanvas(canvas) }.disabled(true)
            }
        }
    }

    @ViewBuilder
    private var newCanvasRow: some View {
        let id = "new"
        Button {
            onDismiss()
            onCreateCanvas()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x888888))
                    .frame(width: 12)
                Text("New Canvas")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0xEEEEEE))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered == id ? Color(hex: 0x2C2D30).opacity(0.7) : Color.clear)
            )
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : nil }
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(hex: 0x2C2D30))
            .frame(height: 1)
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
