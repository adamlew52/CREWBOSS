import SwiftUI
import WebKit
import StoreKit

// ═══════════════════════════════════════════════════════
//  ForestryWebView
//  Single WKWebView pointing at dashboard.html with:
//  - Offline caching (URLCache + snapshot fallback)
//  - APNs device token bridge
//  - setUserId handler (called by dashboard.html JS)
//  - Geolocation bridge
//  - Biometric bridge (window.CrewBossAuth)
//  - IAP test hooks
//
//  NOTE: Cognito Hosted UI cookies live in
//  WKWebsiteDataStore.default() and persist across launches.
//  Do not switch to .nonPersistent() or every relaunch will
//  bounce the user back through OAuth.
// ═══════════════════════════════════════════════════════

private let API_GATEWAY_URL = "https://y25m8puewi.execute-api.us-west-1.amazonaws.com/prod/notify"

// ── Offline cache: 100 MB disk, 25 MB memory ─────────
private let offlineCache: URLCache = {
    let cache = URLCache(
        memoryCapacity:  25 * 1024 * 1024,
        diskCapacity:   100 * 1024 * 1024,
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("WebCache")
    )
    URLCache.shared = cache
    return cache
}()

struct ForestryWebView: UIViewRepresentable {
    let url: URL
    let coordinator: AppCoordinator

    func makeCoordinator() -> AppCoordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        _ = offlineCache  // ensure cache is initialized

        let config = WKWebViewConfiguration()
        let ctrl   = config.userContentController

        // ── Inline media ─────────────────────────────────
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // Persistent store — required for the Cognito session cookie.
        config.websiteDataStore = .default()

        // ── Geolocation bridge ───────────────────────────
        ctrl.add(context.coordinator, name: "locationRequest")
        ctrl.addUserScript(WKUserScript(
            source: geolocationBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // ── Biometric bridge (Face ID / Touch ID) ────────
        // Exposes window.CrewBossAuth to every page.
        // Handler is BiometricBridge.shared, not the coordinator,
        // so AppCoordinator.swift needs no changes.
        ctrl.add(BiometricBridge.shared, name: "biometricRequest")
        ctrl.addUserScript(WKUserScript(
            source: biometricBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // ── APNs token bridge ────────────────────────────
        let savedToken = UserDefaults.standard.string(forKey: "apns_device_token") ?? ""
        let tokenBridgeJS = """
        (function () {
            window.__apns_device_token = "\(savedToken)";
            window.__apns_api_url      = "\(API_GATEWAY_URL)";

            window.CrewBoss = {
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
        ctrl.addUserScript(WKUserScript(
            source: tokenBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // ── setUserId handler ────────────────────────────
        ctrl.add(context.coordinator, name: "setUserId")

        // ── Xcode console bridge (DEBUG only) ────────────
        // Shipping this in Release leaks page internals into the
        // system log and adds a message hop on every console call.
        #if DEBUG
        ctrl.add(context.coordinator, name: "xcodelogdebug")
        ctrl.addUserScript(WKUserScript(
            source: """
            (function () {
                var _log  = console.log.bind(console);
                var _warn = console.warn.bind(console);
                console.log = function () {
                    var msg = Array.from(arguments).join(' ');
                    window.webkit.messageHandlers.xcodelogdebug.postMessage(msg);
                    _log.apply(console, arguments);
                };
                console.warn = function () {
                    var msg = '[WARN] ' + Array.from(arguments).join(' ');
                    window.webkit.messageHandlers.xcodelogdebug.postMessage(msg);
                    _warn.apply(console, arguments);
                };
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        #endif

        // ── Disable pinch-to-zoom ────────────────────────
        ctrl.addUserScript(WKUserScript(
            source: """
            var meta = document.querySelector('meta[name=viewport]');
            if (meta) {
                meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
            }
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        // ── IAP bridge ───────────────────────────────────
        ctrl.add(context.coordinator, name: "iapRequest")
        ctrl.addUserScript(WKUserScript(
            source: iapBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // ── Build the web view ───────────────────────────
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate         = context.coordinator
        webView.allowsBackForwardNavigationGestures = false

        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        context.coordinator.register(webView: webView, homeURL: url)
        BiometricBridge.shared.attach(webView)

        // ── Load with offline fallback ───────────────────
        loadWithOfflineFallback(webView: webView, url: url)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // ── Offline loading strategy ─────────────────────────
    private func loadWithOfflineFallback(webView: WKWebView, url: URL) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 10

        if !NetworkMonitor.shared.isConnected {
            request.cachePolicy = .returnCacheDataDontLoad
        }

        webView.load(request)
    }

    // ── Geolocation bridge JS ────────────────────────────
    private let geolocationBridgeJS = """
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

    // ── IAP bridge JS ────────────────────────────────────
    private let iapBridgeJS = """
    (function () {
        window.CrewBossIAP = {
            getProducts: function () {
                window.webkit.messageHandlers.iapRequest.postMessage({
                    action: 'getProducts'
                });
            },
            purchase: function (productId) {
                window.webkit.messageHandlers.iapRequest.postMessage({
                    action: 'purchase',
                    productId: productId
                });
            },
            restore: function () {
                window.webkit.messageHandlers.iapRequest.postMessage({
                    action: 'restore'
                });
            }
        };
    })();
    """
}

// ═══════════════════════════════════════════════════════
//  Network connectivity monitor
// ═══════════════════════════════════════════════════════
import Network

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published var isConnected = true

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "NetworkMonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }
}
