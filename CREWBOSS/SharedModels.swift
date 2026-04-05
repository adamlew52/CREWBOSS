// SharedModels.swift  (add to BOTH the iOS and Watch targets)
struct Assignment: Codable, Identifiable {
    let id: String
    let title: String
    let location: String
    let date: String
}

struct JobPost: Codable, Identifiable {
    let id: String
    let title: String
    let location: String
}
