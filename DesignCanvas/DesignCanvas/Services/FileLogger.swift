// Writes structured log lines to ~/Library/Logs/DesignCanvas/app.log so debugging
// doesn't require Xcode console. Rotates when the file exceeds 2 MB.

import Foundation

final class FileLogger: @unchecked Sendable {

    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "com.designcanvas.filelogger", qos: .utility)
    private let logDir: URL
    private let logFile: URL
    private let maxBytes: UInt64 = 2_000_000  // 2 MB
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logDir = home.appendingPathComponent("Library/Logs/\(BuildPolicy.dataDirectoryName)")
        logFile = logDir.appendingPathComponent("app.log")

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func log(_ message: String, tag: String = "App", level: Level = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [\(level.rawValue)] [\(tag)] \(message)\n"

        queue.async { [self] in
            rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFile.path) {
                    if let handle = try? FileHandle(forWritingTo: logFile) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: logFile, options: .atomic)
                }
            }
        }

        // Also print to Xcode console for convenience
        print("[\(tag)] \(message)")
    }

    /// Path to the current log file — use this to read from a Claude agent.
    var path: String { logFile.path }

    // MARK: - Levels

    enum Level: String {
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
    }

    // MARK: - Rotation

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }

        let rotated = logDir.appendingPathComponent("app.prev.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: logFile, to: rotated)
    }
}
