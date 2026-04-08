import SwiftUI
import WebKit

// ── Paste your API Gateway URL here ───────────────────────────────────
private let API_GATEWAY_URL = "https://y25m8puewi.execute-api.us-west-1.amazonaws.com/prod/notify"

struct ForestryWebView: UIViewRepresentable {
    let url: URL
    let coordinator: AppCoordinator

    func makeCoordinator() -> AppCoordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // ── Allow inline camera preview / video ──────────────────────
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // ── Geolocation bridge ───────────────────────────────────────
        config.userContentController.add(context.coordinator,
                                         name: "locationRequest")
        config.userContentController.addUserScript(
            WKUserScript(source: locationBridgeJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )

        // ── APNs token bridge ────────────────────────────────────────
        // Injects window.__apns_device_token and window.CrewBoss into
        // every page. Your web JS calls CrewBoss.registerToken(userId)
        // after the user logs in — it POSTs straight to API Gateway.
        let savedToken = UserDefaults.standard.string(forKey: "apns_device_token") ?? ""
        let tokenBridgeJS = """
        (function () {
            window.__apns_device_token = "\(savedToken)";
            window.__apns_api_url      = "\(API_GATEWAY_URL)";

            window.CrewBoss = {
                // Call this after login: CrewBoss.registerToken(userId)
                registerToken: function (userId) {
                    var token = window.__apns_device_token;
                    if (!token || token.length === 0) return;
                    fetch(window.__apns_api_url, {
                        method:  'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({
                            action:       'register',
                            user_id:      String(userId),
                            device_token: token
                        })
                    }).then(function(r) {
                        console.log('[CrewBoss] token registered, status:', r.status);
                    }).catch(function(err) {
                        console.warn('[CrewBoss] registerToken failed:', err);
                    });
                }
            };
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: tokenBridgeJS,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        
        func webViewer(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Test that injection worked — results print in Xcode console
            webView.evaluateJavaScript("""
                console.log('Token:', window.__apns_device_token || 'MISSING');
                console.log('CrewBoss:', typeof window.CrewBoss);
                console.log('API URL:', window.__apns_api_url || 'MISSING');
            """)
        }
        

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate          = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .scrollableAxes

        if #available(iOS 16.4, *) { webView.isInspectable = true }

        context.coordinator.register(webView: webView, homeURL: url)
        webView.load(URLRequest(url: url))
        
        // ── TEMPORARY TEST — remove before shipping ──────────────────
        webView.evaluateJavaScript("""
            if (window.CrewBoss) {
                window.CrewBoss.registerToken('test-user-123');
            } else {
                console.log('CrewBoss not found on this page');
            }
        """)
        
        // ── JS console → Xcode console bridge ───────────────────────────
        config.userContentController.add(context.coordinator, name: "xcodelogdebug")
        config.userContentController.addUserScript(
            WKUserScript(source: """
            (function () {
                var _log = console.log.bind(console);
                console.log = function () {
                    var msg = Array.from(arguments).join(' ');
                    window.webkit.messageHandlers.xcodelogdebug.postMessage(msg);
                    _log.apply(console, arguments);
                };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // ── Geolocation JS (unchanged) ───────────────────────────────────
    private let locationBridgeJS = """
    (function () {
        window.__geo_success = null;
        window.__geo_error   = null;

        const _orig = navigator.geolocation.getCurrentPosition
            .bind(navigator.geolocation);

        navigator.geolocation.getCurrentPosition = function (success, error, opts) {
            window.__geo_success = success;
            window.__geo_error   = error || null;
            window.webkit.messageHandlers.locationRequest.postMessage({});
        };

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
