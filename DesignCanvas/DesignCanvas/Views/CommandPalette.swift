// ⌘K command palette — multi-select route picker with search, grouping, manual URL entry,
// and assign mode (Change Route). Linear/Raycast aesthetic. Design tokens from visual-design-references.md.

import SwiftUI

struct CommandPalette: View {
    @Bindable var state: CommandPaletteState

    @FocusState private var isSearchFocused: Bool

    // Design tokens
    private let surface = Color(nsColor: NSColor(red: 0x19/255, green: 0x1A/255, blue: 0x1D/255, alpha: 1))
    private let border = Color(nsColor: NSColor(red: 0x2C/255, green: 0x2D/255, blue: 0x30/255, alpha: 1))
    private let textPrimary = Color(nsColor: NSColor(red: 0xEE/255, green: 0xEE/255, blue: 0xEE/255, alpha: 1))
    private let textMuted = Color(nsColor: NSColor(red: 0x88/255, green: 0x88/255, blue: 0x88/255, alpha: 1))
    private let textDimmed = Color(nsColor: NSColor(red: 0x55/255, green: 0x55/255, blue: 0x55/255, alpha: 1))
    private let textDarker = Color(nsColor: NSColor(red: 0x66/255, green: 0x66/255, blue: 0x66/255, alpha: 1))
    private let textDisabled = Color(nsColor: NSColor(red: 0x44/255, green: 0x44/255, blue: 0x44/255, alpha: 1))
    private let highlightBg = Color.white.opacity(0.06)

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { state.close() }

