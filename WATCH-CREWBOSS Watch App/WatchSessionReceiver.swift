// WatchSessionReceiver.swift (Watch target)
import WatchConnectivity

class WatchDataStore: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = WatchDataStore()
    @Published var assignments: [WatchAssignment] = []
    @Published var jobs: [WatchJobPost] = []

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        decode(from: context)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        decode(from: message)
    }

    private func decode(from dict: [String: Any]) {
        DispatchQueue.main.async {
            if let data = dict["assignments"] as? Data {
                self.assignments = (try? JSONDecoder().decode([WatchAssignment].self, from: data)) ?? []
            }
            if let data = dict["jobs"] as? Data {
                self.jobs = (try? JSONDecoder().decode([WatchJobPost].self, from: data)) ?? []
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
}
