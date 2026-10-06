// Local HTTP API on localhost:7420. External tools (MCP server, curl, scripts) use this
// to control the canvas. Bound to 127.0.0.1 only — not accessible from the network.
// All endpoints require Bearer token auth. Token stored in BuildPolicy.tokenDirectoryName/api_token.

import Foundation
import Swifter

class HTTPAPIServer {

    private let server = HttpServer()
    private weak var canvasManager: CanvasManager?
    private weak var mcpState: MCPConnectionState?
    private weak var mcpActivity: MCPActivityDetector?
    private static let port = BuildPolicy.apiPort

    /// Auth token required on all endpoints. Persisted across launches so MCP servers
    /// don't lose sync when the app restarts.
    private let authToken: String

    /// Allowed Host header values to prevent DNS rebinding attacks.
    private static let allowedHosts: Set<String> = [
        "localhost:\(port)",
        "127.0.0.1:\(port)",
        "[::1]:\(port)",
        "localhost",
        "127.0.0.1",
    ]

    init(
        canvasManager: CanvasManager,
        mcpState: MCPConnectionState? = nil,
        mcpActivity: MCPActivityDetector? = nil
    ) {
        self.canvasManager = canvasManager
        self.mcpState = mcpState
        self.mcpActivity = mcpActivity
        self.authToken = Self.loadOrCreateToken()
        setupRoutes()
    }

    // MARK: - Auth token management

    private static let tokenDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(BuildPolicy.tokenDirectoryName)
    private static let tokenFile = tokenDir.appendingPathComponent("api_token")