            // Palette panel
            VStack(spacing: 0) {
                switch state.mode {
                case .root:
                    searchField
                    divider
                    routeList
                    if showsAddSection {
                        divider
                        addSection
                    }
                    divider
                    actionBar
                case .markdownPicker:
                    CommandPaletteMarkdownPicker(state: state)
                case .imagePicker:
                    CommandPaletteImagePicker(state: state)
                }
            }
            .frame(width: 480)
            .frame(maxHeight: 520)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .onAppear { isSearchFocused = true }
        .onChange(of: state.mode) { _, newMode in
            if newMode == .root { isSearchFocused = true }
        }
    }

    // MARK: - Helpers

    /// Estimate first-load time: ~6s per route, rounded to nearest 5s.
    private func loadTimeEstimate(count: Int) -> String {
        let totalSeconds = count * 6
        let rounded = ((totalSeconds + 2) / 5) * 5 // round to nearest 5
        if rounded >= 90 {
            let mins = Double(rounded) / 60.0
            let formatted = String(format: "%.1f", mins)
                .replacingOccurrences(of: ".0", with: "")
            return "~\(formatted) min first load"
        }
        return "~\(rounded)s first load"
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(textDimmed)
                .font(.system(size: 14))

            ZStack(alignment: .leading) {
                if state.searchText.isEmpty {
                    Text(state.isAssignMode ? "Change route…" : "Search routes or paste URL…")
                        .font(.system(size: 14))
                        .foregroundColor(textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(textPrimary)
                    .focused($isSearchFocused)
            }

            Text("⌘K")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(textDimmed)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Rectangle().fill(border).frame(height: 1)
    }

    // MARK: - Route list

    private var routeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Resolved custom URL — shown when typing a non-matching path
                if state.isCustomPath {
                    customPathRow
                }

                // No server message
                if noServerDetected && state.searchText.isEmpty {
                    noServerRow
                }

                // Empty search results (only when no custom path either)
                if !state.isCustomPath && state.filteredRoutes.isEmpty && !state.searchText.isEmpty {
                    emptyResultsRow
                }

                // Grouped route rows
                let groups = state.groupedRoutes()
                ForEach(Array(groups.enumerated()), id: \.element.header) { _, group in
                    sectionHeader(group.header)
                    ForEach(group.routes, id: \.label) { route in
                        routeRow(route)
                    }
                }

                // Other section — demo project entry
                if state.showDemoEntry && (state.searchText.isEmpty || "open demo project".contains(state.searchText.lowercased())) {
                    sectionHeader("OTHER")
                    Button {
                        state.onOpenDemoProject?()
                        state.close()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "play.rectangle")
                                .foregroundColor(textMuted)
                                .font(.system(size: 12))
                                .frame(width: 14)
                            Text("Open Demo Project")
                                .font(.system(size: 13))
                                .foregroundColor(textMuted)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 280)
    }

    private var noServerDetected: Bool {
        AppServices.shared.devServer.status != .running
            && (state.routeDiscovery?.lastDiscovered.isEmpty ?? true)
    }

    private var noServerRow: some View {
        Text("No dev server found — start one or enter a URL manually")
            .font(.system(size: 12))
            .foregroundColor(textDimmed)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private var emptyResultsRow: some View {
        Text("No matching routes")
            .font(.system(size: 12))
            .foregroundColor(textDimmed)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    // MARK: - ADD section (pinned below the scrolling route list)

    /// Hide the ADD section while the user is searching (search is the primary path)
    /// or assigning a route (add actions are unavailable in that mode).
    private var showsAddSection: Bool {
        state.searchText.isEmpty && !state.isAssignMode
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("ADD")
            addRow(icon: "doc.text", title: "Add markdown file…", hasChevron: true) {
                state.enterMarkdownPicker()
            }
            addRow(icon: "photo", title: "Add image…", hasChevron: true) {
                state.enterImagePicker()
            }
            addRow(icon: "globe", title: "Add custom URL…", hasChevron: false) {
                state.searchText = "https://"
            }
        }
        .padding(.vertical, 4)
    }

    /// Generic row used by the ADD section — icon + label + optional chevron.
    private func addRow(icon: String, title: String, hasChevron: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(textMuted)
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(textMuted)
                Spacer()
                if hasChevron {
                    Image(systemName: "chevron.right")
                        .foregroundColor(textDimmed)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var customPathRow: some View {
        let resolved = state.resolvedCustomPath
        let isExternal = state.isExternalURL
        return Button {
            if state.isAssignMode {
                state.assignCustomPath()
            } else {
                state.addCustomPath()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExternal ? "globe" : "plus")
                    .foregroundColor(textMuted)
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text("Open \"\(resolved)\"")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(highlightBg)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(textDarker)
            .textCase(.uppercase)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Route row

    private func routeRow(_ route: DiscoveredRoute) -> some View {
        let isOnCanvas = state.document?.routes.contains(where: { $0.path == route.label }) ?? false
        let isSelected = state.selectedPaths.contains(route.label)

        return Button {
            if state.isAssignMode {
                guard !isOnCanvas else { return }
                state.assignRoute(route)
            } else if isOnCanvas {
                // Can't toggle on-canvas routes
            } else {
                state.toggleRoute(path: route.label)
            }
        } label: {
            HStack(spacing: 8) {
                if !state.isAssignMode {
                    // Checkbox
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(isOnCanvas ? textDisabled : border, lineWidth: 1)
                            .frame(width: 14, height: 14)
                        if isSelected {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(textPrimary)
                                .frame(width: 14, height: 14)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(surface)
                        }
                    }
                }

                Text(route.label)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(isOnCanvas ? textDimmed : textPrimary)
                    .lineLimit(1)

                Spacer()

                if isOnCanvas {
                    Text("on canvas")
                        .font(.system(size: 11))
                        .foregroundColor(textDisabled)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isOnCanvas && !state.isAssignMode)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack {
            if !state.isAssignMode {
                Button {
                    state.addSelected()
                } label: {
                    Text("Add Selected (\(state.selectedPaths.count))")
                        .font(.system(size: 13))
                        .foregroundColor(state.selectedPaths.isEmpty ? textDimmed : textPrimary)
                }
                .buttonStyle(.plain)
                .disabled(state.selectedPaths.isEmpty)

                Spacer()

                // Time estimate for large batches (4+ routes)
                if state.selectedPaths.count >= 4 {
                    Text(loadTimeEstimate(count: state.selectedPaths.count))
                        .font(.system(size: 11))
                        .foregroundColor(textDimmed)
                }

                if state.selectedPaths.count >= 4 {
                    Spacer()
                }

                addAllButton
                    .animation(.easeInOut(duration: 0.15), value: state.confirmingAddAll)
            } else {
                Text("Click a route to assign")
                    .font(.system(size: 13))
                    .foregroundColor(textMuted)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: state.searchText) { _, _ in
            state.confirmingAddAll = false
        }
    }

    // MARK: - Add All (two-phase for large batches)

    @State private var confirmRevertTask: Task<Void, Never>?

    @ViewBuilder
    private var addAllButton: some View {
        let count = state.availableRoutes.count

        if state.confirmingAddAll {
            Button {
                confirmRevertTask?.cancel()
                state.addAll()
            } label: {
                Text("Add \(count) routes · \(loadTimeEstimate(count: count))? ↵")
                    .font(.system(size: 13))
                    .foregroundColor(textPrimary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.08))
            )
            .transition(.opacity)
            .onAppear {
                confirmRevertTask?.cancel()
                confirmRevertTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    state.confirmingAddAll = false
                }
            }
            .onDisappear {
                confirmRevertTask?.cancel()
            }
        } else {
            Button {
                state.requestAddAll()
            } label: {
                let label = count > 8 ? "Add All (\(count))" : "Add All"
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(count == 0 ? textDimmed : textMuted)
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
            .transition(.opacity)
        }
    }
}
