// Spawns a dev server (npm/pnpm/yarn/bun) or connects to an already-running one.
// Detects the package manager from lock files. Probes the target port first; if
// something responds, skips spawning. Kills the process group on stop.

import Foundation
import Observation

@Observable
@MainActor
class DevServerManager {

    // MARK: - Public state

    enum Status: Equatable {
        case disconnected
        case probing
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: "No Server"
            case .probing:      "Checking port…"
            case .starting:     "Starting…"
            case .running:      "Running"
            case .failed(let m): "Failed: \(m)"
            }
        }
    }

    private(set) var status: Status = .disconnected
    private(set) var serverURL: URL?
    private(set) var projectDir: String?
    private(set) var port: Int = 3000

    /// True when the server was spawned by us (vs. detected externally).
    private(set) var didSpawn = false

    // MARK: - Private

    private var process: Process?
    private var pollTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var outputPipe: Pipe?

    // MARK: - Connect (probe only, never spawns)

    /// Probe for an existing server on the given port. If found, connect and
    /// auto-detect the project directory. If not found, stay disconnected and
    /// keep monitoring — the user manages their own dev server externally.
    func connect(port: Int = 3000) {
        // Cancel stale monitors from previous port
        healthTask?.cancel()
        healthTask = nil
        pollTask?.cancel()
        pollTask = nil

        // Clear stale state so UI doesn't show old port's data
        serverURL = nil

        self.port = port
        CrashReporter.shared.breadcrumb(category: "server", action: "connect", message: "port:\(port)")
        status = .probing

        Task {
            let alive = await probeLocalhost(port: port)
            if alive {
                status = .running
                serverURL = URL(string: "http://localhost:\(port)")
                didSpawn = false
                FileLogger.shared.log("Found existing server on port \(port)", tag: "DevServer")
                AnalyticsService.shared.capture(.devServerConnected, properties: [
                    "port": port,
                    "server_type": "existing",
                ])

                // Always re-resolve project dir (different port = likely different project)
                if let dir = await resolveProjectDir(port: port) {
                    projectDir = dir
                    FileLogger.shared.log("Resolved project dir: \(dir)", tag: "DevServer")
                }

                startMonitor(port: port)
                return
            }

            // No server running — stay disconnected and monitor.
            // Never auto-spawn: the user manages their own dev server externally.
            FileLogger.shared.log("No server responding on port \(port) (probed both IPv4 and IPv6)", tag: "DevServer", level: .warn)
            CrashReporter.shared.breadcrumb(category: "server", action: "connect_miss", message: "port:\(port)")
            status = .disconnected
            startMonitor(port: port)
        }
    }

    // MARK: - Spawn

    func startServer(projectDir: String, port: Int = 3000) {
        stopServer()
        self.projectDir = projectDir
        self.port = port

        // Validate: package.json must exist
        let pkgPath = (projectDir as NSString).appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: pkgPath) else {
            status = .failed("No package.json in \(projectDir)")
            FileLogger.shared.log("No package.json at \(pkgPath)", tag: "DevServer", level: .error)
            return
        }

        let pm = Self.detectPackageManager(in: projectDir)

        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [pm, "run", "dev", "--", "--port", "\(port)"]

        // Resolve PATH from the user's login shell so nvm/volta/fnm-managed
        // Node.js is found even when launched from Finder (GUI apps don't
        // inherit the interactive shell PATH).
        var env = ProcessInfo.processInfo.environment
        if let shellPath = Self.resolveShellPath() {
            env["PATH"] = shellPath
        } else {
            // Fallback: common install locations
            let home = env["HOME"] ?? NSHomeDirectory()
            let extraPaths = [
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "\(home)/.nvm/versions/node/default/bin",
                "\(home)/.nvm/versions/node/v22/bin",
                "\(home)/.volta/bin",
                "\(home)/.fnm/aliases/default/bin",
                "\(home)/.bun/bin",
                "\(home)/.local/share/pnpm",
            ]
            env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        }
        proc.environment = env

        // Create a new process group so we can kill the tree later
        proc.qualityOfService = .userInitiated

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        // Log output (non-blocking read)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                FileLogger.shared.log(trimmed, tag: "DevServer.stdout")
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                if proc.terminationStatus != 0 && self.status != .disconnected {
                    self.status = .failed(Self.humanReadableExit(proc.terminationStatus))
                }
                self.process = nil
                self.didSpawn = false
            }
        }

        do {
            try proc.run()
            process = proc
            didSpawn = true
            status = .starting
            FileLogger.shared.log("Spawned \(pm) run dev (pid \(proc.processIdentifier)) in \(projectDir)", tag: "DevServer")
            startPolling(port: port)
        } catch {
            status = .failed(error.localizedDescription)
            FileLogger.shared.log("Failed to spawn: \(error)", tag: "DevServer", level: .error)
        }
    }

    // MARK: - Stop

    func stopServer() {
        CrashReporter.shared.breadcrumb(category: "server", action: "disconnect", message: "port:\(port)")
        pollTask?.cancel()
        pollTask = nil
        healthTask?.cancel()
        healthTask = nil

        if let proc = process, proc.isRunning {
            // Kill the entire process group so Node.js children don't survive
            let pid = proc.processIdentifier
            kill(-pid, SIGTERM)
            // Wait up to 5s for graceful shutdown, then force kill
            let deadline = DispatchTime.now() + 5.0
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
            }
            if proc.isRunning {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                    if proc.isRunning {
                        kill(-pid, SIGKILL)
                    }
                }
            }
            FileLogger.shared.log("Killed process group \(pid)", tag: "DevServer")
        }

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil
        didSpawn = false
        status = .disconnected
        serverURL = nil
    }

    // MARK: - HTTP Polling (ready detection)

    private func startPolling(port: Int) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            let url = URL(string: "http://localhost:\(port)")!
            let interval: TimeInterval = 0.5
            let timeout: TimeInterval = 30
            var elapsed: TimeInterval = 0

            while elapsed < timeout {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                elapsed += interval
                guard let self, !Task.isCancelled else { return }

                let alive = await probeLocalhost(port: port)
                if alive {
                    self.status = .running
                    self.serverURL = url
                    FileLogger.shared.log("Server ready on port \(port) after \(String(format: "%.1f", elapsed))s", tag: "DevServer")
                    self.startMonitor(port: port)
                    return
                }
            }

            self?.status = .failed("Timeout — server didn't respond within \(Int(timeout))s")
        }
    }

    // MARK: - Server monitor (detect death + detect new server appearing)

    /// Runs continuously. When running, checks server is still alive.
    /// When disconnected, checks if a server has appeared on the port.
    private func startMonitor(port: Int) {
        healthTask?.cancel()
        healthTask = Task { @MainActor [weak self] in
            let runningInterval: UInt64 = 2_000_000_000           // 2s — fast death detection while live
            let disconnectedBaseInterval: UInt64 = 5_000_000_000  // 5s initial idle scan
            let maxInterval: UInt64 = 30_000_000_000              // 30s cap when no server appears
            var disconnectedInterval = disconnectedBaseInterval

            while !Task.isCancelled {
                let interval: UInt64 = (self?.status == .running) ? runningInterval : disconnectedInterval
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }

                let alive = await probeLocalhost(port: port)

                if self.status == .running && !alive {
                    // Server was running but stopped — double-check
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    let stillDead = !(await probeLocalhost(port: port))
                    if stillDead {
                        self.status = .disconnected
                        self.serverURL = nil
                        self.didSpawn = false
                        self.process = nil
                        disconnectedInterval = disconnectedBaseInterval
                        FileLogger.shared.log("Server on port \(port) is no longer responding", tag: "DevServer", level: .warn)
                    }
                } else if self.status == .disconnected && alive {
                    // Server appeared externally
                    self.status = .running
                    self.serverURL = URL(string: "http://localhost:\(port)")
                    self.didSpawn = false
                    disconnectedInterval = disconnectedBaseInterval
                    FileLogger.shared.log("Detected server on port \(port)", tag: "DevServer")

                    // Always re-resolve project directory — it may be a different project
                    // on the same port. This triggers onChange(of: projectDir) for session switching.
                    if let dir = await self.resolveProjectDir(port: port) {
                        if dir != self.projectDir {
                            self.projectDir = dir
                            FileLogger.shared.log("Resolved project dir: \(dir)", tag: "DevServer")
                        } else if self.projectDir == nil {
                            self.projectDir = dir
                            FileLogger.shared.log("Resolved project dir: \(dir)", tag: "DevServer")
                        }
                    }
                } else if self.status == .disconnected && !alive {
                    // No server — back off
                    disconnectedInterval = min(disconnectedInterval * 2, maxInterval)
                }
            }
        }
    }

    // MARK: - Set project directory (without spawning)

    func setProjectDir(_ dir: String) {
        projectDir = dir
    }

    // MARK: - Auto-detect project directory from process on port

    /// Find the working directory of the process listening on a given port.
    /// Uses `lsof` to get PIDs, then checks each one's cwd for a package.json.
    /// Works for any dev server (Node, Python, Go, Ruby) — framework-agnostic.
    private nonisolated func resolveProjectDir(port: Int) async -> String? {
        // Step 1: Get PIDs listening on the port
        guard let pidsOutput = runShell("/usr/sbin/lsof", ["-ti", ":\(port)"]) else { return nil }
        let pids = pidsOutput.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return nil }

        // Step 2: For each PID, get its working directory and check for package.json
        for pid in pids {
            guard let cwdOutput = runShell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { continue }

            // Parse lsof output: lines starting with "n" contain the path
            for line in cwdOutput.split(separator: "\n") {
                guard line.hasPrefix("n") else { continue }
                let dir = String(line.dropFirst())

                // Skip system paths and root
                guard dir.count > 1, dir.hasPrefix("/Users/") || dir.hasPrefix("/home/") else { continue }

                // Validate: must contain package.json (or similar project marker)
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

    /// Run a shell command synchronously and return stdout as a string.
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

    // MARK: - Package manager detection

    /// Detect which package manager a project uses by checking lock files.
    /// Falls back to npm if no lock file is found.
    private static func detectPackageManager(in projectDir: String) -> String {
        let fm = FileManager.default
        let path = { (file: String) in (projectDir as NSString).appendingPathComponent(file) }

        if fm.fileExists(atPath: path("bun.lockb")) || fm.fileExists(atPath: path("bun.lock")) {
            return "bun"
        } else if fm.fileExists(atPath: path("pnpm-lock.yaml")) {
            return "pnpm"
        } else if fm.fileExists(atPath: path("yarn.lock")) {
            return "yarn"
        }
        return "npm"
    }

    // MARK: - Human-readable exit codes

    private static func humanReadableExit(_ code: Int32) -> String {
        switch code {
        case 1:   return "Server crashed"
        case 2:   return "Server stopped unexpectedly"
        case 127: return "Package manager not found — check Node.js install"
        case 126: return "Permission denied running server"
        case 128 + 9:  return "Server killed (SIGKILL)"
        case 128 + 15: return "Server terminated"
        default:  return "Server exited (\(code))"
        }
    }

    // MARK: - Shell PATH resolution

    /// Run the user's login shell to get their full PATH (includes nvm, volta, fnm, etc.).
    /// Cached after first call since it won't change within a session.
    private static var cachedShellPath: String?
    private static var didResolveShellPath = false

    private static func resolveShellPath() -> String? {
        if didResolveShellPath { return cachedShellPath }
        didResolveShellPath = true

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "echo $PATH"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty else { return nil }
            cachedShellPath = path
            return path
        } catch {
            return nil
        }
    }

    // Cleanup is handled by stopServer() called from applicationWillTerminate.
    // No deinit needed — @MainActor properties can't be safely accessed from deinit.
}
