// WKNavigationDelegate that logs all navigation events and notifies containers of state changes.
// WKWebView failures are silent without this — essential for debugging.

import AppKit
import WebKit

class WebViewCoordinator: NSObject, WKNavigationDelegate {

    var onLoadingStarted: (() -> Void)?
    var onLoadingFinished: (() -> Void)?
    var onLoadingFailed: ((String) -> Void)?
    var onProcessTerminated: (() -> Void)?

    /// Fired when the dev server responds with 404 for a main-frame navigation.
    /// Triggers a file system re-validation — does NOT directly mark the route as removed.
    var onPossibleRouteRemoval: (() -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        print("Loading: \(webView.url?.absoluteString ?? "unknown")")
        onLoadingStarted?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("Loaded: \(webView.url?.absoluteString ?? "unknown")")
        onLoadingFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // -999 (NSURLErrorCancelled) is normal — happens when a frame is demoted during
        // loading or a new load supersedes the old one. Not a real failure.
        if (error as NSError).code == NSURLErrorCancelled { return }
        print("Failed: \(webView.url?.absoluteString ?? "unknown") — \(error.localizedDescription)")
        onLoadingFailed?(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        print("Failed to start: \(webView.url?.absoluteString ?? "unknown") — \(error.localizedDescription)")
        onLoadingFailed?(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Storm pause: while ReloadStormDetector is paused, swallow HMR-driven
        // reloads (`location.reload()` from the dev server's client JS surfaces
        // here as `.reload`). App-initiated `wv.load(URLRequest(...))` from
        // TileLifecycle uses `.other`, so the post-storm catch-up reload still
        // works. User link clicks are `.linkActivated` and stay allowed.
        // Note the suppression so the auto-resume quiet-timer keeps resetting
        // while the agent is still firing HMR — otherwise we'd auto-resume
        // mid-storm just because no `onLoadingStarted` ever fires.
        if navigationAction.navigationType == .reload {
            let suppressed = MainActor.assumeIsolated { () -> Bool in
                let detector = AppServices.shared.stormDetector
                guard detector.isPaused else { return false }
                detector.noteSuppressedReload()
                return true
            }
            if suppressed {
                decisionHandler(.cancel)
                return
            }
        }

        // Only hand off user-clicked cross-origin links to the default browser.
        // Programmatic loads, redirects, and same-origin navigations must stay
        // inside the frame — otherwise the initial route load itself (e.g. demo
        // mode's vercel.app URLs, or any non-localhost dev server) gets cancelled.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           let destHost = url.host,
           let currentHost = webView.url?.host,
           destHost != currentHost {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Only check main-frame navigations — sub-resources (CSS, JS) may 404 legitimately
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode == 404 {
            print("404 detected: \(http.url?.absoluteString ?? "unknown") — triggering route validation")
            onPossibleRouteRemoval?()
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("WebView process terminated: \(webView.url?.absoluteString ?? "unknown")")
        onProcessTerminated?()
    }
}
