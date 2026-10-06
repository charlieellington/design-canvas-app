// Local builds and forks never inherit the official distribution's services or data.
import Foundation
import Security

enum BuildPolicy {
    static let apiPort = UInt16(ProcessInfo.processInfo.environment["DESIGN_CANVAS_PORT"] ?? "7420") ?? 7420
    static var localAPIURL: String { "http://127.0.0.1:\(apiPort)" }

    static let accountIntegrationKey = "accountUsageIntegrationsEnabled"
    static var accountIntegrationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: accountIntegrationKey)
    }

    /// An explicit release flag alone cannot opt a fork into the official updater.
    /// Require the official bundle ID and a valid signature from its release team.
    static let isOfficialDistribution: Bool = {
        guard Bundle.main.object(forInfoDictionaryKey: "DesignCanvasOfficialDistribution") as? String == "YES",
              Bundle.main.bundleIdentifier == "com.designcanvas.app" else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let officialRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"5NULP26FKR\" and identifier \"com.designcanvas.app\""
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(officialRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any] else { return false }
        return details[kSecCodeInfoTeamIdentifier as String] as? String == "5NULP26FKR"
    }()

    static var dataDirectoryName: String {
        isOfficialDistribution ? "DesignCanvas" : "DesignCanvasLocal"
    }

    static var tokenDirectoryName: String {
        isOfficialDistribution ? ".designcanvas" : ".designcanvas-local"
    }

    /// No fallback to a hosted service, including in Release builds.
    static func shareBaseURL(defaults: UserDefaults = .standard) -> URL? {
        guard let raw = defaults.string(forKey: "DesignCanvasShareBaseURL"),
              let url = URL(string: raw),
              let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else { return nil }
        return url
    }
}
