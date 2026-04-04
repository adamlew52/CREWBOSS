import SwiftUI
import WebKit

/// Wraps WKWebView so it can be used in SwiftUI.
/// Each tab gets its own WebView instance but shares one AppCoordinator
/// (so there's only one CLLocationManager and one image picker active at a time).
struct ForestryWebView: UIViewRepresentable {
    let url: URL
    /// Shared coordinator — handles location, file picking, JS dialogs.
    let coordinator: AppCoordinator

    func makeCoordinator() -> AppCoordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // ── Allow inline camera preview / video ──────────────────
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // ── Geolocation bridge ───────────────────────────────────
        // We intercept navigator.geolocation.getCurrentPosition so
        // iOS can prompt for permission and respond with real coordinates.
        config.userContentController.add(context.coordinator,
                                         name: "locationRequest")
        config.userContentController.addUserScript(
            WKUserScript(source: locationBridgeJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate          = context.coordinator

        // Prevent the web content from leaving a gap under the notch
        webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes

        // Useful during development — lets you inspect from Safari DevTools
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        // Give the coordinator a reference so it can call evaluateJavaScript
        context.coordinator.register(webView: webView)

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // ── JS injected before page load ─────────────────────────────
    // Replaces navigator.geolocation.getCurrentPosition with a version
    // that calls back to Swift, which responds via evaluateJavaScript.
    private let locationBridgeJS = """
    (function () {
        // Store callbacks so Swift can invoke them later
        window.__geo_success = null;
        window.__geo_error   = null;

        const _orig = navigator.geolocation.getCurrentPosition
            .bind(navigator.geolocation);

        navigator.geolocation.getCurrentPosition = function (success, error, opts) {
            window.__geo_success = success;
            window.__geo_error   = error || null;
            // Notify Swift to trigger CLLocationManager
            window.webkit.messageHandlers.locationRequest.postMessage({});
        };

        // Also expose helpers Swift calls back into
        window.__geo_respond = function (lat, lng, accuracy) {
            if (!window.__geo_success) return;
            window.__geo_success({
                coords: {
                    latitude:         lat,
                    longitude:        lng,
                    accuracy:         accuracy,
                    altitude:         null,
                    altitudeAccuracy: null,
                    heading:          null,
                    speed:            null
                },
                timestamp: Date.now()
            });
        };
        window.__geo_fail = function (code, msg) {
            if (!window.__geo_error) return;
            window.__geo_error({ code: code, message: msg });
        };
    })();
    """
}
