import Foundation
import LocalAuthentication
import Security
import WebKit
import Combine
import UIKit

// ═══════════════════════════════════════════════════════
//  BiometricAuth
//  • App-lock gate (Face ID / Touch ID / passcode fallback)
//  • Keychain vault with .biometryCurrentSet ACL for the
//    web session token, so dashboard.html can auto-login
//  • window.CrewBossAuth JS bridge (promise-based)
//
//  No entitlement required. Info.plist MUST contain
//  NSFaceIDUsageDescription or evaluatePolicy crashes.
// ═══════════════════════════════════════════════════════

enum BiometricFailure: Error {
    case unavailable(String)
    case cancelled
    case failed(String)
    case notEnrolled
    case noToken
}

@MainActor
final class BiometricAuth: ObservableObject {

    static let shared = BiometricAuth()

    // Re-lock policy: how long the app may sit in the background
    // before Face ID is required again on return.
    static let lockGraceSeconds: TimeInterval = 60

    @Published private(set) var isUnlocked = false
    @Published private(set) var isEvaluating = false

    /// User opt-in. Off by default so existing users aren't locked
    /// out by an update they didn't ask for.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    private var backgroundedAt: Date?

    private enum Keys {
        static let enabled  = "biometric_lock_enabled"
        static let service  = "net.sensaro.crewboss.session"
        static let account  = "web_session_token"
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        // If the feature is off, the app is effectively always unlocked.
        isUnlocked = !isEnabled
    }

    // MARK: – Capability

    /// `.faceID`, `.touchID`, `.opticID`, or `.none`.
    var biometryType: LABiometryType {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType
    }

    var biometryName: String {
        switch biometryType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:       return "Passcode"
        }
    }

    var isBiometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    // MARK: – Lock lifecycle

    func noteEnteredBackground() {
        guard isEnabled else { return }
        backgroundedAt = Date()
    }

    /// Call on foreground. Re-locks only past the grace window.
    func noteEnteredForeground() {
        guard isEnabled else { isUnlocked = true; return }
        guard let then = backgroundedAt else { return }
        if Date().timeIntervalSince(then) > Self.lockGraceSeconds {
            isUnlocked = false
        }
        backgroundedAt = nil
    }

    func lock() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    // MARK: – Authenticate

    /// Biometrics with system passcode fallback.
    @discardableResult
    func authenticate(reason: String = "Unlock CREWBOSS") async -> Result<Void, BiometricFailure> {
        guard !isEvaluating else { return .failure(.failed("Already evaluating")) }
        isEvaluating = true
        defer { isEvaluating = false }

        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Passcode"

        var err: NSError?
        // .deviceOwnerAuthentication == biometrics, falling back to passcode.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            let code = LAError.Code(rawValue: err?.code ?? -1)
            if code == .biometryNotEnrolled || code == .passcodeNotSet {
                // Nothing to authenticate against — fail open rather than
                // bricking the app for a user with no passcode set.
                isUnlocked = true
                return .failure(.notEnrolled)
            }
            isUnlocked = true
            return .failure(.unavailable(err?.localizedDescription ?? "Unavailable"))
        }

        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            isUnlocked = true
            return .success(())
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel:
                return .failure(.cancelled)
            default:
                return .failure(.failed(e.localizedDescription))
            }
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    // MARK: – Keychain token vault
    //
    // Stored with .biometryCurrentSet: the item is invalidated
    // automatically if the user adds/removes a face or fingerprint.
    // Reading it triggers the biometric prompt on its own, so
    // loadToken() IS an authentication.

    nonisolated func saveToken(_ token: String) throws {
        var acError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            &acError
        ) else {
            throw BiometricFailure.unavailable("Access control unavailable")
        }

        let base: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: Keys.account
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String]       = Data(token.utf8)
        add[kSecAttrAccessControl as String] = access

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BiometricFailure.failed("Keychain write failed (\(status))")
        }
    }

    /// Blocking Keychain read — never call on the main thread.
    nonisolated func loadTokenSync(reason: String) throws -> String {
        let ctx = LAContext()
        ctx.localizedReason = reason
        ctx.localizedFallbackTitle = "Use Passcode"

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Keys.service,
            kSecAttrAccount as String:      Keys.account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: ctx
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw BiometricFailure.failed("Corrupt token")
            }
            return token
        case errSecItemNotFound:
            throw BiometricFailure.noToken
        case errSecUserCanceled:
            throw BiometricFailure.cancelled
        default:
            throw BiometricFailure.failed("Keychain read failed (\(status))")
        }
    }

    func loadToken(reason: String = "Sign in to CREWBOSS") async throws -> String {
        try await Task.detached(priority: .userInitiated) { [self] in
            try loadTokenSync(reason: reason)
        }.value
    }

    nonisolated func clearToken() {
        SecItemDelete([
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Keys.service,
            kSecAttrAccount as String: Keys.account
        ] as CFDictionary)
    }

    nonisolated var hasStoredToken: Bool {
        let status = SecItemCopyMatching([
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Keys.service,
            kSecAttrAccount as String:      Keys.account,
            kSecReturnData as String:       false,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ] as CFDictionary, nil)
        // errSecInteractionNotAllowed means the item exists but needs auth.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }
}

