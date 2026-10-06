// Crash uploads are disabled. Local logs stay on this machine.
import Foundation

final class CrashReporter {
    static let shared = CrashReporter()
    private init() {}
    func start() {}
    func breadcrumb(category: String, action: String, message: String) {}
}
