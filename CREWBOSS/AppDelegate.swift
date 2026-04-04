import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Request permission and register for remote notifications
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        return true
    }

    // ── Prints your device token to the Xcode console ────────────
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("APNs token: \(token)")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error)")
    }

    // ── Fires when the user TAPS a notification ───────────────────
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

// ── Notification name used by ContentView's onReceive ─────────────
extension Notification.Name {
    static let navigateToTarget = Notification.Name("navigateToTarget")
}

// ── Local test notification (delete before shipping) ──────────────
func scheduleTestNotification() {
    let content = UNMutableNotificationContent()
    content.title = "Wildfire Alert"
    content.body  = "New activity near your area."
    content.sound = .default
    content.badge = 1

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
    let request = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: trigger)
    UNUserNotificationCenter.current().add(request)
}
