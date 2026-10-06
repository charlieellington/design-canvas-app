// Saves and restores canvas state per project identity. Keys session files by a stable
// hash of (package.json name + normalized git remote URL) so different worktrees of the
// same repo share a single saved canvas. Falls back to name-only, then a path hash, when
// git or package.json are unavailable. Debounced to prevent disk thrashing during drags.

import Foundation
import CryptoKit

@MainActor
class SessionPersistence {

    /// Current project directory being tracked.
    var currentProjectDir: String?

    private let sessionsDir: URL
    private var debounceWork: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.5

    /// Memoized normalized git remote per projectDir. Empty string is the sentinel for
    /// "known to have no remote" so we don't reshell git on every save for non-git dirs.
    private var remoteCache: [String: String] = [:]

    init() {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            sessionsDir = appSupport.appendingPathComponent("\(BuildPolicy.dataDirectoryName)/sessions")
        } else {
            sessionsDir = FileManager.default.temporaryDirectory.appendingPathComponent("\(BuildPolicy.dataDirectoryName)/sessions")
        }
        // Defer migration so synchronous `git` doesn't run inside the dispatch_once
        // block that lazily constructs AppServices.shared. Process.waitUntilExit()
        // during static-let init can deadlock the main thread. Skip it in the hosted
        // XCTest process, where the test runner itself is injected through the same
        // run loop and can otherwise be re-entered while `git` is still waiting.
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil {
            Task { [weak self] in
                self?.migrateLegacyKeys()
            }
        }
    }

    // MARK: - Save

    func save(document: DocumentModel, projectDir: String, port: Int) {
        // Never persist demo mode state
        guard !AppServices.shared.demo.isInDemoMode else { return }
        let projectName = resolveProjectName(projectDir: projectDir)
        // Filter out removed routes — they shouldn't survive app restart.
        // On next launch, discovery re-runs and marks any truly missing routes fresh.
        let savedRoutes = document.routes.filter { !$0.isRemoved }.map { route in
            SavedRoute(
                path: route.path,
                urlPath: route.urlPath,
                displayName: route.displayName,
                x: route.x,
                y: route.y,
                width: route.width,
                height: route.height,
                serverBindingId: route.serverBindingId,
                captureDelay: route.captureDelay,
                captureDelaySource: route.captureDelaySource,
                isAnimatedDetected: route.isAnimatedDetected
            )
        }

        // Encode empty arrays as nil so old/clean project sessions stay tidy.
        let savedDocuments: [SavedMarkdownFrame]? = document.documents.isEmpty ? nil :
            document.documents.map { doc in
                SavedMarkdownFrame(id: doc.id, filePath: doc.filePath, displayName: doc.displayName,
                                   x: doc.x, y: doc.y, width: doc.width, height: doc.height)
            }
        let savedImages: [SavedImageFrame]? = document.images.isEmpty ? nil :
            document.images.map { img in
                SavedImageFrame(id: img.id, filePath: img.filePath, displayName: img.displayName,
                                x: img.x, y: img.y, width: img.width, height: img.height)
            }
        let savedSections: [SavedSection]? = document.sections.isEmpty ? nil :
            document.sections.map { sec in
                SavedSection(id: sec.id, title: sec.title,
                             x: sec.x, y: sec.y, width: sec.width, height: sec.height,
                             routeIds: sec.routeIds, documentIds: sec.documentIds, imageIds: sec.imageIds)
            }

        // A1: persist canvases + per-canvas snapshots. The flat (routes/documents/images/
        // bindings/primaryBindingId) fields above mirror the ACTIVE canvas's contents, so
        // a pre-A1 build downgrading reads them correctly. canvasSnapshots holds inactive
        // canvases' contents. v3-encoded snapshots map UUID → CanvasSnapshot as a
        // dictionary keyed by UUID.uuidString.
        let snapshots: [String: CanvasSnapshot]? = document.canvasSnapshots.isEmpty ? nil :
            Dictionary(uniqueKeysWithValues: document.canvasSnapshots.map { ($0.key.uuidString, $0.value) })

        let fileURL = sessionsDir.appendingPathComponent("\(cacheKey(projectDir: projectDir)).json")

        // Empty-overwrite guard: a save with zero user content is virtually never
        // intent — it's a race (e.g. dev server connected to a worktree whose
        // cacheKey differs from the saved one, leaving the canvas blank before
        // load resolves). Refuse to stomp an existing non-empty file.
        let isBlank = savedRoutes.isEmpty
            && savedDocuments == nil
            && savedImages == nil
            && savedSections == nil
            && snapshots == nil
            && document.canvases.count <= 1
        if isBlank, let existing = decodeState(at: fileURL),
           !(existing.routes.isEmpty
             && (existing.documents?.isEmpty ?? true)
             && (existing.images?.isEmpty ?? true)) {
            print("[SessionPersistence] Skipped empty-overwrite save for \(projectName) — \(existing.routes.count) saved routes preserved")
            return
        }

        let camera = AppServices.shared.camera
        let state = CanvasState(
            projectDir: projectDir,
            projectName: projectName,
            serverPort: port,
            routes: savedRoutes,
            documents: savedDocuments,
            images: savedImages,
            schemaVersion: 4,
            bindings: document.bindings.isEmpty ? nil : document.bindings,
            primaryBindingId: document.primaryBindingId,
            canvases: document.canvases.count > 1 ? document.canvases : nil,
            activeCanvasId: document.canvases.count > 1 ? document.activeCanvasId : nil,
            canvasSnapshots: snapshots,
            sections: savedSections,
            cameraX: Double(camera.origin.x),
            cameraY: Double(camera.origin.y),
            cameraZoom: Double(camera.zoom),
            styling: document.styling
        )

        do {
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            // Pretty-print for debuggability
            let prettyData = try JSONSerialization.data(
                withJSONObject: try JSONSerialization.jsonObject(with: data),
                options: [.prettyPrinted, .sortedKeys]
            )
            // Atomic write: Swift writes to a sibling `.<name>.tmp` file, fsyncs, then
            // POSIX-renames it into place. A crash, SIGKILL, or out-of-disk mid-write
            // leaves either the previous file intact OR the new file in place — never
            // a truncated, unparseable JSON. Mirrors FileLogger.swift's pattern.
            try prettyData.write(to: fileURL, options: .atomic)
            print("[SessionPersistence] Saved \(savedRoutes.count) routes for \(projectName)")
        } catch {
            print("[SessionPersistence] Save failed: \(error)")
        }
    }

    /// Schedule a debounced save. Cancels any pending save and schedules a new one.
    func scheduleSave(document: DocumentModel, port: Int) {
        guard let projectDir = currentProjectDir else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.save(document: document, projectDir: projectDir, port: port)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Save immediately — no debounce. Used on app termination.
    func saveNow(document: DocumentModel, port: Int) {
        debounceWork?.cancel()
        guard let projectDir = currentProjectDir else { return }
        save(document: document, projectDir: projectDir, port: port)
    }

    // MARK: - Load

    func load(projectDir: String) -> CanvasState? {
        let fileURL = sessionsDir.appendingPathComponent("\(cacheKey(projectDir: projectDir)).json")
        if let state = decodeState(at: fileURL) {
            print("[SessionPersistence] Loaded \(state.routes.count) routes, \(state.documents?.count ?? 0) documents, \(state.images?.count ?? 0) images for \(state.projectName)")
            return state
        }
        // Lazy fallback: legacy SHA256(projectDir) key from before the cacheKey rewrite.
        // Covers files written by an older app version after this app instance started
        // (init-time migrateLegacyKeys handles files that existed at launch).
        let legacyURL = sessionsDir.appendingPathComponent("\(legacyHash(projectDir)).json")
        if legacyURL != fileURL, let state = decodeState(at: legacyURL) {
            do {
                let data = try Data(contentsOf: legacyURL)
                // Atomic — same reasoning as the primary save path above.
                try data.write(to: fileURL, options: .atomic)
            } catch {
                print("[SessionPersistence] Lazy migration write failed: \(error)")
            }
            print("[SessionPersistence] Loaded \(state.routes.count) routes, \(state.documents?.count ?? 0) documents, \(state.images?.count ?? 0) images for \(state.projectName) (legacy key)")
            return state
        }
        // ProjectName fallback: cacheKey drifts between worktrees when one has
        // `git remote get-url origin` available and the other doesn't (different
        // payload shape → different SHA). Pick the most recent saved file whose
        // projectName matches this dir's resolved name and that has real content.
        let currentName = resolveProjectName(projectDir: projectDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentName.isEmpty else { return nil }
        if let match = listAll().first(where: { state in
            state.projectName.trimmingCharacters(in: .whitespacesAndNewlines) == currentName
                && !state.routes.isEmpty
        }) {
            print("[SessionPersistence] Recovered \(match.routes.count) routes by name-fallback for \(currentName) (from \(match.projectDir))")
            return match
        }
        return nil
    }

    private func decodeState(at url: URL) -> CanvasState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CanvasState.self, from: data)
        } catch {
            print("[SessionPersistence] Decode failed at \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - List all saved sessions

    /// Enumerate all saved session files for the workspace switcher "Recent" section.
    func listAll() -> [CanvasState] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return [] }
        let decoder = JSONDecoder()
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter { $0.pathExtension == "json" }

            // Sort by most recently modified first
            let sorted = files.sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA > dateB
            }

            return sorted.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CanvasState.self, from: data)
            }
        } catch {
            print("[SessionPersistence] listAll failed: \(error)")
            return []
        }
    }

    // MARK: - Delete

    /// Remove a saved session file for the given project directory.
    func delete(projectDir: String) {
        let fileURL = sessionsDir.appendingPathComponent("\(cacheKey(projectDir: projectDir)).json")
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Cache key

    /// Compute a stable cache key for a project. Two worktrees of the same repo (same
    /// package.json name + same git remote) resolve to the same key, so they share a
    /// single saved canvas. Falls back to name-only when no git remote, and to a hash
    /// of the projectDir when neither is available.
    func cacheKey(projectDir: String) -> String {
        let name = resolveProjectName(projectDir: projectDir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = resolveGitRemote(projectDir: projectDir)
        let payload: String
        switch (name.isEmpty, remote) {
        case (false, .some(let r)):
            payload = "name+remote::\(name)::\(r)"
        case (true, .some(let r)):
            payload = "remote::\(r)"
        case (false, nil):
            payload = "name::\(name)"
        case (true, nil):
            payload = "path::\(projectDir)"
        }
        return sha256Hex(payload)
    }

    // MARK: - Migration

    /// One-shot migration on init: rename every legacy-keyed `.json` file to its new key.
    /// Collisions (two worktrees, both pre-saved) keep the most recently modified file at
    /// the new key and rename losers to `<newName>.bak-<legacyHash>` so no data is silently
    /// destroyed. Idempotent — safe to run on every launch.
    private func migrateLegacyKeys() {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else { return }
        let decoder = JSONDecoder()
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter { $0.pathExtension == "json" }
        } catch {
            print("[SessionPersistence] migrateLegacyKeys: enumerate failed: \(error)")
            return
        }

        struct Candidate {
            let url: URL
            let mtime: Date
            let projectDir: String
        }
        var groups: [String: [Candidate]] = [:]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let state = try? decoder.decode(CanvasState.self, from: data) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let newName = "\(cacheKey(projectDir: state.projectDir)).json"
            groups[newName, default: []].append(Candidate(url: url, mtime: mtime, projectDir: state.projectDir))
        }

        var renamed = 0
        var bakd = 0
        for (newName, candidates) in groups {
            // Already canonical and unique → skip.
            if candidates.count == 1, candidates[0].url.lastPathComponent == newName { continue }
            let sorted = candidates.sorted { $0.mtime > $1.mtime }
            let winner = sorted[0]
            let dest = sessionsDir.appendingPathComponent(newName)
            if winner.url.lastPathComponent != newName {
                do {
                    if FileManager.default.fileExists(atPath: dest.path) {
                        // An undecodable or out-of-group file already occupies the slot — back it up.
                        let bak = sessionsDir.appendingPathComponent("\(newName).bak-existing")
                        try? FileManager.default.removeItem(at: bak)
                        try? FileManager.default.moveItem(at: dest, to: bak)
                    }
                    try FileManager.default.moveItem(at: winner.url, to: dest)
                    renamed += 1
                } catch {
                    print("[SessionPersistence] migrate winner failed for \(newName): \(error)")
                    continue
                }
            }
            for loser in sorted.dropFirst() {
                let suffix = sha256Hex(loser.projectDir).prefix(12)
                let bak = sessionsDir.appendingPathComponent("\(newName).bak-\(suffix)")
                do {
                    try? FileManager.default.removeItem(at: bak)
                    try FileManager.default.moveItem(at: loser.url, to: bak)
                    bakd += 1
                } catch {
                    print("[SessionPersistence] migrate loser bak failed for \(loser.url.lastPathComponent): \(error)")
                }
            }
        }
        if renamed > 0 || bakd > 0 {
            print("[SessionPersistence] Migration: \(renamed) renamed, \(bakd) backed up")
        }
    }

    // MARK: - Helpers

    private func resolveProjectName(projectDir: String) -> String {
        let pkgURL = URL(fileURLWithPath: projectDir).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkgURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        return URL(fileURLWithPath: projectDir).lastPathComponent
    }

    /// Run `git -C <dir> config --get remote.origin.url`, normalize the result.
    /// Returns nil if git fails, repo has no origin, or the remote is empty. Memoized
    /// per projectDir for the app session — empty string is the sentinel for "no remote".
    private func resolveGitRemote(projectDir: String) -> String? {
        guard !projectDir.isEmpty else { return nil }
        if let cached = remoteCache[projectDir] {
            return cached.isEmpty ? nil : cached
        }
        let gitPath = "/usr/bin/git"
        guard FileManager.default.fileExists(atPath: gitPath) else {
            remoteCache[projectDir] = ""
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", projectDir, "config", "--get", "remote.origin.url"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // discard stderr
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                remoteCache[projectDir] = ""
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let normalized = normalizeRemoteURL(raw) ?? ""
            remoteCache[projectDir] = normalized
            return normalized.isEmpty ? nil : normalized
        } catch {
            remoteCache[projectDir] = ""
            return nil
        }
    }

    /// Normalize remote URLs so SSH and HTTPS forms of the same repo collapse to one key.
    /// `git@github.com:foo/bar.git`, `https://github.com/foo/bar.git`, `https://github.com/foo/bar`
    /// all become `github.com/foo/bar`.
    private func normalizeRemoteURL(_ raw: String) -> String? {
        var s = raw.lowercased()
        if s.hasPrefix("git+") { s.removeFirst(4) }
        // SSH form: git@host:path → host/path
        if s.hasPrefix("git@"), let colonIdx = s.firstIndex(of: ":") {
            let host = String(s[s.index(s.startIndex, offsetBy: 4)..<colonIdx])
            let path = String(s[s.index(after: colonIdx)...])
            s = "\(host)/\(path)"
        }
        // Strip URL schemes
        for scheme in ["https://", "http://", "ssh://", "git://"] {
            if s.hasPrefix(scheme) {
                s.removeFirst(scheme.count)
                break
            }
        }
        if s.hasSuffix(".git") { s.removeLast(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    private func sha256Hex(_ string: String) -> String {
        let hash = SHA256.hash(data: Data(string.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Legacy keying scheme used before the cacheKey rewrite. Retained only for the lazy
    /// migration fallback in `load`.
    private func legacyHash(_ dir: String) -> String {
        sha256Hex(dir)
    }
}
