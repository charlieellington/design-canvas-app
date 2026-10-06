// Cookie reader for the unofficial claude.ai usage endpoint.
// Pulls the `sessionKey` cookie out of a WKWebsiteDataStore that the login sheet
// writes into. Cookies persist across launches with no Keychain involvement — so
// a one-time WKWebView login is enough to authenticate the JSON poller for the
// lifetime of the session cookie.
//
// Every call takes a `store` so each Claude account can keep its own isolated
// cookie jar: account 1 uses `.default()`, additional accounts use persistent
// WebKit profiles created via `WKWebsiteDataStore(forIdentifier:)`. The default
// argument keeps single-account call sites unchanged.

import Foundation
import WebKit

@MainActor
enum ClaudeAuth {
    /// Returns the current `sessionKey` cookie value for `claude.ai` in `store`,
    /// or nil if that account is signed out / has never signed in.
    static func currentSessionKey(store: WKWebsiteDataStore = .default()) async -> String? {
        let cookies = await store.httpCookieStore.allCookies()
        return cookies.first { isClaudeSessionKey($0) }?.value
    }

    /// Returns the latest `sessionKey` cookie object — useful to read its
    /// expiry date if we ever want to surface a "your login is about to expire"
    /// hint. Currently unused but cheap to keep alongside `currentSessionKey`.
    static func currentSessionCookie(store: WKWebsiteDataStore = .default()) async -> HTTPCookie? {
        let cookies = await store.httpCookieStore.allCookies()
        return cookies.first { isClaudeSessionKey($0) }
    }

    /// Sign the user out by deleting every cookie scoped to `claude.ai` in
    /// `store`. Removes more than just `sessionKey` so any related auth state
    /// (anti-CSRF tokens, partial-login fragments) is cleared in one shot.
    static func signOut(store: WKWebsiteDataStore = .default()) async {
        let cookieStore = store.httpCookieStore
        let cookies = await cookieStore.allCookies()
        for cookie in cookies where isClaudeDomain(cookie.domain) {
            await cookieStore.deleteCookie(cookie)
        }
    }

    private static func isClaudeSessionKey(_ cookie: HTTPCookie) -> Bool {
        cookie.name == "sessionKey" && isClaudeDomain(cookie.domain)
    }

    private static func isClaudeDomain(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        return lower == "claude.ai" || lower == ".claude.ai" || lower.hasSuffix(".claude.ai")
    }
}
