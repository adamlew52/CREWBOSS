import WebKit
import CoreLocation
import PhotosUI
import UIKit

final class AppCoordinator: NSObject, ObservableObject {

    private var webViews: [WKWebView] = []
    private let locationManager = CLLocationManager()
    private weak var locationRequester: WKWebView?
    private var fileUploadCompletion: (([URL]?) -> Void)?
    private var homeURLs: [WKWebView: URL] = [:]
    private var lastDownloadURL: URL?              // ── NEW ── tracks download destination

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

    func resetToHome(webViewIndex index: Int) {
        guard index < webViews.count else { return }
        let webView = webViews[index]
        guard let url = homeURLs[webView] else { return }
        if webView.url?.path == url.path {
            webView.evaluateJavaScript("window.scrollTo({top:0,behavior:'smooth'})", completionHandler: nil)
        } else {
            webView.load(URLRequest(url: url))
        }
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKNavigationDelegate
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation _: WKNavigation!,
                 withError error: Error) {
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

    // ── NEW ── Intercept responses that can't be displayed (e.g. image downloads)
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    // ── NEW ── Called when a navigation response becomes a download
    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    // ── NEW ── Called when a navigation action becomes a download
    //           (e.g. long-press "Download Image")
    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }
}

// ─────────────────────────────────────────────────────────────────
// MARK: – WKDownloadDelegate  ── NEW ──
// Handles press-and-hold image downloads without crashing
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
            let share = UIActivityViewController(activityItems: [url],
                                                 applicationActivities: nil)
            // Required on iPad or it crashes
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
        print("Download failed: \(error.localizedDescription)")
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

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX,
                                        y: webView.bounds.midY,
                                        width: 0, height: 0)
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
// ─────────────────────────────────────────────────────────────────
extension AppCoordinator: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "locationRequest" else { return }
        locationRequester = message.webView
        print("[WebView JS] \(message.body)")

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            respondWithLocationError(code: 1,
                message: "Location access denied. Enable it in Settings → Privacy → Location.")
        @unknown default:
            break
        }
    }

    private func respondWithLocationError(code: Int, message: String) {
        let safeMsg = message.replacingOccurrences(of: "'", with: "\\'")
        locationRequester?.evaluateJavaScript("window.__geo_fail(\(code), '\(safeMsg)');",
                                              completionHandler: nil)
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

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let js = "window.__geo_respond(\(loc.coordinate.latitude), \(loc.coordinate.longitude), \(loc.horizontalAccuracy));"
        locationRequester?.evaluateJavaScript(js, completionHandler: nil)
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
