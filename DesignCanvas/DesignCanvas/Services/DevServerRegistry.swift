// Passive catalog of ServerBindings on the current document. Layered on top of the
// existing DevServerManager (which keeps owning spawn/SIGTERM/health for the primary
// server). The registry's job is narrow: probe a port, resolve project identity,
// mint a ServerBinding. Actual ownership of bindings lives on DocumentModel.

import Foundation

@MainActor
final class DevServerRegistry {

    private weak var document: DocumentModel?

    init(document: DocumentModel) {
        self.document = document
    }

    // MARK: - Bind a new port to the active canvas

    /// Probe `port`, resolve project identity (projectDir / packageName / gitRemote),
    /// and append a fresh ServerBinding to the document. Returns the new binding's id,
    /// or nil if nothing is listening on that port.
    @discardableResult
    func bind(port: Int) async -> UUID? {
        guard let document else { return nil }
        let alive = await probeLocalhost(port: port)
        guard alive else { return nil }

        let projectDir = await resolveProjectDir(port: port)
        let packageName = projectDir.flatMap { Self.readPackageName(in: $0) }
        let gitRemote = projectDir.flatMap { Self.readGitRemote(in: $0) }
        let displayName = packageName
            ?? projectDir.map { ($0 as NSString).lastPathComponent }
            ?? "localhost:\(port)"

        // Dedupe — same origin, OR realpath-equal projectDir.
        let origin = URL(string: "http://localhost:\(port)")!
        if let existing = document.bindings.first(where: { binding in
            if binding.origin == origin { return true }
            if let a = binding.projectDir, let b = projectDir,
               (a as NSString).resolvingSymlinksInPath == (b as NSString).resolvingSymlinksInPath {
                return true
            }
            return false
        }) {
            // Refresh the existing binding's runtime info — it just came back online.
            if let idx = document.bindings.firstIndex(where: { $0.id == existing.id }) {
                document.bindings[idx].origin = origin
                document.bindings[idx].status = .connected
                document.bindings[idx].lastSeenAt = Date()
                if document.bindings[idx].projectDir == nil { document.bindings[idx].projectDir = projectDir }
                if document.bindings[idx].packageName == nil { document.bindings[idx].packageName = packageName }
                if document.bindings[idx].gitRemote == nil { document.bindings[idx].gitRemote = gitRemote }
            }
            return existing.id
        }

        let binding = ServerBinding(
            id: UUID(),
            origin: origin,
            displayName: displayName,
            projectDir: projectDir,
            packageName: packageName,
            gitRemote: gitRemote,
            lastSeenAt: Date(),
            status: .connected
        )
        document.bindings.append(binding)
        if document.primaryBindingId == nil { document.primaryBindingId = binding.id }
        return binding.id
    }

    // MARK: - Refresh status

    /// Probe every binding and flip status accordingly. Cheap (TCP probe per port).
    func refreshAll() async {
        guard let document else { return }
        for binding in document.bindings {
            guard let port = binding.port else { continue }
            let alive = await probeLocalhost(port: port)
            guard let idx = document.bindings.firstIndex(where: { $0.id == binding.id }) else { continue }
            if alive {
                document.bindings[idx].status = .connected
                document.bindings[idx].lastSeenAt = Date()
            } else if document.bindings[idx].status == .connected {
                document.bindings[idx].status = .stale
            }
        }
    }

    // MARK: - Project-identity resolvers (mirror DevServerManager's logic)

    private nonisolated func resolveProjectDir(port: Int) async -> String? {
        guard let pidsOutput = Self.runShell("/usr/sbin/lsof", ["-ti", ":\(port)"]) else { return nil }
        let pids = pidsOutput.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return nil }
        for pid in pids {
            guard let cwdOutput = Self.runShell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { continue }
            for line in cwdOutput.split(separator: "\n") {
                guard line.hasPrefix("n") else { continue }
                let dir = String(line.dropFirst())
                guard dir.count > 1, dir.hasPrefix("/Users/") || dir.hasPrefix("/home/") else { continue }
                let fm = FileManager.default
                if fm.fileExists(atPath: (dir as NSString).appendingPathComponent("package.json"))
                    || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("requirements.txt"))
                    || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("Gemfile"))
                    || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("go.mod"))
                    || fm.fileExists(atPath: (dir as NSString).appendingPathComponent("Cargo.toml")) {
                    return dir
                }
            }
        }
        return nil
    }

    nonisolated private static func readPackageName(in projectDir: String) -> String? {
        let pkgURL = URL(fileURLWithPath: projectDir).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkgURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    nonisolated private static func readGitRemote(in projectDir: String) -> String? {
        let gitPath = "/usr/bin/git"
        guard FileManager.default.fileExists(atPath: gitPath) else { return nil }
        guard let raw = runShell(gitPath, ["-C", projectDir, "config", "--get", "remote.origin.url"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return normaliseRemote(raw)
    }

    nonisolated private static func normaliseRemote(_ raw: String) -> String? {
        var s = raw.lowercased()
        if s.hasPrefix("git+") { s.removeFirst(4) }
        if s.hasPrefix("git@"), let colonIdx = s.firstIndex(of: ":") {
            let host = String(s[s.index(s.startIndex, offsetBy: 4)..<colonIdx])
            let path = String(s[s.index(after: colonIdx)...])
            s = "\(host)/\(path)"
        }
        for scheme in ["https://", "http://", "ssh://", "git://"] {
            if s.hasPrefix(scheme) { s.removeFirst(scheme.count); break }
        }
        if s.hasSuffix(".git") { s.removeLast(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    nonisolated private static func runShell(_ path: String, _ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
