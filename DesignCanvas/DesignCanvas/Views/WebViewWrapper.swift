// NSViewRepresentable wrapping WKWebView for use in SwiftUI. Uses Coordinator pattern so the
// WKNavigationDelegate is retained stably across view updates.

import SwiftUI
import WebKit

struct WebViewWrapper: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
