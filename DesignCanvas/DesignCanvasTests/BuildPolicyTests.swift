import XCTest
@testable import DesignCanvas

final class BuildPolicyTests: XCTestCase {
    func testLocalBuildDoesNotUseOfficialServicesOrData() {
        XCTAssertFalse(BuildPolicy.isOfficialDistribution)
        XCTAssertEqual(BuildPolicy.dataDirectoryName, "DesignCanvasLocal")
        XCTAssertEqual(BuildPolicy.tokenDirectoryName, ".designcanvas-local")
    }

    func testSharingRequiresExplicitSafeEndpoint() {
        let suite = "BuildPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(BuildPolicy.shareBaseURL(defaults: defaults))
        for invalid in ["http://example.com", "https://user:password@example.com", "file:///tmp/share", "https://example.com?token=secret"] {
            defaults.set(invalid, forKey: "DesignCanvasShareBaseURL")
            XCTAssertNil(BuildPolicy.shareBaseURL(defaults: defaults))
        }
        for valid in ["http://127.0.0.1:4000", "https://sharing.example.com"] {
            defaults.set(valid, forKey: "DesignCanvasShareBaseURL")
            XCTAssertEqual(BuildPolicy.shareBaseURL(defaults: defaults)?.absoluteString, valid)
        }
    }
}
