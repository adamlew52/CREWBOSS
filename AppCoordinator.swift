import WebKit
import CoreLocation
import PhotosUI
import UIKit
import StoreKit

// ═══════════════════════════════════════════════════════
//  AppCoordinator
//  Handles: WKWebView delegation, location, camera,
//  file uploads, downloads, APNs registration via
//  setUserId, IAP via StoreKit 2, and JS evaluation.
// ═══════════════════════════════════════════════════════

final class AppCoordinator: NSObject, ObservableObject {

    private var webViews: [WKWebView] = []
    private let locationManager = CLLocationManager()
    private weak var locationRequester: WKWebView?
    private var fileUploadCompletion: (([URL]?) -> Void)?
    private var homeURLs: [WKWebView: URL] = [:]
    private var lastDownloadURL: URL?

    // ── IAP ──────────────────────────────────────────
    // Product IDs — configure these in App Store Connect
    static let iapProductIDs: Set<String> = [
        "com.sensaro.crewboss.monthly",
        "com.sensaro.crewboss.yearly",
    ]

    override init() {
        super.init()
        locationManager.delegate        = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func register(webView: WKWebView, homeURL: URL) {
        if !webViews.contains(webView) {
            webViews.append(webView)
            homeURLs[webView] = homeURL
        }
    }

    /// Run JS on the first (only) web view — used by ContentView for push nav
    func evaluateInFirstWebView(_ js: String) {
        webViews.first?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKNavigationDelegate
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKNavigationDelegate {

    /// Offline fallback: show a retry page instead of a blank screen
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation _: WKNavigation!,
                 withError error: Error) {
        let nsError = error as NSError
        // Only show offline page for network errors, not cancellations
        guard nsError.domain == NSURLErrorDomain else { return }

        let homeURL = homeURLs[webView]?.absoluteString ?? ""
        let html = """
        <!DOCTYPE html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
            body{background:#0e1a10;color:#dce6cf;font-family:-apple-system,sans-serif;
                 display:flex;flex-direction:column;align-items:center;justify-content:center;
                 min-height:100vh;margin:0;padding:2rem;text-align:center}
            h2{font-size:1.3rem;margin-bottom:0.5rem;color:#d4952a}
            p{font-size:0.9rem;opacity:0.7;margin-bottom:1.5rem;max-width:300px;line-height:1.5}
            button{background:#3d7a48;color:#dce6cf;border:none;padding:0.8rem 2rem;
                   border-radius:8px;font-size:1rem;font-weight:600;cursor:pointer}
        </style></head><body>
            <h2>No connection</h2>
            <p>CREWBOSS needs internet to load. Check your signal and try again.</p>
            <button onclick="window.location.href='\(homeURL)'">Retry</button>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView,
                 didFail _: WKNavigation!,
                 withError error: Error) {
        print("[Nav] didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKDownloadDelegate
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKDownloadDelegate {

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(suggestedFilename)
        lastDownloadURL = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = lastDownloadURL else { return }
        DispatchQueue.main.async { [weak self] in
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let pop = share.popoverPresentationController {
                pop.sourceView = self?.topVC()?.view
                pop.permittedArrowDirections = []
                pop.sourceRect = CGRect(x: UIScreen.main.bounds.midX,
                                        y: UIScreen.main.bounds.midY,
                                        width: 0, height: 0)
            }
            self?.topVC()?.present(share, animated: true)
        }
    }

    func download(_ download: WKDownload,
                  didFailWithError error: Error,
                  resumeData: Data?) {
        print("[Download] failed: \(error.localizedDescription)")
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKUIDelegate  (file picking + JS dialogs)
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame _: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {

        self.fileUploadCompletion = completionHandler
        let sheet = UIAlertController(title: "Add Photo", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Take Photo with Camera", style: .default) { [weak self] _ in
            self?.presentCamera()
        })
        sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
            self?.presentPhotoLibrary()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.fileUploadCompletion?(nil)
            self?.fileUploadCompletion = nil
        })
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topVC()?.present(sheet, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame _: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        topVC()?.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame _: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        topVC()?.present(alert, animated: true)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKScriptMessageHandler
// Handles: locationRequest, setUserId, iapRequest, xcodelogdebug
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {

        case "locationRequest":
            locationRequester = message.webView
            switch locationManager.authorizationStatus {
            case .notDetermined:        locationManager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse,
                 .authorizedAlways:     locationManager.requestLocation()
            case .denied, .restricted:  respondWithLocationError(code: 1, message: "Location access denied.")
            @unknown default:           break
            }

        case "setUserId":
            // Called by dashboard.html's registerApnsToken():
            //   window.webkit.messageHandlers.setUserId.postMessage(email)
            guard let email = message.body as? String, !email.isEmpty else { return }
            let token = UserDefaults.standard.string(forKey: "apns_device_token") ?? ""
            guard !token.isEmpty else {
                print("[APNs] No device token stored yet — skipping registration for \(email)")
                return
            }
            // Register the device token + user email with the backend
            registerDeviceWithBackend(email: email, deviceToken: token)

        case "iapRequest":
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            handleIAPRequest(action: action, body: body, webView: message.webView)

        case "xcodelogdebug":
            if let msg = message.body as? String { print("[WebView] \(msg)") }

        default:
            break
        }
    }

    // ── APNs backend registration ────────────────────
    private func registerDeviceWithBackend(email: String, deviceToken: String) {
        guard let url = URL(string: "\(apiGatewayURL)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action":       "register",
            "user_id":      email,
            "device_token": deviceToken,
        ])
        URLSession.shared.dataTask(with: request) { _, resp, err in
            if let err { print("[APNs] Registration failed: \(err.localizedDescription)"); return }
            if let http = resp as? HTTPURLResponse {
                print("[APNs] Registration status: \(http.statusCode) for \(email)")
            }
        }.resume()
    }

    private var apiGatewayURL: String {
        "https://y25m8puewi.execute-api.us-west-1.amazonaws.com/prod/notify"
    }

    private func respondWithLocationError(code: Int, message: String) {
        let safe = message.replacingOccurrences(of: "'", with: "\\'")
        locationRequester?.evaluateJavaScript("window.__geo_fail(\(code), '\(safe)');", completionHandler: nil)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – IAP (StoreKit 2)
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator {

    private func handleIAPRequest(action: String, body: [String: Any], webView: WKWebView?) {
        switch action {

        case "getProducts":
            Task {
                do {
                    let products = try await Product.products(for: Self.iapProductIDs)
                    let json = products.map { p in
                        [
                            "id":          p.id,
                            "displayName": p.displayName,
                            "description": p.description,
                            "price":       "\(p.price)",
                            "currency":    p.priceFormatStyle.currencyCode ?? "USD",
                        ]
                    }
                    let data = try JSONSerialization.data(withJSONObject: json)
                    let jsonStr = String(data: data, encoding: .utf8) ?? "[]"
                    await MainActor.run {
                        webView?.evaluateJavaScript("""
                            window.dispatchEvent(new CustomEvent('iap-products', {detail: \(jsonStr)}));
                        """)
                    }
                } catch {
                    await MainActor.run {
                        webView?.evaluateJavaScript("""
                            window.dispatchEvent(new CustomEvent('iap-error', {detail: {message: '\(error.localizedDescription)'}}));
                        """)
                    }
                }
            }

        case "purchase":
            guard let productId = body["productId"] as? String else { return }
            Task {
                do {
                    let products = try await Product.products(for: [productId])
                    guard let product = products.first else { return }
                    let result = try await product.purchase()
                    switch result {
                    case .success(let verification):
                        let transaction = try checkVerified(verification)
                        await transaction.finish()
                        await MainActor.run {
                            webView?.evaluateJavaScript("""
                                window.dispatchEvent(new CustomEvent('iap-purchased', {detail: {
                                    productId: '\(productId)',
                                    transactionId: '\(transaction.id)'
                                }}));
                            """)
                        }
                    case .pending:
                        await MainActor.run {
                            webView?.evaluateJavaScript("""
                                window.dispatchEvent(new CustomEvent('iap-error', {detail: {message: 'Purchase pending approval'}}));
                            """)
                        }
                    case .userCancelled:
                        break
                    @unknown default:
                        break
                    }
                } catch {
                    await MainActor.run {
                        webView?.evaluateJavaScript("""
                            window.dispatchEvent(new CustomEvent('iap-error', {detail: {message: '\(error.localizedDescription)'}}));
                        """)
                    }
                }
            }

        case "restore":
            Task {
                do {
                    try await AppStore.sync()
                    var active: [[String: String]] = []
                    for await result in Transaction.currentEntitlements {
                        if let tx = try? checkVerified(result) {
                            active.append([
                                "productId":     tx.productID,
                                "transactionId": "\(tx.id)",
                            ])
                        }
                    }
                    let data = try JSONSerialization.data(withJSONObject: active)
                    let jsonStr = String(data: data, encoding: .utf8) ?? "[]"
                    await MainActor.run {
                        webView?.evaluateJavaScript("""
                            window.dispatchEvent(new CustomEvent('iap-restored', {detail: \(jsonStr)}));
                        """)
                    }
                } catch {
                    await MainActor.run {
                        webView?.evaluateJavaScript("""
                            window.dispatchEvent(new CustomEvent('iap-error', {detail: {message: '\(error.localizedDescription)'}}));
                        """)
                    }
                }
            }

        default:
            break
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):   return value
        case .unverified(_, let err): throw err
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – CLLocationManagerDelegate
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if locationRequester != nil { manager.requestLocation() }
        case .denied, .restricted:
            respondWithLocationError(code: 1, message: "Location permission denied.")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        locationRequester?.evaluateJavaScript(
            "window.__geo_respond(\(loc.coordinate.latitude), \(loc.coordinate.longitude), \(loc.horizontalAccuracy));",
            completionHandler: nil
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        respondWithLocationError(code: 2, message: error.localizedDescription)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – Camera
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator {
    func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            presentPhotoLibrary(); return
        }
        let picker = UIImagePickerController()
        picker.sourceType        = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing     = false
        picker.delegate          = self
        topVC()?.present(picker, animated: true)
    }
}

extension AppCoordinator: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data  = image.jpegData(compressionQuality: 0.85) else {
            fileUploadCompletion?(nil); fileUploadCompletion = nil; return
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload_\(UUID().uuidString).jpg")
        try? data.write(to: dest)
        fileUploadCompletion?([dest])
        fileUploadCompletion = nil
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        fileUploadCompletion?(nil)
        fileUploadCompletion = nil
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – Photo Library
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: PHPickerViewControllerDelegate {

    func presentPhotoLibrary() {
        var config            = PHPickerConfiguration(photoLibrary: .shared())
        config.filter         = .images
        config.selectionLimit = 1
        let picker            = PHPickerViewController(configuration: config)
        picker.delegate       = self
        topVC()?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let result = results.first else {
            fileUploadCompletion?(nil); fileUploadCompletion = nil; return
        }
        result.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.image") { [weak self] url, _ in
            guard let url else {
                DispatchQueue.main.async { self?.fileUploadCompletion?(nil); self?.fileUploadCompletion = nil }
                return
            }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("upload_\(UUID().uuidString).\(url.pathExtension)")
            try? FileManager.default.copyItem(at: url, to: dest)
            DispatchQueue.main.async {
                self?.fileUploadCompletion?([dest])
                self?.fileUploadCompletion = nil
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – Helpers
// ─────────────────────────────────────────────────────────────────
private extension AppCoordinator {
    func topVC() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: { $0.isKeyWindow })
        else { return nil }
        var vc = window.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
