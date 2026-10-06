// What this file does (plain English):
// This is the "two Claude accounts at once" coordinator. The app can show the
// usage of more than one Claude subscription side by side, so Charlie can glance
// up, see which account still has headroom, and switch his work to it. Account 1
// is the original single account and behaves exactly as before. Adding a second
// account gives it its OWN isolated browser session, so both accounts can stay
// signed in at the same time instead of one login overwriting the other.
//
// Account 1 → ClaudeUsageService.shared on WKWebsiteDataStore.default()
// Account 2 → a second ClaudeUsageService on a persistent WebKit "profile"
//             (WKWebsiteDataStore(forIdentifier:), macOS 14+). Its claude.ai
//             cookie lives in a separate jar, persisted to disk under that UUID,
//             so it survives relaunches and never clashes with account 1.

import Foundation
import Observation
import WebKit

@Observable
@MainActor
final class ClaudeAccountsManager {
    /// One usage service per tracked account. `[0]` is always account 1 (the
    /// default-store singleton); `[1]` exists only after a second account is added.
    private(set) var accounts: [ClaudeUsageService] = [.shared]

    /// Strong reference that keeps the second account's profile store alive for
    /// the app's lifetime — required for its cookie writes to persist reliably.
    private var secondStore: WKWebsiteDataStore?

    private static let secondUUIDKey = "claudeUsagePill.account2.storeUUID"
    private static let secondKeyPrefix = "claudeUsagePill.account2."

    // Fixed, slot-based labels shown on the pill / menu-bar item when two accounts
    // are tracked. Unambiguous regardless of the accounts' emails.
    static let primaryLabel = "Main"
    static let secondLabel = "2nd"

    init() {
        accounts[0].accountLabel = Self.primaryLabel
        restoreSecondAccountIfPresent()
    }

    /// Account 1 — always present.
    var primaryAccount: ClaudeUsageService { accounts[0] }

    /// Account 2 — present only once added.
    var secondAccount: ClaudeUsageService? { accounts.count > 1 ? accounts[1] : nil }

    /// True once a second account has been added.
    var hasSecondAccount: Bool { accounts.count > 1 }

    /// True while there's still a free slot (we track at most two accounts).
    var canAddAccount: Bool { accounts.count < 2 }

    /// A stable, non-optional handle for the second account's menu bar item.
    /// The app declares that MenuBarExtra unconditionally (gated by `isInserted`
    /// + `hasSecondAccount`) rather than behind `if let second` — a *conditional*
    /// second Scene pushes the App's Scene body past the Swift type-checker's
    /// complexity limit. When no real second account exists this returns a
    /// dormant, never-started placeholder on a throwaway in-memory store, and the
    /// menu bar item stays hidden via `hasSecondAccount`.
    @ObservationIgnored
    private let menuBarPlaceholder = ClaudeUsageService(
        dataStore: .nonPersistent(),
        keyPrefix: "claudeUsagePill.placeholder."
    )
    var secondMenuBarAccount: ClaudeUsageService { secondAccount ?? menuBarPlaceholder }

    // MARK: - Lifecycle

    func startAll() { accounts.forEach { $0.start() } }
    func stopAll() { accounts.forEach { $0.stop() } }

    // MARK: - Add / remove

    /// Add the second account: mint a fresh persistent profile, build a service
    /// bound to it, persist the profile UUID, and start polling. Returns the new
    /// service so the caller can immediately present its login sheet. If a second
    /// account already exists this is a no-op that returns the existing one.
    @discardableResult
    func addSecondAccount() -> ClaudeUsageService? {
        if let existing = secondAccount { return existing }
        let uuid = UUID() // random, never the all-zero UUID that the initializer rejects
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        let service = ClaudeUsageService(dataStore: store, keyPrefix: Self.secondKeyPrefix)
        service.accountLabel = Self.secondLabel
        secondStore = store
        UserDefaults.standard.set(uuid.uuidString, forKey: Self.secondUUIDKey)
        accounts.append(service)
        service.start()
        return service
    }

    /// Remove the second account: sign it out (clears its cookies), stop polling,
    /// forget its persisted settings + profile UUID, and discard the on-disk
    /// profile. Account 1 is untouched.
    func removeSecondAccount() {
        guard let service = secondAccount else { return }
        service.signOut()
        service.stop()
        service.forgetPersistedSettings()
        accounts.removeLast()

        let uuid = secondStore?.identifier
        secondStore = nil
        UserDefaults.standard.removeObject(forKey: Self.secondUUIDKey)
        // Best-effort disk cleanup of the now-orphaned profile. Cookies are already
        // gone via signOut(), so failure here is harmless.
        if let uuid {
            WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }
        }
    }

    // MARK: - Restore

    /// On launch, rebuild the second account from its persisted profile UUID so it
    /// stays signed in across relaunches (WebKit restores the cookies from disk).
    private func restoreSecondAccountIfPresent() {
        guard
            let saved = UserDefaults.standard.string(forKey: Self.secondUUIDKey),
            let uuid = UUID(uuidString: saved)
        else { return }
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        let service = ClaudeUsageService(dataStore: store, keyPrefix: Self.secondKeyPrefix)
        service.accountLabel = Self.secondLabel
        secondStore = store
        accounts.append(service)
    }
}
