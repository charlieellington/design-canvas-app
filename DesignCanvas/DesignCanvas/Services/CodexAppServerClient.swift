// Read-only bridge to `codex app-server`. The app server owns authentication
// and token refresh; Design Canvas only asks for the active account and its
// rate-limit snapshot. No credentials or response payloads are logged.

import Foundation

enum CodexAppServerError: Error, Equatable, LocalizedError {
    case executableNotFound
    case failedToLaunch
    case disconnected
    case requestTimedOut
    case protocolError
    case serverError

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex isn't installed"
        case .failedToLaunch:
            return "Codex couldn't be started"
        case .disconnected:
            return "Codex disconnected"
        case .requestTimedOut:
            return "Codex didn't respond"
        case .protocolError, .serverError:
            return "Codex usage is unavailable"
        }
    }
}

@MainActor
protocol CodexUsageClient: AnyObject {
    var onRateLimitsChanged: (() -> Void)? { get set }
    var onUnexpectedExit: (() -> Void)? { get set }

    func connect() async throws
    func readAccount(refreshToken: Bool) async throws -> [String: Any]
    func readRateLimits() async throws -> [String: Any]
    func disconnect()
}

/// Incremental JSONL decoder. FileHandle callbacks may split one JSON object
/// across reads or coalesce several objects into one read, so parsing cannot
/// assume one callback equals one message.
struct CodexJSONLStreamDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [[String: Any]] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var messages: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else { continue }
            messages.append(message)
        }
        return messages
    }
}

/// Mirrors DevServerManager's Finder-safe PATH strategy: resolve the user's
/// login-shell PATH, then locate an executable inside it. The returned path is
/// validated and never assumes a particular Codex or Conductor installation.
enum LoginShellExecutableResolver {
    static func resolve(_ executable: String) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var paths: [String] = []

        if let inherited = environment["PATH"] {
            paths.append(contentsOf: inherited.split(separator: ":").map(String.init))
        }
        if let loginPath = resolveLoginShellPath(environment: environment) {
            paths.append(contentsOf: loginPath.split(separator: ":").map(String.init))
        }

        let applicationSupportDirectories = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        return resolve(
            executable,
            searchPaths: paths,
            applicationSupportDirectories: applicationSupportDirectories
        )
    }

    /// Testable search core. Conductor exposes its selected Codex binary through
    /// a stable `bin/codex` symlink under its macOS Application Support folder.
    /// Constructing that location from the system directory keeps this independent
    /// of the macOS username and the versioned agent-binary installation path.
    static func resolve(
        _ executable: String,
        searchPaths: [String],
        applicationSupportDirectories: [URL]
    ) -> URL? {
        var paths = searchPaths
        paths.append(contentsOf: applicationSupportDirectories.map {
            $0
                .appendingPathComponent("com.conductor.app", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .path
        })

        var seen = Set<String>()
        for directory in paths where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(executable)
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func resolveLoginShellPath(environment: [String: String]) -> String? {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "echo $PATH"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty else { return nil }
            return path
        } catch {
            return nil
        }
    }
}

@MainActor
final class CodexAppServerClient: CodexUsageClient {
    var onRateLimitsChanged: (() -> Void)?
    var onUnexpectedExit: (() -> Void)?

    private struct PendingRequest {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeoutTask: Task<Void, Never>
    }

    private let executableResolver: () -> URL?
    private let requestTimeout: TimeInterval

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var streamDecoder = CodexJSONLStreamDecoder()
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var isStopping = false

    init(
        executableResolver: @escaping () -> URL? = { LoginShellExecutableResolver.resolve("codex") },
        requestTimeout: TimeInterval = 15
    ) {
        self.executableResolver = executableResolver
        self.requestTimeout = requestTimeout
    }

    func connect() async throws {
        guard process == nil else { return }
        guard let executableURL = executableResolver() else {
            throw CodexAppServerError.executableNotFound
        }

        isStopping = false
        streamDecoder = CodexJSONLStreamDecoder()

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.qualityOfService = .utility

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in self?.receive(data) }
        }

        // Consume stderr so the child can never block on a full pipe, but do not
        // retain or log it: auth/account diagnostics may contain private data.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                self?.handleTermination(of: terminated)
            }
        }

        self.process = process
        inputPipe = input
        outputPipe = output
        errorPipe = errors

        do {
            try process.run()
            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "design_canvas",
                        "title": "Design Canvas",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                    ]
                ]
            )
            try send(message: ["method": "initialized", "params": [:]])
        } catch {
            disconnect()
            if let known = error as? CodexAppServerError { throw known }
            throw CodexAppServerError.failedToLaunch
        }
    }

    func readAccount(refreshToken: Bool) async throws -> [String: Any] {
        try await request(
            method: "account/read",
            params: ["refreshToken": refreshToken]
        )
    }

    func readRateLimits() async throws -> [String: Any] {
        try await request(method: "account/rateLimits/read", params: NSNull())
    }

    func disconnect() {
        isStopping = true

        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()

        let runningProcess = process
        process = nil
        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminationHandler = nil
            runningProcess.terminate()
        }

        failPendingRequests(with: CodexAppServerError.disconnected)
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }

    // MARK: - Requests

    private func request(method: String, params: Any) async throws -> [String: Any] {
        guard process?.isRunning == true else { throw CodexAppServerError.disconnected }

        let requestID = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(self?.requestTimeout ?? 15))
                guard !Task.isCancelled else { return }
                self?.completeRequest(requestID, with: .failure(CodexAppServerError.requestTimedOut))
            }
            pendingRequests[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            do {
                try send(message: [
                    "id": requestID,
                    "method": method,
                    "params": params
                ])
            } catch {
                completeRequest(requestID, with: .failure(CodexAppServerError.disconnected))
            }
        }
    }

    private func send(message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message),
              let handle = inputPipe?.fileHandleForWriting else {
            throw CodexAppServerError.protocolError
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        for message in streamDecoder.append(data) {
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let requestID = (message["id"] as? NSNumber)?.intValue,
           pendingRequests[requestID] != nil {
            if message["error"] != nil {
                completeRequest(requestID, with: .failure(CodexAppServerError.serverError))
                return
            }
            if let result = message["result"] as? [String: Any] {
                completeRequest(requestID, with: .success(result))
            } else if message["result"] is NSNull {
                completeRequest(requestID, with: .success([:]))
            } else {
                completeRequest(requestID, with: .failure(CodexAppServerError.protocolError))
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        switch method {
        case "account/rateLimits/updated", "account/updated":
            onRateLimitsChanged?()
        default:
            break
        }
    }

    private func completeRequest(
        _ requestID: Int,
        with result: Result<[String: Any], Error>
    ) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(with: result)
    }

    private func failPendingRequests(with error: Error) {
        let pending = pendingRequests.values
        pendingRequests.removeAll()
        for request in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func handleTermination(of terminated: Process) {
        guard process === terminated else { return }
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        failPendingRequests(with: CodexAppServerError.disconnected)
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil

        if !isStopping {
            onUnexpectedExit?()
        }
    }
}
