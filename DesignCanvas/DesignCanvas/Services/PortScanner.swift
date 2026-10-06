// Scans common dev server ports to find running servers. Resolves project name from
// the process working directory. Used by WorkspaceSwitcherState to populate the "Running" section.

import Foundation
import Observation

struct DetectedServer: Identifiable, Equatable {
    let port: Int
    let projectName: String
    let projectDir: String?

    var id: Int { port }
}

@Observable
@MainActor
class PortScanner {

    private(set) var detectedServers: [DetectedServer] = []
    private var scanTask: Task<Void, Never>?
    private var emptyScans = 0

    /// Ports to probe on each scan cycle.
    static let commonPorts = [
        3000, 3001, 3002, 3003, 3004, 3005, 3006, 3007, 3008, 3009, 3010,
        4000, 5173, 5174, 8000, 8080,
    ]

    /// Run a one-off scan without affecting the periodic scan task.
    /// Used by the demo fast-scan loop to avoid cancelling the periodic scan.
    func scanNow() {
        Task {
            let found = await fullScanAwait()
            guard !Task.isCancelled else { return }
            detectedServers = found
        }
    }

    /// Run a single scan of all common ports. Updates `detectedServers`.
    func scan() {
        scanTask?.cancel()
        scanTask = Task {
            let found = await fullScanAwait()
            guard !Task.isCancelled else { return }
            detectedServers = found
        }
    }

    /// Phase 1: TCP probe only (~50ms). Returns placeholder `DetectedServer` entries
    /// for live ports with `projectDir: nil` and `projectName: "localhost:<port>"`.
    /// Updates `detectedServers` immediately, then fires-and-forgets background
    /// enrichment that resolves project dirs and patches entries in place.
    @discardableResult
    func quickProbe() async -> [DetectedServer] {
        let livePorts = await probeAllPorts()
        let placeholders = livePorts.map {
            DetectedServer(port: $0, projectName: "localhost:\($0)", projectDir: nil)
        }
        detectedServers = placeholders
        Task { [weak self] in
            await self?.enrich(ports: livePorts)
        }
        return placeholders
    }

    /// Full scan: probe + lsof project-dir resolution. Returns when both phases are done.
    /// Used for periodic scan and `scan()` / `scanNow()`.
    @discardableResult
    func fullScanAwait() async -> [DetectedServer] {
        let livePorts = await probeAllPorts()
        let resolved = await resolveAllProjectDirs(ports: livePorts)
        detectedServers = resolved
        return resolved
    }

    /// Start periodic scanning. Backs off from 30s to 60s after 3 consecutive empty scans.
    /// Note: caller (smartLaunch) should call scan() first if an immediate scan is needed.
    func startPeriodicScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds: UInt64 = (self?.emptyScans ?? 0) >= 3 ? 60 : 30
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.runScanCycle()
                if self.detectedServers.isEmpty {
                    self.emptyScans = min(self.emptyScans + 1, 10)
                } else {
                    self.emptyScans = 0
                }
            }
        }
    }

    func stopPeriodicScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Private

    private func runScanCycle() async {
        let found = await fullScanAwait()
        guard !Task.isCancelled else { return }
        detectedServers = found
    }

    /// Probe all common ports in parallel. Returns sorted list of live port numbers.
    /// No `lsof` shell-out — just TCP connect probes (~5ms per live port, instant per dead).
    private func probeAllPorts() async -> [Int] {
        await withTaskGroup(of: Int?.self) { group in
            for port in Self.commonPorts {
                group.addTask {
                    await probeLocalhost(port: port) ? port : nil
                }
            }
            var results: [Int] = []
            for await result in group {
                if let port = result { results.append(port) }
            }
            return results.sorted()
        }
    }

    /// Resolve project dirs for known live ports in parallel. Returns enriched list.
    private func resolveAllProjectDirs(ports: [Int]) async -> [DetectedServer] {
        await withTaskGroup(of: DetectedServer.self) { group in
            for port in ports {
                group.addTask { [self] in
                    let dir = await self.resolveProjectDir(port: port)
                    let name = dir.map { self.resolveProjectName(projectDir: $0) } ?? "localhost:\(port)"
                    return DetectedServer(port: port, projectName: name, projectDir: dir)
                }
            }
            var results: [DetectedServer] = []
            for await server in group { results.append(server) }
            return results.sorted(by: { $0.port < $1.port })
        }
    }

    /// Background enrichment after `quickProbe`: replaces placeholder entries in
    /// `detectedServers` one-by-one as each `lsof` resolution completes.
    private func enrich(ports: [Int]) async {
        await withTaskGroup(of: DetectedServer.self) { group in
            for port in ports {
                group.addTask { [self] in
                    let dir = await self.resolveProjectDir(port: port)
                    let name = dir.map { self.resolveProjectName(projectDir: $0) } ?? "localhost:\(port)"
                    return DetectedServer(port: port, projectName: name, projectDir: dir)
                }
            }
            for await server in group {
                if let idx = detectedServers.firstIndex(where: { $0.port == server.port }) {
                    detectedServers[idx] = server
                }
            }
        }
    }

    private nonisolated func resolveProjectDir(port: Int) async -> String? {
        guard let pidsOutput = runShell("/usr/sbin/lsof", ["-ti", ":\(port)"]) else { return nil }
        let pids = pidsOutput.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return nil }

        for pid in pids {
            guard let cwdOutput = runShell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { continue }
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

    private nonisolated func resolveProjectName(projectDir: String) -> String {
        let pkgURL = URL(fileURLWithPath: projectDir).appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkgURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }
        return URL(fileURLWithPath: projectDir).lastPathComponent
    }

    private nonisolated func runShell(_ path: String, _ arguments: [String]) -> String? {
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
