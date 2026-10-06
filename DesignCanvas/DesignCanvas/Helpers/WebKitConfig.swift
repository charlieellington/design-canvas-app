// Shared WebKit configuration — shares cookies/sessions across route views via default data store.
// Injects scrollbar-hiding CSS, height measurement JS, and SPA navigation hooks into every webview.

import WebKit

class WebKitConfig {
    static let shared = WebKitConfig()

    let dataStore = WKWebsiteDataStore.default()

    private init() {}

    /// Height measurement JS — ResizeObserver on document.body with debounce and threshold guard.
    /// Posts measured height via window.webkit.messageHandlers.frameMetrics.postMessage().
    /// Idempotent: safe to re-evaluate (guards against duplicate observers).
    static let heightMeasurementJS = """
    (function() {
        if (window.__dcHeightSetup) { if (window.__dcReportHeight) window.__dcReportHeight(); return; }
        window.__dcHeightSetup = true;

        var lastReported = 0;
        var timer = null;

        function measure() {
            return Math.ceil(Math.max(
                document.body ? document.body.scrollHeight : 0,
                document.body ? document.body.offsetHeight : 0,
                document.documentElement ? document.documentElement.scrollHeight : 0,
                document.documentElement ? document.documentElement.offsetHeight : 0
            ));
        }

        window.__dcReportHeight = function() {
            var h = measure();
            if (Math.abs(h - lastReported) < 4) return;
            lastReported = h;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.frameMetrics) {
                window.webkit.messageHandlers.frameMetrics.postMessage({ height: h });
            }
        };

        var observer = new ResizeObserver(function() {
            clearTimeout(timer);
            timer = setTimeout(window.__dcReportHeight, 100);
        });

        if (document.body) {
            observer.observe(document.body);
            observer.observe(document.documentElement);
        } else {
            document.addEventListener('DOMContentLoaded', function() {
                if (document.body) observer.observe(document.body);
                observer.observe(document.documentElement);
            });
        }

        window.__dcReportHeight();
    })();
    """

    /// On-demand intrinsic height measurement for "Fit to Content".
    /// Temporarily neutralises viewport-relative sizing (height:100%, min-height:100vh)
    /// on html, body, and framework root wrappers (#__next etc.), measures, then restores.
    static let fitToContentJS = """
    (function() {
        var html = document.documentElement;
        var body = document.body;
        if (!body) return 0;
        var htmlH = html.style.height, htmlMinH = html.style.minHeight, htmlMaxH = html.style.maxHeight;
        var bodyH = body.style.height, bodyMinH = body.style.minHeight, bodyMaxH = body.style.maxHeight;
        var bodyOv = body.style.overflow, bodyOvY = body.style.overflowY;
        var saved = [];
        function save(el) {
            if (el.tagName === 'SCRIPT' || el.tagName === 'STYLE' || el.tagName === 'LINK') return;
            saved.push({ el: el, h: el.style.height, mh: el.style.minHeight, xh: el.style.maxHeight,
                         ov: el.style.overflow, ovy: el.style.overflowY });
            el.style.height = 'auto'; el.style.minHeight = '0'; el.style.maxHeight = 'none';
            el.style.overflow = 'visible'; el.style.overflowY = 'visible';
        }
        try {
            html.style.height = 'auto'; html.style.minHeight = '0'; html.style.maxHeight = 'none';
            body.style.height = 'auto'; body.style.minHeight = '0'; body.style.maxHeight = 'none';
            body.style.overflow = 'visible'; body.style.overflowY = 'visible';
            for (var i = 0; i < body.children.length; i++) {
                var child = body.children[i];
                save(child);
                for (var j = 0; j < child.children.length; j++) save(child.children[j]);
            }
            void body.offsetHeight;
            return Math.ceil(Math.max(body.scrollHeight, body.offsetHeight));
        } finally {
            html.style.height = htmlH; html.style.minHeight = htmlMinH; html.style.maxHeight = htmlMaxH;
            body.style.height = bodyH; body.style.minHeight = bodyMinH; body.style.maxHeight = bodyMaxH;
            body.style.overflow = bodyOv; body.style.overflowY = bodyOvY;
            for (var k = 0; k < saved.length; k++) {
                var s = saved[k];
                s.el.style.height = s.h; s.el.style.minHeight = s.mh; s.el.style.maxHeight = s.xh;
                s.el.style.overflow = s.ov; s.el.style.overflowY = s.ovy;
            }
        }
    })();
    """

    /// SPA navigation hook — monkey-patches pushState/replaceState and listens for popstate
    /// so client-side route changes (React Router, Next.js, etc.) post to dcNavChange handler.
    /// Idempotent: guards against duplicate patching.
    static let spaNavigationHookJS = """
    (function() {
        if (window.__dcNavHook) return;
        window.__dcNavHook = true;
        function notify() {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dcNavChange) {
                window.webkit.messageHandlers.dcNavChange.postMessage({ url: location.href });
            }
        }
        var origPush = history.pushState;
        history.pushState = function() { origPush.apply(this, arguments); notify(); };
        var origReplace = history.replaceState;
        history.replaceState = function() { origReplace.apply(this, arguments); notify(); };
        window.addEventListener('popstate', notify);
    })();
    """

    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore

        // Dark background at document start — prevents white flash before page CSS loads.
        // Uses !important so it wins over default body bg; page's own styles override once loaded.
        let darkBgCSS = "html, body { background-color: #191A1D !important; }"
        let darkBgJS = "var s = document.createElement('style'); s.id='dc-preload-bg'; s.textContent = '\(darkBgCSS)'; document.documentElement.appendChild(s);"
        let darkBgScript = WKUserScript(
            source: darkBgJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(darkBgScript)

        // Hide scrollbars + remove preload dark background once page content is ready
        let css = "::-webkit-scrollbar { display: none; }"
        let scrollbarJS = "var style = document.createElement('style'); style.textContent = '\(css)'; document.head.appendChild(style);"
        let removePreloadBg = "var dcBg = document.getElementById('dc-preload-bg'); if (dcBg) dcBg.remove();"
        let scrollbarScript = WKUserScript(
            source: scrollbarJS + removePreloadBg,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(scrollbarScript)

        // Height measurement script (Stage 3c) — posts to frameMetrics handler
        let heightScript = WKUserScript(
            source: Self.heightMeasurementJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(heightScript)

        // SPA navigation hook — catches pushState/replaceState for focus-mode nav capsule
        let navHookScript = WKUserScript(
            source: Self.spaNavigationHookJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(navHookScript)

        return config
    }
}