    /// Load existing token or generate a new one on first launch.
    private static func loadOrCreateToken() -> String {
        // Try to read existing token
        if let existing = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        // Generate a new cryptographically random token
        let token = UUID().uuidString + "-" + UUID().uuidString

        // Create directory with 0700 permissions (owner only)
        try? FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])

        // Write token with 0600 permissions (owner read/write only)
        try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)

        FileLogger.shared.log("Generated new API auth token", tag: "HTTPAPIServer")
        return token
    }

    // MARK: - Request validation

    /// Validate Host header to prevent DNS rebinding attacks.
    private func isValidHost(_ request: HttpRequest) -> Bool {
        guard let host = request.headers["host"] else { return true } // curl may not send Host
        return Self.allowedHosts.contains(host)
    }

    /// Validate Bearer token from Authorization header.
    private func isAuthorized(_ request: HttpRequest) -> Bool {
        guard let auth = request.headers["authorization"] else { return false }
        let expected = "Bearer \(authToken)"
        // Constant-time comparison to prevent timing attacks
        guard auth.count == expected.count else { return false }
        return auth.utf8.elementsEqual(expected.utf8)
    }

    /// Check both Host and Auth. Returns an error response if invalid, nil if OK.
    private func validateRequest(_ request: HttpRequest) -> HttpResponse? {
        if !isValidHost(request) {
            return errorResponse(403, "Forbidden: invalid Host header")
        }
        if !isAuthorized(request) {
            return errorResponse(401, "Unauthorized: missing or invalid Bearer token")
        }
        return nil
    }

    // MARK: - Start / Stop

    func start() {
        do {
            // Bind to localhost only — not accessible from the network
            server.listenAddressIPv4 = "127.0.0.1"
            try server.start(Self.port, forceIPv4: true)
            FileLogger.shared.log("Running on http://127.0.0.1:\(Self.port)", tag: "HTTPAPIServer")
            FileLogger.shared.log("Auth token file: \(Self.tokenFile.path)", tag: "HTTPAPIServer")
        } catch {
            FileLogger.shared.log("Failed to start: \(error.localizedDescription)", tag: "HTTPAPIServer", level: .error)
            FileLogger.shared.log("Is another instance already running on port \(Self.port)?", tag: "HTTPAPIServer", level: .warn)
        }
    }

    func stop() {
        server.stop()
        FileLogger.shared.log("Stopped", tag: "HTTPAPIServer")
    }

    // MARK: - Routes

    private func setupRoutes() {
        // GET /routes
        server["/routes"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "list_routes"])
            return self?.handleGetRoutes() ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // POST /routes
        server.POST["/routes"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "add_route"])
            return self?.handlePostRoutes(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // DELETE /routes
        server.DELETE["/routes"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "remove_route"])
            return self?.handleDeleteRoutes(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // PATCH /routes — mutate an existing route's path (used by "Pin as route" + MCP update_route)
        server.PATCH["/routes"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "update_route"])
            return self?.handlePatchRoutes(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // GET /servers — list of dev-server bindings on the active canvas. Used by the
        // MCP `list_servers` tool to let agents disambiguate add_route in multi-server
        // canvases without going through the 409 path.
        server["/servers"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "list_servers"])
            return self?.handleGetServers() ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // POST /capture
        server.POST["/capture"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "capture_canvas"])
            return self?.handleCapture(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // GET /documents
        server["/documents"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "list_documents"])
            return self?.handleGetDocuments() ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // POST /documents
        server.POST["/documents"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "add_document"])
            return self?.handlePostDocuments(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // DELETE /documents
        server.DELETE["/documents"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "remove_document"])
            return self?.handleDeleteDocuments(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // GET /images
        server["/images"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "list_images"])
            return self?.handleGetImages() ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // POST /images
        server.POST["/images"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "add_image"])
            return self?.handlePostImages(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // DELETE /images
        server.DELETE["/images"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "remove_image"])
            return self?.handleDeleteImages(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // POST /frames/batch — atomic add of mixed routes/documents/images, laid out as one unit
        server.POST["/frames/batch"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "add_frames"])
            return self?.handlePostFramesBatch(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // GET /sections
        server["/sections"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "list_sections"])
            return self?.handleGetSections() ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // POST /sections — wrap a batch of frames in a labelled rectangle group
        server.POST["/sections"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "add_section"])
            return self?.handlePostSections(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }

        // DELETE /sections?id= — remove section AND all contained frames
        server.DELETE["/sections"] = { [weak self] request in
            if let err = self?.validateRequest(request) { return err }
            AnalyticsService.shared.capture(.mcpCommandReceived, properties: ["tool_name": "remove_section"])
            return self?.handleDeleteSections(request) ?? self?.errorResponse(500, "Server error") ?? .accepted
        }
    }

    // MARK: - GET /servers

    private func handleGetServers() -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "GET", message: "/servers")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [[String: Any]] = []
        DispatchQueue.main.async {
            result = self.canvasManager?.serverData ?? []
            semaphore.signal()
        }
        let waitResult = semaphore.wait(timeout: .now() + 5)
        if waitResult == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        return jsonResponse(["servers": result])
    }

    // MARK: - GET /routes

    private func handleGetRoutes() -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "GET", message: "/routes")
        DispatchQueue.main.async {
            self.mcpState?.recordAPIRequest()
            self.mcpActivity?.noteListRoutes()
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [[String: Any]] = []

        DispatchQueue.main.async {
            result = self.canvasManager?.routeData ?? []
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 10)
        if waitResult == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        return jsonResponse(result)
    }

    // MARK: - POST /routes

    private func handlePostRoutes(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "POST", message: "/routes")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let path = json["path"] as? String else {
            return errorResponse(400, "Missing 'path' in request body")
        }

        let x = (json["x"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let y = (json["y"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let width = (json["width"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let height = (json["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let port = (json["port"] as? NSNumber)?.intValue
        let serverIdRaw = json["serverId"] as? String
        let serverId = serverIdRaw.flatMap { UUID(uuidString: $0) }
        if let raw = serverIdRaw, serverId == nil {
            return errorResponse(400, "Invalid 'serverId' — expected a UUID string (got: \(raw))")
        }
        let placement = Self.parsePlacement(json["placement"])

        enum Outcome {
            case ok(UUID?)
            case ambiguous([CanvasManager.ServerDisambiguationError])
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .ok(nil)

        DispatchQueue.main.async {
            do {
                let id = try self.canvasManager?.addRoute(
                    path: path, x: x, y: y, width: width, height: height,
                    port: port, serverId: serverId, placement: placement
                )
                outcome = .ok(id)
            } catch let err as CanvasManager.ServerDisambiguationError {
                outcome = .ambiguous([err])
            } catch {
                outcome = .ok(nil)
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + 10)
        if waitResult == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .ok(let id):
            let response: [String: Any] = ["ok": true, "path": path, "id": id?.uuidString ?? ""]
            return jsonResponse(response)
        case .ambiguous(let errs):
            let avail = errs.first?.availableServers ?? []
            let list: [[String: Any]] = avail.map { entry in
                var dict: [String: Any] = [
                    "serverId": entry.id.uuidString,
                    "projectName": entry.projectName,
                ]
                if let p = entry.port { dict["port"] = p }
                if let d = entry.projectDir { dict["projectDir"] = d }
                return dict
            }
            let body: [String: Any] = [
                "error": "server_required",
                "message": "Canvas has multiple servers. Pass 'port' or 'serverId' to disambiguate.",
                "availableServers": list,
            ]
            return jsonResponse(body, code: 409, message: "Conflict")
        }
    }

    // MARK: - DELETE /routes?id=<uuid> or DELETE /routes?path=/some-route

    private func handleDeleteRoutes(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "DELETE", message: "/routes")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let rawId = request.queryParams.first(where: { $0.0 == "id" })?.1
        let idParam = (rawId?.isEmpty == false) ? rawId : nil
        let pathParam = request.queryParams.first(where: { $0.0 == "path" })?.1

        guard idParam != nil || pathParam != nil else {
            return errorResponse(400, "Missing 'id' or 'path' query parameter")
        }

        enum Outcome { case removed, notFound, invalid, ambiguous(Int) }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .notFound

        DispatchQueue.main.async {
            guard let cm = self.canvasManager else { semaphore.signal(); return }
            if let idString = idParam {
                switch Self.resolveUUID(idString, in: cm.document.routes.map(\.id)) {
                case .matched(let uuid):
                    outcome = cm.removeRoute(id: uuid) ? .removed : .notFound
                case .invalid:
                    outcome = .invalid
                case .ambiguous(let n):
                    outcome = .ambiguous(n)
                }
            } else if let path = pathParam {
                let decodedPath = path.removingPercentEncoding ?? path
                outcome = (cm.removeRoute(path: decodedPath)) ? .removed : .notFound
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .removed: return jsonResponse(["ok": true])
        case .notFound:
            let target = idParam ?? pathParam ?? "unknown"
            return errorResponse(404, "Route not found: \(target)")
        case .invalid:
            return errorResponse(400, "Invalid 'id' '\(idParam ?? "")' — expected a full UUID or unambiguous UUID prefix from list_routes")
        case .ambiguous(let n):
            return errorResponse(400, "Ambiguous 'id' prefix '\(idParam ?? "")' matches \(n) routes — provide more characters")
        }
    }

    // MARK: - PATCH /routes — body: { "id": "<uuid|prefix>", "path": "/new" }

    private func handlePatchRoutes(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "PATCH", message: "/routes")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let idString = json["id"] as? String, !idString.isEmpty,
              let newPath = json["path"] as? String, !newPath.isEmpty else {
            return errorResponse(400, "Missing 'id' or 'path' in request body")
        }
        guard newPath.hasPrefix("/") else {
            return errorResponse(400, "'path' must start with '/'")
        }

        enum Outcome { case updated, notFound, invalid, ambiguous(Int) }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .notFound

        DispatchQueue.main.async {
            guard let cm = self.canvasManager else { semaphore.signal(); return }
            switch Self.resolveUUID(idString, in: cm.document.routes.map(\.id)) {
            case .matched(let uuid):
                outcome = cm.updateRoute(id: uuid, newPath: newPath) ? .updated : .notFound
            case .invalid:
                outcome = .invalid
            case .ambiguous(let n):
                outcome = .ambiguous(n)
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .updated:
            return jsonResponse(["ok": true, "id": idString, "path": newPath])
        case .notFound:
            return errorResponse(404, "Route not found: \(idString)")
        case .invalid:
            return errorResponse(400, "Invalid 'id' '\(idString)' — expected a full UUID or unambiguous UUID prefix from list_routes")
        case .ambiguous(let n):
            return errorResponse(400, "Ambiguous 'id' prefix '\(idString)' matches \(n) routes — provide more characters")
        }
    }

    // MARK: - POST /capture

    private func handleCapture(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "POST", message: "/capture")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }

        // Optional `{"ids": [String]}` body. Empty/missing → capture all (back-compat).
        let body = Data(request.body)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let rawIds = json?["ids"] as? [String]

        // Resolve `ids` against current routes on @MainActor before kicking off capture.
        // Subset path returns 400 on bad ids and 409 if a capture is already in flight,
        // so callers don't silently piggy-back on someone else's full-canvas capture.
        enum Plan {
            case captureAll
            case captureSubset([UUID])
            case error(Int, String)
            case inProgress(capturedSoFar: Int)
        }

        let resolveSemaphore = DispatchSemaphore(value: 0)
        var plan: Plan = .captureAll
        // (id, path) pairs of routes the agent is waiting on. Captured under @MainActor
        // here so the timeout path can synthesise a partial-result body without racing
        // with concurrent route adds/removes.
        var workingRouteSnapshots: [(id: UUID, path: String)] = []

        DispatchQueue.main.async {
            guard let cm = self.canvasManager else {
                plan = .error(500, "Canvas not ready")
                resolveSemaphore.signal()
                return
            }
            guard let rawIds, !rawIds.isEmpty else {
                plan = .captureAll
                workingRouteSnapshots = cm.document.routes.map { ($0.id, $0.path) }
                resolveSemaphore.signal()
                return
            }
            var uuids: [UUID] = []
            for id in rawIds {
                switch Self.resolveUUID(id, in: cm.document.routes.map(\.id)) {
                case .matched(let u):
                    uuids.append(u)
                case .invalid:
                    plan = .error(400, "Invalid id '\(id)' — expected a full UUID or unambiguous UUID prefix from list_routes")
                    resolveSemaphore.signal()
                    return
                case .ambiguous(let n):
                    plan = .error(400, "Ambiguous id prefix '\(id)' matches \(n) routes — provide more characters")
                    resolveSemaphore.signal()
                    return
                }
            }
            if cm.screenshotService.isCaptureInProgress {
                plan = .inProgress(capturedSoFar: cm.document.screenshots.count)
                resolveSemaphore.signal()
                return
            }
            plan = .captureSubset(uuids)
            let idSet = Set(uuids)
            workingRouteSnapshots = cm.document.routes
                .filter { idSet.contains($0.id) }
                .map { ($0.id, $0.path) }
            resolveSemaphore.signal()
        }

        if resolveSemaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }

        switch plan {
        case .error(let code, let msg):
            return errorResponse(code, msg)
        case .inProgress(let n):
            return jsonResponse(["error": "Capture in progress", "capturedSoFar": n], code: 409, message: "Conflict")
        case .captureAll, .captureSubset:
            break
        }

        let captureSemaphore = DispatchSemaphore(value: 0)
        var result: [[String: String]] = []

        DispatchQueue.main.async {
            Task { @MainActor in
                switch plan {
                case .captureSubset(let uuids):
                    result = await self.canvasManager?.captureAll(ids: uuids) ?? []
                default:
                    result = await self.canvasManager?.captureAll() ?? []
                }
                captureSemaphore.signal()
            }
        }

        // Three-tier capture can take 10s+ per route per pass — allow plenty of time
        let timeout = captureSemaphore.wait(timeout: .now() + 180.0)
        if timeout == .timedOut {
            // The Task is still running on @MainActor — orphan it. Subsequent /capture
            // calls hit the isCaptureInProgress guard (→ 409) until it drains. This is
            // simpler than cooperative cancellation and matches today's wait-it-out
            // behaviour for piggy-backed captures.
            return self.partialTimeoutResponse(workingRouteSnapshots: workingRouteSnapshots)
        }

        return jsonResponse(["screenshots": result])
    }

    /// Build a structured 504 body listing what *was* captured before the deadline.
    /// `screenshots` carries the partial set so the MCP client can still surface images;
    /// `unsettled` names the routes that didn't finish so agents can target them next.
    private func partialTimeoutResponse(workingRouteSnapshots: [(id: UUID, path: String)]) -> HttpResponse {
        let snapshotSemaphore = DispatchSemaphore(value: 0)
        var captured = 0
        var unsettled: [String] = []
        var partial: [[String: String]] = []

        DispatchQueue.main.async {
            guard let cm = self.canvasManager else {
                snapshotSemaphore.signal()
                return
            }
            for r in workingRouteSnapshots {
                if let url = cm.document.screenshots[r.id] {
                    captured += 1
                    partial.append(["path": r.path, "filePath": url.path])
                } else {
                    unsettled.append(r.path)
                }
            }
            snapshotSemaphore.signal()
        }
        _ = snapshotSemaphore.wait(timeout: .now() + 5)

        let body: [String: Any] = [
            "error": "Capture timed out",
            "captured": captured,
            "total": workingRouteSnapshots.count,
            "unsettled": unsettled,
            "screenshots": partial,
        ]
        return jsonResponse(body, code: 504, message: "Gateway Timeout")
    }

    // MARK: - Document (markdown) handlers

    private func handleGetDocuments() -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "GET", message: "/documents")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [[String: Any]] = []
        DispatchQueue.main.async {
            result = self.canvasManager?.documentData ?? []
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        return jsonResponse(result)
    }

    private func handlePostDocuments(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "POST", message: "/documents")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let filePath = json["filePath"] as? String else {
            return errorResponse(400, "Missing 'filePath' in request body")
        }
        let x = (json["x"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let y = (json["y"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let width = (json["width"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let height = (json["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let placement = Self.parsePlacement(json["placement"])

        let semaphore = DispatchSemaphore(value: 0)
        var id: UUID?
        DispatchQueue.main.async {
            id = self.canvasManager?.addDocument(filePath: filePath, x: x, y: y, width: width, height: height, placement: placement)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        guard let uuid = id else {
            return errorResponse(400, "File not readable: \(filePath)")
        }
        return jsonResponse(["ok": true, "filePath": filePath, "id": uuid.uuidString])
    }

    private func handleDeleteDocuments(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "DELETE", message: "/documents")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        guard let idParam = request.queryParams.first(where: { $0.0 == "id" })?.1, !idParam.isEmpty else {
            return errorResponse(400, "Missing 'id' query parameter")
        }

        enum Outcome { case removed, notFound, invalid, ambiguous(Int) }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .notFound

        DispatchQueue.main.async {
            guard let cm = self.canvasManager else { semaphore.signal(); return }
            switch Self.resolveUUID(idParam, in: cm.document.documents.map(\.id)) {
            case .matched(let uuid):
                outcome = cm.removeDocument(id: uuid) ? .removed : .notFound
            case .invalid:
                outcome = .invalid
            case .ambiguous(let n):
                outcome = .ambiguous(n)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .removed: return jsonResponse(["ok": true])
        case .notFound: return errorResponse(404, "Document not found: \(idParam)")
        case .invalid: return errorResponse(400, "Invalid 'id' '\(idParam)' — expected a full UUID or unambiguous UUID prefix from list_documents")
        case .ambiguous(let n): return errorResponse(400, "Ambiguous 'id' prefix '\(idParam)' matches \(n) documents — provide more characters")
        }
    }

    // MARK: - Image handlers

    private func handleGetImages() -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "GET", message: "/images")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [[String: Any]] = []
        DispatchQueue.main.async {
            result = self.canvasManager?.imageData ?? []
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        return jsonResponse(result)
    }

    private func handlePostImages(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "POST", message: "/images")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let filePath = json["filePath"] as? String else {
            return errorResponse(400, "Missing 'filePath' in request body")
        }
        let x = (json["x"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let y = (json["y"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let width = (json["width"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let height = (json["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let placement = Self.parsePlacement(json["placement"])

        let semaphore = DispatchSemaphore(value: 0)
        var id: UUID?
        DispatchQueue.main.async {
            id = self.canvasManager?.addImage(filePath: filePath, x: x, y: y, width: width, height: height, placement: placement)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        guard let uuid = id else {
            return errorResponse(400, "File not readable: \(filePath)")
        }
        return jsonResponse(["ok": true, "filePath": filePath, "id": uuid.uuidString])
    }

    private func handleDeleteImages(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "DELETE", message: "/images")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        guard let idParam = request.queryParams.first(where: { $0.0 == "id" })?.1, !idParam.isEmpty else {
            return errorResponse(400, "Missing 'id' query parameter")
        }

        enum Outcome { case removed, notFound, invalid, ambiguous(Int) }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .notFound

        DispatchQueue.main.async {
            guard let cm = self.canvasManager else { semaphore.signal(); return }
            switch Self.resolveUUID(idParam, in: cm.document.images.map(\.id)) {
            case .matched(let uuid):
                outcome = cm.removeImage(id: uuid) ? .removed : .notFound
            case .invalid:
                outcome = .invalid
            case .ambiguous(let n):
                outcome = .ambiguous(n)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .removed: return jsonResponse(["ok": true])
        case .notFound: return errorResponse(404, "Image not found: \(idParam)")
        case .invalid: return errorResponse(400, "Invalid 'id' '\(idParam)' — expected a full UUID or unambiguous UUID prefix from list_images")
        case .ambiguous(let n): return errorResponse(400, "Ambiguous 'id' prefix '\(idParam)' matches \(n) images — provide more characters")
        }
    }

    // MARK: - POST /frames/batch

    private func handlePostFramesBatch(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "POST", message: "/frames/batch")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let rawItems = json["items"] as? [[String: Any]] else {
            return errorResponse(400, "Missing or malformed 'items' array in request body")
        }
        guard !rawItems.isEmpty else {
            return errorResponse(400, "'items' array is empty — pass at least one item")
        }

        // Parse items into Swift structs. Validation errors are surfaced before we touch the canvas.
        var items: [CanvasManager.BatchItem] = []
        for (index, raw) in rawItems.enumerated() {
            guard let typeStr = raw["type"] as? String else {
                return errorResponse(400, "Item [\(index)] missing 'type' (route|document|image)")
            }
            let width = (raw["width"] as? NSNumber).map { CGFloat($0.doubleValue) }
            let height = (raw["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
            switch typeStr {
            case "route":
                guard let p = raw["path"] as? String else {
                    return errorResponse(400, "Item [\(index)] (route) missing 'path'")
                }
                let port = (raw["port"] as? NSNumber)?.intValue
                let serverIdRaw = raw["serverId"] as? String
                let serverId = serverIdRaw.flatMap { UUID(uuidString: $0) }
                if let raw = serverIdRaw, serverId == nil {
                    return errorResponse(400, "Item [\(index)] (route) invalid 'serverId': \(raw)")
                }
                items.append(.route(path: p, width: width, height: height, port: port, serverId: serverId))
            case "document":
                guard let p = raw["filePath"] as? String else {
                    return errorResponse(400, "Item [\(index)] (document) missing 'filePath'")
                }
                items.append(.document(filePath: p, width: width, height: height))
            case "image":
                guard let p = raw["filePath"] as? String else {
                    return errorResponse(400, "Item [\(index)] (image) missing 'filePath'")
                }
                items.append(.image(filePath: p, width: width, height: height))
            default:
                return errorResponse(400, "Item [\(index)] unknown 'type': \(typeStr) (expected route|document|image)")
            }
        }

        let layout: CanvasManager.BatchLayout = ((json["layout"] as? String) == "pairs-rows") ? .pairsRows : .row
        // Batches default to .newRow so the whole group claims a fresh band — explicit
        // "right-of-last" is honoured for callers who want the batch to continue an existing row.
        let explicitPlacement: CanvasManager.Placement =
            ((json["placement"] as? String) == "right-of-last") ? .rightOfLast : .newRow

        enum Outcome {
            case ok([CanvasManager.BatchResult])
            case validation(String)
            case ambiguous(CanvasManager.ServerDisambiguationError)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .validation("unknown")

        DispatchQueue.main.async {
            do {
                let results = try self.canvasManager?.addBatch(items: items, layout: layout, placement: explicitPlacement) ?? []
                outcome = .ok(results)
            } catch let err as CanvasManager.BatchError {
                switch err {
                case .invalidItem(let idx, let reason):
                    outcome = .validation("Item [\(idx)] invalid: \(reason)")
                case .fileNotReadable(let idx, let path):
                    outcome = .validation("Item [\(idx)] file not readable: \(path)")
                case .serverAmbiguous(let dis):
                    outcome = .ambiguous(dis)
                }
            } catch {
                outcome = .validation("Internal error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .ok(let results):
            let added: [[String: Any]] = results.map { r in
                var dict: [String: Any] = [
                    "id": r.id.uuidString,
                    "type": r.type,
                    "x": r.x,
                    "y": r.y,
                    "width": r.width,
                    "height": r.height,
                ]
                if let p = r.path { dict["path"] = p }
                if let f = r.filePath { dict["filePath"] = f }
                return dict
            }
            return jsonResponse(["ok": true, "added": added])
        case .validation(let msg):
            return errorResponse(400, msg)
        case .ambiguous(let dis):
            let list: [[String: Any]] = dis.availableServers.map { entry in
                var dict: [String: Any] = [
                    "serverId": entry.id.uuidString,
                    "projectName": entry.projectName,
                ]
                if let p = entry.port { dict["port"] = p }
                if let d = entry.projectDir { dict["projectDir"] = d }
                return dict
            }
            let body: [String: Any] = [
                "error": "server_required",
                "message": "Batch contains a route on an ambiguous server. Pass 'port' or 'serverId' on that item.",
                "availableServers": list,
            ]
            return jsonResponse(body, code: 409, message: "Conflict")
        }
    }

    // MARK: - Section handlers

    private func handleGetSections() -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "GET", message: "/sections")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [[String: Any]] = []
        DispatchQueue.main.async {
            result = self.canvasManager?.sectionData ?? []
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        return jsonResponse(result)
    }

    private func handlePostSections(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "POST", message: "/sections")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let title = json["title"] as? String,
              let rawItems = json["items"] as? [[String: Any]] else {
            return errorResponse(400, "Missing 'title' or 'items' in request body")
        }
        guard !rawItems.isEmpty else {
            return errorResponse(400, "'items' array is empty — pass at least one item")
        }

        var items: [CanvasManager.BatchItem] = []
        for (index, raw) in rawItems.enumerated() {
            guard let typeStr = raw["type"] as? String else {
                return errorResponse(400, "Item [\(index)] missing 'type' (route|document|image)")
            }
            let width = (raw["width"] as? NSNumber).map { CGFloat($0.doubleValue) }
            let height = (raw["height"] as? NSNumber).map { CGFloat($0.doubleValue) }
            switch typeStr {
            case "route":
                guard let p = raw["path"] as? String else {
                    return errorResponse(400, "Item [\(index)] (route) missing 'path'")
                }
                let port = (raw["port"] as? NSNumber)?.intValue
                let serverIdRaw = raw["serverId"] as? String
                let serverId = serverIdRaw.flatMap { UUID(uuidString: $0) }
                if let raw = serverIdRaw, serverId == nil {
                    return errorResponse(400, "Item [\(index)] (route) invalid 'serverId': \(raw)")
                }
                items.append(.route(path: p, width: width, height: height, port: port, serverId: serverId))
            case "document":
                guard let p = raw["filePath"] as? String else {
                    return errorResponse(400, "Item [\(index)] (document) missing 'filePath'")
                }
                items.append(.document(filePath: p, width: width, height: height))
            case "image":
                guard let p = raw["filePath"] as? String else {
                    return errorResponse(400, "Item [\(index)] (image) missing 'filePath'")
                }
                items.append(.image(filePath: p, width: width, height: height))
            default:
                return errorResponse(400, "Item [\(index)] unknown 'type': \(typeStr)")
            }
        }

        let layout: CanvasManager.BatchLayout = ((json["layout"] as? String) == "pairs-rows") ? .pairsRows : .row
        let x = (json["x"] as? NSNumber).map { CGFloat($0.doubleValue) }
        let y = (json["y"] as? NSNumber).map { CGFloat($0.doubleValue) }

        enum Outcome {
            case ok(CanvasManager.SectionResult)
            case validation(String)
            case ambiguous(CanvasManager.ServerDisambiguationError)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .validation("unknown")
        DispatchQueue.main.async {
            do {
                if let result = try self.canvasManager?.addSection(title: title, items: items, layout: layout, x: x, y: y) {
                    outcome = .ok(result)
                } else {
                    outcome = .validation("Canvas not ready")
                }
            } catch let err as CanvasManager.BatchError {
                switch err {
                case .invalidItem(let idx, let reason):
                    outcome = .validation("Item [\(idx)] invalid: \(reason)")
                case .fileNotReadable(let idx, let path):
                    outcome = .validation("Item [\(idx)] file not readable: \(path)")
                case .serverAmbiguous(let dis):
                    outcome = .ambiguous(dis)
                }
            } catch {
                outcome = .validation("Internal error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .ok(let res):
            let added: [[String: Any]] = res.frames.map { r in
                var dict: [String: Any] = [
                    "id": r.id.uuidString,
                    "type": r.type,
                    "x": r.x,
                    "y": r.y,
                    "width": r.width,
                    "height": r.height,
                ]
                if let p = r.path { dict["path"] = p }
                if let f = r.filePath { dict["filePath"] = f }
                return dict
            }
            return jsonResponse([
                "ok": true,
                "sectionId": res.sectionId.uuidString,
                "added": added,
            ])
        case .validation(let msg):
            return errorResponse(400, msg)
        case .ambiguous(let dis):
            let list: [[String: Any]] = dis.availableServers.map { entry in
                var dict: [String: Any] = [
                    "serverId": entry.id.uuidString,
                    "projectName": entry.projectName,
                ]
                if let p = entry.port { dict["port"] = p }
                if let d = entry.projectDir { dict["projectDir"] = d }
                return dict
            }
            let body: [String: Any] = [
                "error": "server_required",
                "message": "Section contains a route on an ambiguous server. Pass 'port' or 'serverId' on that item.",
                "availableServers": list,
            ]
            return jsonResponse(body, code: 409, message: "Conflict")
        }
    }

    private func handleDeleteSections(_ request: HttpRequest) -> HttpResponse {
        CrashReporter.shared.breadcrumb(category: "api", action: "DELETE", message: "/sections")
        DispatchQueue.main.async { self.mcpState?.recordAPIRequest() }
        guard let idParam = request.queryParams.first(where: { $0.0 == "id" })?.1, !idParam.isEmpty else {
            return errorResponse(400, "Missing 'id' query parameter")
        }

        enum Outcome { case removed, notFound, invalid, ambiguous(Int) }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Outcome = .notFound

        DispatchQueue.main.async {
            guard let cm = self.canvasManager else { semaphore.signal(); return }
            switch Self.resolveUUID(idParam, in: cm.document.sections.map(\.id)) {
            case .matched(let uuid):
                outcome = cm.removeSection(id: uuid) ? .removed : .notFound
            case .invalid:
                outcome = .invalid
            case .ambiguous(let n):
                outcome = .ambiguous(n)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return errorResponse(504, "Main thread timed out")
        }
        switch outcome {
        case .removed: return jsonResponse(["ok": true])
        case .notFound: return errorResponse(404, "Section not found: \(idParam)")
        case .invalid: return errorResponse(400, "Invalid 'id' '\(idParam)' — expected a full UUID or unambiguous UUID prefix from list_sections")
        case .ambiguous(let n): return errorResponse(400, "Ambiguous 'id' prefix '\(idParam)' matches \(n) sections — provide more characters")
        }
    }

    // MARK: - Response helpers

    private func jsonResponse(_ object: Any) -> HttpResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return errorResponse(500, "JSON serialization failed")
        }
        return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
            try writer.write(data)
        }
    }

    private func jsonResponse(_ object: Any, code: Int, message: String) -> HttpResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return errorResponse(500, "JSON serialization failed")
        }
        return .raw(code, message, ["Content-Type": "application/json"]) { writer in
            try writer.write(data)
        }
    }

    private func errorResponse(_ code: Int, _ message: String) -> HttpResponse {
        let body = Data("{\"error\":\"\(message)\"}".utf8)
        return .raw(code, message, ["Content-Type": "application/json"]) { writer in
            try writer.write(body)
        }
    }

    // MARK: - ID resolution (full UUID or unambiguous prefix)

    /// Accept either a full 36-char UUID or an unambiguous prefix (case-insensitive).
    /// Returns `.invalid` when neither parses as a UUID nor matches any prefix —
    /// caller turns that into a clear 400 instead of the old "missing or invalid" mush.
    enum IDResolution {
        case matched(UUID)
        case invalid
        case ambiguous(Int)
    }

    private static func resolveUUID(_ idParam: String, in ids: [UUID]) -> IDResolution {
        if let exact = UUID(uuidString: idParam) {
            return .matched(exact)
        }
        let lower = idParam.lowercased()
        let matches = ids.filter { $0.uuidString.lowercased().hasPrefix(lower) }
        switch matches.count {
        case 0: return .invalid
        case 1: return .matched(matches[0])
        default: return .ambiguous(matches.count)
        }
    }

    /// Parse the optional `placement` field from a request body. Unknown values fall
    /// back to the default (.rightOfLast) rather than erroring — placement is advisory.
    static func parsePlacement(_ raw: Any?) -> CanvasManager.Placement {
        guard let s = raw as? String else { return .rightOfLast }
        switch s {
        case "new-row": return .newRow
        case "right-of-last": return .rightOfLast
        default: return .rightOfLast
        }
    }
}
