import SwiftUI

private let BASE_URL = "https://www.sensaro.net/Mobile/TTTS"

struct ContentView: View {
    // Keep one coordinator alive for the whole app lifetime
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        TabView {
            // ── Tab 1: Dashboard ──────────────────────────
            ForestryWebView(
                url: URL(string: "\(BASE_URL)/jobs.html")!,
                coordinator: coordinator
            )
            .ignoresSafeArea()
            .tabItem {
                Label("Job Posts", systemImage: "helmet")
            }

            // ── Tab 2: User Assignments ─────────────────────────
            ForestryWebView(
                url: URL(string: "\(BASE_URL)/assignments.html")!,
                coordinator: coordinator
            )
            .ignoresSafeArea()
            .tabItem {
                Label("Your Assignments", systemImage: "tray")
            }

            // ── Tab 3: Account ───────────────────
            ForestryWebView(
                url: URL(string: "\(BASE_URL)/user.html")!,
                coordinator: coordinator
            )
            .ignoresSafeArea()
            .tabItem {
                Label("Account Dashboard", systemImage: "person")
            }
            
            Button("Fire Test Notification") {
                scheduleTestNotification()
            }
            .padding()
            .tag(Tab.test)
            .tabItem { Label("Test", systemImage: "bell.fill") }
        }
        // Forest green accent to match your existing dark-green theme
        .tint(Color(red: 0.19, green: 0.44, blue: 0.31))
    }
}
