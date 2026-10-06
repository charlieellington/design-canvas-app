// One-time login flow for the Claude usage pill.
// Hosts a WKWebView pointed at https://claude.ai/login that writes into the
// account's own WKWebsiteDataStore (`service.dataStore`). After login, the
// `sessionKey` cookie persists across launches and ClaudeUsageService can fetch
// usage without further auth. Pointing each account at its own store is what lets
// two accounts stay signed in at once: a second account's login lands in a fresh,
// isolated jar instead of overwriting the first account's cookie.
//
// We dismiss automatically once `sessionKey` appears in the cookie store; we
// don't try to detect the post-login page via URL alone because Anthropic's
// flow involves multi-step redirects (SSO, 2FA, device challenges) that are
// awkward to whitelist statically.

import SwiftUI
import WebKit

struct ClaudeLoginSheet: View {
    let service: ClaudeUsageService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to claude.ai")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ClaudeLoginWebView(dataStore: service.dataStore) { token in
                service.refreshNow()
                dismiss()
            }
            .frame(width: 720, height: 640)
        }
        .frame(width: 720, height: 690)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ClaudeLoginWebView: NSViewRepresentable {
    let dataStore: WKWebsiteDataStore
    let onAuthenticated: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onAuthenticated: (String) -> Void
        weak var webView: WKWebView?
        private var didFire = false

        init(onAuthenticated: @escaping (String) -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForSessionKey(in: webView)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // Some flows set the cookie before the next navigation finishes —
            // re-check on commit too. Cheap; idempotent via `didFire` guard.
            checkForSessionKey(in: webView)
        }

        private func checkForSessionKey(in webView: WKWebView) {
            guard !didFire else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let match = cookies.first { c in
                    c.name == "sessionKey" &&
                    (c.domain == "claude.ai" || c.domain == ".claude.ai" || c.domain.hasSuffix(".claude.ai"))
                }
                guard let match else { return }
                self.didFire = true
                DispatchQueue.main.async {
                    self.onAuthenticated(match.value)
                }
            }
        }
    }
}
