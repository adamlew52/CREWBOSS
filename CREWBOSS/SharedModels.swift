// SharedModels.swift  (add to BOTH the iOS and Watch targets)
struct WatchAssignment: Codable, Identifiable {
    let id: String
    let title: String
    let location: String
    let date: String
}

struct WatchJobPost: Codable, Identifiable {
    let id: String
    let title: String
    let location: String
}
