// WatchSessionManager.swift (iOS target)
import WatchConnectivity

class WatchSessionManager: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = WatchSessionManager()

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func sendAssignments(_ assignments: [Assignment]) {
        guard WCSession.default.isReachable else { return }
        let data = try? JSONEncoder().encode(assignments)
        WCSession.default.sendMessage(
            ["assignments": data as Any],
            replyHandler: nil
        )
    }

    // Also push via applicationContext so Watch gets it even when not reachable
    func updateContext(assignments: [Assignment], jobs: [JobPost]) {
        let aData = (try? JSONEncoder().encode(assignments)) ?? Data()
        let jData = (try? JSONEncoder().encode(jobs)) ?? Data()
        try? WCSession.default.updateApplicationContext([
            "assignments": aData,
            "jobs": jData
        ])
    }

    // Required delegate stubs
    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
