// Observable state for the ⌘K command palette. Tracks search text, selected routes,
// highlight position, and assign mode (Change Route). References RouteDiscovery for
// available routes and DocumentModel for on-canvas routes.

import Foundation
import Observation

@Observable
@MainActor
class CommandPaletteState {

    /// Which body the palette is showing. Assign mode (`targetFrameId`) is orthogonal.
    enum Mode: String {
        case root
        case markdownPicker
        case imagePicker
    }

    var isOpen = false
    var searchText = ""
    var selectedPaths: Set<String> = []
    var highlightedIndex: Int = 0
    var mode: Mode = .root

    /// Two-phase "Add All" confirmation state — true when awaiting user confirm for large batches.
    var confirmingAddAll = false

    /// When set, the palette is in "assign" mode — single-select to swap a frame's route.
    var targetFrameId: UUID?

    var isAssignMode: Bool { targetFrameId != nil }

    // MARK: - Dependencies

    weak var routeDiscovery: RouteDiscovery?
    weak var document: DocumentModel?

    /// Whether to show "Open Demo Project" entry in the palette.
    var showDemoEntry: Bool { !AppServices.shared.demo.isInDemoMode }

    /// Called when user selects "Open Demo Project" from the palette.
    var onOpenDemoProject: (() -> Void)?

    // MARK: - Computed

    /// Discovered routes NOT currently on the canvas.
    var availableRoutes: [DiscoveredRoute] {
        guard let routeDiscovery, let document else { return [] }
        let onCanvas = Set(document.routes.map(\.path))
        return routeDiscovery.lastDiscovered.filter { !onCanvas.contains($0.label) }
    }

    /// Discovered routes already on the canvas.
    var onCanvasRoutes: [DiscoveredRoute] {
        guard let routeDiscovery, let document else { return [] }
        let onCanvas = Set(document.routes.map(\.path))
        return routeDiscovery.lastDiscovered.filter { onCanvas.contains($0.label) }
    }

    /// All discovered routes, filtered by search text, grouped by first path segment.
    var filteredRoutes: [DiscoveredRoute] {
        guard let routeDiscovery else { return [] }
        let all = routeDiscovery.lastDiscovered
        if searchText.isEmpty { return all.sorted { $0.label < $1.label } }
        let query = searchText.lowercased()
        return all.filter { $0.label.lowercased().contains(query) }
            .sorted { $0.label < $1.label }
    }

    /// Whether the search text looks like a custom path the user is typing manually.
    /// Shows whenever there's non-empty input that isn't an exact match of a discovered route.
    var isCustomPath: Bool {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        return !filteredRoutes.contains { $0.label == text || $0.urlPath == text }
    }

    /// The resolved custom path — auto-prepends https:// for bare domains.
    var resolvedCustomPath: String {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("/") || text.hasPrefix("http://") || text.hasPrefix("https://") {
            return text
        }
        return "https://\(text)"
    }

    /// Whether the current custom path looks like an external URL.
    var isExternalURL: Bool {
        let resolved = resolvedCustomPath
        return resolved.hasPrefix("http://") || resolved.hasPrefix("https://")
    }

    /// Group routes by first path segment for display.
    func groupedRoutes() -> [(header: String, routes: [DiscoveredRoute])] {
        let routes = filteredRoutes
        var groups: [String: [DiscoveredRoute]] = [:]

        for route in routes {
            let segments = route.label.split(separator: "/", omittingEmptySubsequences: true)
            let group: String
            if segments.isEmpty {
                group = "ROOT"
            } else if segments.count == 1 {
                group = "ROOT"
            } else {
                group = segments[0].uppercased()
            }
            groups[group, default: []].append(route)
        }

        return groups.sorted { $0.key < $1.key }
            .map { (header: $0.key, routes: $0.value.sorted { $0.label < $1.label }) }
    }

    // MARK: - Actions

    func open() {
        searchText = ""
        selectedPaths = []
        highlightedIndex = 0
        confirmingAddAll = false
        targetFrameId = nil
        mode = .root
        isOpen = true
    }

    func openForAssign(frameId: UUID) {
        searchText = ""
        selectedPaths = []
        highlightedIndex = 0
        confirmingAddAll = false
        targetFrameId = frameId
        mode = .root
        isOpen = true
    }

    func close() {
        isOpen = false
        searchText = ""
        selectedPaths = []
        confirmingAddAll = false
        targetFrameId = nil
        mode = .root
    }

    // MARK: - Mode transitions

    func enterMarkdownPicker() {
        searchText = ""
        mode = .markdownPicker
    }

    func enterImagePicker() {
        searchText = ""
        mode = .imagePicker
    }

    func backToRoot() {
        searchText = ""
        mode = .root
    }

    func toggleRoute(path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else {
            selectedPaths.insert(path)
        }
    }

    /// Add selected routes to the canvas using staggered loading.
    func addSelected() {
        guard let document, let routeDiscovery else { return }
        let selected = routeDiscovery.lastDiscovered.filter { selectedPaths.contains($0.label) }
        if !selected.isEmpty {
            document.mergeDiscoveredRoutes(
                document.routes.map { DiscoveredRoute(label: $0.path, urlPath: $0.urlPath ?? $0.path) }
                + selected
            )
        }
        close()
    }

    /// Gate for "Add All" — confirms with the user for large batches (>8 routes).
    func requestAddAll() {
        if availableRoutes.count > 8 {
            confirmingAddAll = true
        } else {
            addAll()
        }
    }

    /// Add ALL available (non-canvas) routes.
    func addAll() {
        guard let document, let routeDiscovery else { return }
        let all = routeDiscovery.lastDiscovered
        document.mergeDiscoveredRoutes(all)
        close()
    }

    /// Add a custom path typed by the user. Auto-prepends https:// for bare domains.
    func addCustomPath() {
        let path = resolvedCustomPath
        guard !path.isEmpty else { return }
        _ = try? AppServices.shared.canvasManager?.addRoute(
            path: path, x: nil, y: nil, width: 1280, height: 800
        )
        close()
    }

    /// Assign a route to an existing frame (Change Route mode).
    func assignRoute(_ route: DiscoveredRoute) {
        guard let document, let frameId = targetFrameId else { return }
        if let index = document.routes.firstIndex(where: { $0.id == frameId }) {
            document.routes[index].path = route.label
            document.routes[index].urlPath = route.label == route.urlPath ? nil : route.urlPath
        }
        close()
    }

    /// Assign a custom path to an existing frame (Change Route + custom URL).
    func assignCustomPath() {
        let path = resolvedCustomPath
        guard !path.isEmpty else { return }
        assignRoute(DiscoveredRoute(label: path, urlPath: path))
    }
}
