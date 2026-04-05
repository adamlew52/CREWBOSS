import WebKit
import CoreLocation
import PhotosUI
import UIKit

/// ObservableObject so ContentView can hold it with @StateObject.
/// Implements all the WKWebView delegate protocols and bridges
/// camera, photo library, geolocation, and JS dialogs to native iOS.
final class AppCoordinator: NSObject, ObservableObject {

    // ── Active WebViews ──────────────────────────────────────────
    // We track every WKWebView that registers so geolocation
    // callbacks reach the correct one.
    private var webViews: [WKWebView] = []

    // ── Location ─────────────────────────────────────────────────
    private let locationManager = CLLocationManager()
    // Which web view most recently requested location
    private weak var locationRequester: WKWebView?

    // ── File upload completion handler ───────────────────────────
    // Stored so the image-picker delegate can call it after dismissal.
    private var fileUploadCompletion: (([URL]?) -> Void)?

    override init() {
        super.init()
        locationManager.delegate        = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Called by each ForestryWebView after it creates a WKWebView.
    private var homeURLs: [WKWebView: URL] = [:]

    func register(webView: WKWebView, homeURL: URL) {
        if !webViews.contains(webView) {
            webViews.append(webView)
            homeURLs[webView] = homeURL
        }
    }

    // New — called when a tab is re-tapped
    func resetToHome(webViewIndex index: Int) {
        guard index < webViews.count else { return }
        let webView = webViews[index]
        guard let url = homeURLs[webView] else { return }
        // If we're already on the home page, just scroll to top
        if webView.url?.path == url.path {
            webView.evaluateJavaScript("window.scrollTo({top:0,behavior:'smooth'})", completionHandler: nil)
        } else {
            webView.load(URLRequest(url: url))
        }
    }}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKNavigationDelegate
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation _: WKNavigation!,
                 withError error: Error) {
        // Show a simple error page instead of a blank screen
        let html = """
        <html><body style='background:#0f1a14;color:#cfe6da;
            font-family:system-ui;padding:2rem;text-align:center;'>
            <h2>Could not load page</h2>
            <p>\(error.localizedDescription)</p>
            <p style='font-size:.85rem;opacity:.6;'>
                Make sure your device is online and BASE_URL is set correctly.</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKUIDelegate  (file picking + JS dialogs)
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKUIDelegate {

    // ── <input type="file"> handler ──────────────────────────────
    // This fires whenever your HTML form's file input is activated,
    // including when the user taps "Upload from Gallery" or
    // "Take Photo with Camera" in mpb_script.js.
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame _: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {

        self.fileUploadCompletion = completionHandler

        let sheet = UIAlertController(title: "Add Photo",
                                      message: nil,
                                      preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Take Photo with Camera",
                                      style: .default) { [weak self] _ in
            self?.presentCamera()
        })
        sheet.addAction(UIAlertAction(title: "Choose from Library",
                                      style: .default) { [weak self] _ in
            self?.presentPhotoLibrary()
        })
        sheet.addAction(UIAlertAction(title: "Cancel",
                                      style: .cancel) { [weak self] _ in
            self?.fileUploadCompletion?(nil)
            self?.fileUploadCompletion = nil
        })

        // Required for iPad — otherwise it crashes
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX,
                                        y: webView.bounds.midY,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        topVC()?.present(sheet, animated: true)
    }

    // ── JavaScript alert() ───────────────────────────────────────
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame _: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil,
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler()
        })
        topVC()?.present(alert, animated: true)
    }

    // ── JavaScript confirm() ─────────────────────────────────────
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame _: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil,
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            completionHandler(false)
        })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(true)
        })
        topVC()?.present(alert, animated: true)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKScriptMessageHandler  (receives geolocation requests)
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "locationRequest" else { return }
        // Remember which WebView asked
        locationRequester = message.webView

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            // Will continue in locationManagerDidChangeAuthorization
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            respondWithLocationError(
                code: 1,
                message: "Location access denied. Enable it in Settings → Privacy → Location."
            )
        @unknown default:
            break
        }
    }

    private func respondWithLocationError(code: Int, message: String) {
        let safeMsg = message.replacingOccurrences(of: "'", with: "\\'")
        let js = "window.__geo_fail(\(code), '\(safeMsg)');"
        locationRequester?.evaluateJavaScript(js, completionHandler: nil)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – CLLocationManagerDelegate
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // User just granted permission — fulfill the pending request
            if locationRequester != nil {
                manager.requestLocation()
            }
        case .denied, .restricted:
            respondWithLocationError(
                code: 1,
                message: "Location permission denied."
            )
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        let acc = loc.horizontalAccuracy
        let js  = "window.__geo_respond(\(lat), \(lng), \(acc));"
        locationRequester?.evaluateJavaScript(js, completionHandler: nil)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        respondWithLocationError(code: 2,
                                 message: error.localizedDescription)
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – Camera  (UIImagePickerController)
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator {

    func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // Simulator or device without camera — fall back to library
            presentPhotoLibrary()
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType       = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing    = false
        picker.delegate         = self
        topVC()?.present(picker, animated: true)
    }
}

extension AppCoordinator: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data  = image.jpegData(compressionQuality: 0.85) else {
            fileUploadCompletion?(nil)
            fileUploadCompletion = nil
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensaro_\(UUID().uuidString).jpg")
        try? data.write(to: tempURL)
        fileUploadCompletion?([tempURL])
        fileUploadCompletion = nil
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        fileUploadCompletion?(nil)
        fileUploadCompletion = nil
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – Photo Library  (PHPickerViewController, iOS 14+)
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: PHPickerViewControllerDelegate {

    func presentPhotoLibrary() {
        var config         = PHPickerConfiguration(photoLibrary: .shared())
        config.filter      = .images
        config.selectionLimit = 1
        let picker         = PHPickerViewController(configuration: config)
        picker.delegate    = self
        topVC()?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController,
                didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let result = results.first else {
            fileUploadCompletion?(nil)
            fileUploadCompletion = nil
            return
        }

        result.itemProvider.loadFileRepresentation(forTypeIdentifier: "public.image") {
            [weak self] url, error in
            guard let url else {
                DispatchQueue.main.async {
                    self?.fileUploadCompletion?(nil)
                    self?.fileUploadCompletion = nil
                }
                return
            }
            // The system-provided URL is only valid inside this closure,
            // so we copy it to a stable temp location first.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("sensaro_\(UUID().uuidString).\(url.pathExtension)")
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

    /// Returns the topmost presented view controller in the key window.
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

