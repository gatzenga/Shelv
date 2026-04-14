import Foundation

struct SubsonicServer: Identifiable, Codable {
    let id: UUID
    var name: String
    var baseURL: String
    var username: String

    var displayName: String {
        name.isEmpty ? baseURL : name
    }

    init(name: String, baseURL: String, username: String) {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.username = username
    }
}
