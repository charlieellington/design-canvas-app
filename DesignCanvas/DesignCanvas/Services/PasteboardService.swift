// Thin wrapper around NSPasteboard so PasteModal can be exercised without touching the
// system pasteboard in tests. See onboarding-v3-implementation.md § 4.

import AppKit

@MainActor
protocol PasteboardService {
    func copy(_ value: String)
}

final class SystemPasteboard: PasteboardService {
    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
