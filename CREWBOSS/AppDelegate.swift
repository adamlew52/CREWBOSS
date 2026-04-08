import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        return true
    }

    // ── Saves token so ForestryWebView can inject it into every page ──
    // Registration with your server (pairing token + user_id) happens
    // in the web JS after the user logs in — see ForestryWebView.swift.
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("APNs token: \(token)")
        UserDefaults.standard.set(token, forKey: "apns_device_token")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }

    // ── Show banner even when app is in the foreground ────────────────
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    // ── Fires when the user TAPS a notification ───────────────────────
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info   = response.notification.request.content.userInfo
        let tab    = info["tab"]    as? String ?? "wildfire"
        let target = info["target"] as? String ?? "panel-alerts"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NotificationCenter.default.post(
                name: .navigateToTarget,
                object: nil,
                userInfo: ["tab": tab, "target": target]
            )
        }
        completionHandler()
    }
}

// ── Notification name used by ContentView's onReceive ─────────────────
extension Notification.Name {
    static let navigateToTarget = Notification.Name("navigateToTarget")
}
