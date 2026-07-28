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
//  - IAP test hooks
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

        // Use aggressive caching on the data store
        config.websiteDataStore = .default()

        // ── Geolocation bridge ───────────────────────────
        ctrl.add(context.coordinator, name: "locationRequest")
        ctrl.addUserScript(WKUserScript(
            source: geolocationBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // ── APNs token bridge ────────────────────────────
        // Exposes window.__apns_device_token and the CrewBoss
        // registration helper to every page load.
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
        // dashboard.html calls:
        //   window.webkit.messageHandlers.setUserId.postMessage(email)
        // This triggers the native APNs registration with the backend.
        ctrl.add(context.coordinator, name: "setUserId")

        // ── Xcode console bridge ─────────────────────────
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
        // Exposes window.CrewBossIAP to the web layer.
        // For now this is a test stub — calls StoreKit 2
        // to fetch products and initiate purchases.
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

        // Safe area: let the web page handle insets via env()
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        if #available(iOS 16.4, *) { webView.isInspectable = true }

        context.coordinator.register(webView: webView, homeURL: url)

        // ── Load with offline fallback ───────────────────
        loadWithOfflineFallback(webView: webView, url: url)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // ── Offline loading strategy ─────────────────────────
    // Try network first. If offline, fall back to URLCache.
    private func loadWithOfflineFallback(webView: WKWebView, url: URL) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData  // network first, cache fallback
        request.timeoutInterval = 10

        // If we know we're offline, use cache directly
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
    // Web JS can call:
    //   CrewBossIAP.getProducts()       → returns JSON array of products
    //   CrewBossIAP.purchase(productId) → initiates purchase flow
    //   CrewBossIAP.restore()           → restores previous purchases
    //
    // Results come back via window events:
    //   window.addEventListener('iap-products', e => e.detail)
    //   window.addEventListener('iap-purchased', e => e.detail)
    //   window.addEventListener('iap-error', e => e.detail)
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
