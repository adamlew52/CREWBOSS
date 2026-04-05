import SwiftUI

private let BASE_URL = "https://www.sensaro.net/Mobile/TTTS"

// ── Small UIKit bridge that gives us UITabBarControllerDelegate ──
// SwiftUI's TabView doesn't fire onChange when the same tab is re-tapped,
// so we reach into UIKit to get that callback.
private struct TabBarReselectHandler: UIViewControllerRepresentable {
    let onReselect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onReselect: onReselect) }

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.placeholder
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Walk up to the UITabBarController and assign our delegate once it exists
        DispatchQueue.main.async {
            if let tbc = uiViewController.tabBarController,
               !(tbc.delegate is Coordinator) {
                tbc.delegate = context.coordinator
            }
        }
    }

    class Coordinator: NSObject, UITabBarControllerDelegate {
        let placeholder = UIViewController()
        let onReselect: (Int) -> Void
        private var lastSelected: Int = 0

        init(onReselect: @escaping (Int) -> Void) {
            self.onReselect = onReselect
        }

        // Fires on EVERY tap, including re-tapping the current tab
        func tabBarController(_ tbc: UITabBarController, didSelect _: UIViewController) {
            let index = tbc.selectedIndex
            if index == lastSelected {
                onReselect(index)
            }
            lastSelected = index
        }
    }
}

struct ContentView: View {
    @StateObject private var coordinator = AppCoordinator()
    @State private var selectedTab = 0

    // Individual URLs stored so ForestryWebView can pass them to register()
    private let tabURLs: [URL] = [
        URL(string: "\(BASE_URL)/jobs.html")!,
        URL(string: "\(BASE_URL)/assignments.html")!,
        URL(string: "\(BASE_URL)/user.html")!,
    ]

    var body: some View {
        TabView(selection: $selectedTab) {
            ForestryWebView(url: tabURLs[0], coordinator: coordinator)
                .ignoresSafeArea()
                .tabItem { Label("Job Posts", systemImage: "helmet") }
                .tag(0)
                // The bridge only needs to be in one tab — it walks up to
                // the shared UITabBarController from whichever tab it's in
                .background(
                    TabBarReselectHandler { index in
                        coordinator.resetToHome(webViewIndex: index)
                    }
                )

            ForestryWebView(url: tabURLs[1], coordinator: coordinator)
                .ignoresSafeArea()
                .tabItem { Label("Your Assignments", systemImage: "tray") }
                .tag(1)

            ForestryWebView(url: tabURLs[2], coordinator: coordinator)
                .ignoresSafeArea()
                .tabItem { Label("Account Dashboard", systemImage: "person") }
                .tag(2)
        }
        
        //.toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(Color.white, for: .tabBar)
        .tint(Color(red: 0.19, green: 0.44, blue: 0.31))
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTarget)) { note in
            guard let tab = note.userInfo?["tab"] as? String else { return }
            switch tab {
            case "jobs":        selectedTab = 0
            case "assignments": selectedTab = 1
            case "account":     selectedTab = 2
            default:            break
            }
        }
    }
}
