// Sub-pane of the ⌘K palette — searchable flat list of markdown files under
// the watched project root. Click a row (or press Enter with a single match) to
// drop the file onto the canvas.

import SwiftUI

struct CommandPaletteMarkdownPicker: View {
    @Bindable var state: CommandPaletteState
    @FocusState private var isSearchFocused: Bool

    // Design tokens — mirrors CommandPalette.swift:12-19
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let textDimmed = Color(nsColor: NSColor(red: 0x55/255, green: 0x55/255, blue: 0x55/255, alpha: 1))
    private let textDarker = Color(nsColor: NSColor(red: 0x66/255, green: 0x66/255, blue: 0x66/255, alpha: 1))

    private var index: WorkspaceFileIndex { AppServices.shared.workspaceFileIndex }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            divider
            content
        }
        .onAppear { isSearchFocused = true }
        .task { await refreshIfNeeded() }
    }

    // MARK: - Search row

    private var searchRow: some View {
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

            Image(systemName: "magnifyingglass")
                .foregroundColor(textDimmed)
                .font(.system(size: 14))

            ZStack(alignment: .leading) {
                if state.searchText.isEmpty {
                    Text("Search markdown files…")
                        .font(.system(size: 14))
                        .foregroundColor(textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(textPrimary)
                    .focused($isSearchFocused)
                    .onSubmit {
                        if state.searchText.isEmpty {
                            state.backToRoot()
                        } else if let first = filteredFiles.first {
                            pick(first)
                        }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(border).frame(height: 1)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if index.isIndexing && index.markdownFiles.isEmpty {
            loadingRow
        } else if filteredFiles.isEmpty {
            emptyRow
        } else {
            fileList
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning project for markdown files…")
                .font(.system(size: 12))
                .foregroundColor(textDimmed)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
    }

    private var emptyRow: some View {
        let message = index.markdownFiles.isEmpty
            ? "No markdown files found in this project"
            : "No matching files"
        return Text(message)
            .font(.system(size: 12))
            .foregroundColor(textDimmed)
            .frame(maxWidth: .infinity)
            .frame(height: 200)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredFiles, id: \.absolutePath) { file in
                    fileRow(file)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 320)
    }

    private func fileRow(_ file: WorkspaceFileIndex.IndexedFile) -> some View {
        Button {
            pick(file)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundColor(textMuted)
                    .font(.system(size: 12))
                    .frame(width: 14)
                HStack(spacing: 0) {
                    Text(file.parentPathDisplay)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(textDarker)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text(file.filename)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Behavior

    private var filteredFiles: [WorkspaceFileIndex.IndexedFile] {
        let q = state.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return index.markdownFiles }
        return index.markdownFiles.filter { file in
            file.relativePath.lowercased().contains(q)
        }
    }

    private func pick(_ file: WorkspaceFileIndex.IndexedFile) {
        _ = AppServices.shared.canvasManager?.addDocument(
            filePath: file.absolutePath,
            x: nil, y: nil, width: nil, height: nil
        )
        state.close()
    }

    private func refreshIfNeeded() async {
        guard let dir = AppServices.shared.devServer.projectDir else { return }
        if index.lastIndexedDir == dir && !index.markdownFiles.isEmpty { return }
        await index.refresh(projectDir: dir)
    }
}