// ═══════════════════════════════════════════════════════
//  BiometricBridge — WKScriptMessageHandler
//  Kept separate from AppCoordinator so no edits are
//  needed to that file. WKUserContentController retains
//  handlers strongly; singleton avoids lifetime issues.
// ═══════════════════════════════════════════════════════

final class BiometricBridge: NSObject, WKScriptMessageHandler {

    static let shared = BiometricBridge()
    private weak var webView: WKWebView?

    func attach(_ webView: WKWebView) { self.webView = webView }

    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "biometricRequest",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        let reqId = body["id"] as? String ?? ""
        let webView = message.webView

        Task { @MainActor in
            let auth = BiometricAuth.shared

            switch action {

            case "status":
                self.resolve(reqId, [
                    "available":  auth.isBiometryAvailable,
                    "biometry":   auth.biometryName,
                    "enabled":    auth.isEnabled,
                    "hasToken":   auth.hasStoredToken
                ], on: webView)

            case "unlock":
                let reason = body["reason"] as? String ?? "Unlock CREWBOSS"
                let result = await auth.authenticate(reason: reason)
                switch result {
                case .success:
                    self.resolve(reqId, ["ok": true], on: webView)
                case .failure(let e):
                    self.reject(reqId, "\(e)", on: webView)
                }

            case "saveToken":
                guard let token = body["token"] as? String, !token.isEmpty else {
                    self.reject(reqId, "missing token", on: webView); return
                }
                do {
                    try auth.saveToken(token)
                    auth.isEnabled = true
                    self.resolve(reqId, ["ok": true], on: webView)
                } catch {
                    self.reject(reqId, "\(error)", on: webView)
                }

            case "loadToken":
                let reason = body["reason"] as? String ?? "Sign in to CREWBOSS"
                do {
                    let token = try await auth.loadToken(reason: reason)
                    self.resolve(reqId, ["ok": true, "token": token], on: webView)
                } catch {
                    self.reject(reqId, "\(error)", on: webView)
                }

            case "clearToken":
                auth.clearToken()
                auth.isEnabled = false
                self.resolve(reqId, ["ok": true], on: webView)

            case "setEnabled":
                auth.isEnabled = (body["enabled"] as? Bool) ?? false
                if !auth.isEnabled { auth.clearToken() }
                self.resolve(reqId, ["ok": true, "enabled": auth.isEnabled], on: webView)

            default:
                self.reject(reqId, "unknown action", on: webView)
            }
        }
    }

    // MARK: – JS callbacks

    private func resolve(_ id: String, _ payload: [String: Any], on webView: WKWebView?) {
        emit("__cbAuthResolve", id: id, payload: payload, on: webView)
    }

    private func reject(_ id: String, _ message: String, on webView: WKWebView?) {
        emit("__cbAuthReject", id: id, payload: ["error": message], on: webView)
    }

    private func emit(_ fn: String, id: String, payload: [String: Any], on webView: WKWebView?) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let target = webView ?? self.webView
        DispatchQueue.main.async {
            target?.evaluateJavaScript("window.\(fn) && window.\(fn)('\(id)', \(json));")
        }
    }
}

// ═══════════════════════════════════════════════════════
//  Injected JS — window.CrewBossAuth
// ═══════════════════════════════════════════════════════

let biometricBridgeJS = """
(function () {
    var pending = {};
    var seq = 0;

    function call(action, extra) {
        return new Promise(function (resolve, reject) {
            var id = 'cb' + (++seq);
            pending[id] = { resolve: resolve, reject: reject };
            var msg = { action: action, id: id };
            if (extra) for (var k in extra) msg[k] = extra[k];
            try {
                window.webkit.messageHandlers.biometricRequest.postMessage(msg);
            } catch (e) {
                delete pending[id];
                reject(new Error('bridge unavailable'));
            }
        });
    }

    window.__cbAuthResolve = function (id, payload) {
        var p = pending[id];
        if (!p) return;
        delete pending[id];
        p.resolve(payload);
    };

    window.__cbAuthReject = function (id, payload) {
        var p = pending[id];
        if (!p) return;
        delete pending[id];
        p.reject(new Error((payload && payload.error) || 'auth failed'));
    };

    window.CrewBossAuth = {
        isNative:    true,
        status:      function ()            { return call('status'); },
        unlock:      function (reason)      { return call('unlock', { reason: reason }); },
        saveToken:   function (token)       { return call('saveToken', { token: token }); },
        loadToken:   function (reason)      { return call('loadToken', { reason: reason }); },
        clearToken:  function ()            { return call('clearToken'); },
        setEnabled:  function (on)          { return call('setEnabled', { enabled: !!on }); }
    };
})();
"""
