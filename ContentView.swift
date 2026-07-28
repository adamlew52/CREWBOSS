import SwiftUI

// ═══════════════════════════════════════════════════════
//  ContentView — Single full-screen web view
//  Points to the consolidated dashboard.html.
//  The dashboard handles its own tab bar in-page.
// ═══════════════════════════════════════════════════════

private let DASHBOARD_URL = URL(string: "https://www.sensaro.net/Mobile/Test_Server/TTTS/dashboard.html")!

struct ContentView: View {
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        ForestryWebView(url: DASHBOARD_URL, coordinator: coordinator)
            .ignoresSafeArea(.container, edges: .bottom)  // let the web CSS handle safe-area-inset-bottom
            .onReceive(NotificationCenter.default.publisher(for: .navigateToTarget)) { note in
                guard let target = note.userInfo?["target"] as? String else { return }
                // Inject JS to switch the in-page tab based on push notification payload
                coordinator.evaluateInFirstWebView("""
                    if (typeof switchView === 'function') {
                        switch('\(target)') {
                            case 'projects': switchView('v-projects'); break;
                            case 'account':  switchView('v-account');  break;
                            case 'admin':    switchView('v-admin');    break;
                            default:         switchView('v-home');     break;
                        }
                    }
                """)
            }
    }
}
