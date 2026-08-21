import SwiftUI

// ═══════════════════════════════════════════════════════
//  ContentView — Single full-screen web view + lock gate
// ═══════════════════════════════════════════════════════

private let DASHBOARD_URL = URL(string: "https://www.sensaro.net/Mobile/Test_Server/TTTS/dashboard.html")!

struct ContentView: View {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var auth = BiometricAuth.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ForestryWebView(url: DASHBOARD_URL, coordinator: coordinator)
                .ignoresSafeArea(.container, edges: .bottom)
                .onReceive(NotificationCenter.default.publisher(for: .navigateToTarget)) { note in
                    guard let target = note.userInfo?["target"] as? String else { return }
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

            // Privacy shield + lock gate. Also covers the app-switcher
            // snapshot, which otherwise leaks crew data.
            if auth.isEnabled && !auth.isUnlocked {
                LockScreen(auth: auth)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auth.isUnlocked)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                auth.noteEnteredBackground()
            case .active:
                auth.noteEnteredForeground()
                if auth.isEnabled && !auth.isUnlocked {
                    Task { await auth.authenticate() }
                }
            default:
                break
            }
        }
    }
}

// ═══════════════════════════════════════════════════════
//  LockScreen
// ═══════════════════════════════════════════════════════

private struct LockScreen: View {
    @ObservedObject var auth: BiometricAuth
    @State private var failureText: String?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: iconName)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)

                Text("CREWBOSS is locked")
                    .font(.headline)

                if let failureText {
                    Text(failureText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Button {
                    Task { await unlock() }
                } label: {
                    Text("Unlock with \(auth.biometryName)")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(auth.isEvaluating)
            }
        }
        .task { await unlock() }
    }

    private var iconName: String {
        switch auth.biometryName {
        case "Face ID":  return "faceid"
        case "Touch ID": return "touchid"
        default:         return "lock.fill"
        }
    }

    private func unlock() async {
        let result = await auth.authenticate()
        if case .failure(let e) = result {
            switch e {
            case .cancelled:      failureText = nil
            case .notEnrolled:    failureText = nil
            case .unavailable(let m), .failed(let m): failureText = m
            case .noToken:        failureText = nil
            }
        } else {
            failureText = nil
        }
    }
}
