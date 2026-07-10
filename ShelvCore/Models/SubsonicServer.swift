import Foundation

nonisolated enum ServerURLSlot: String, Codable, Sendable {
    case primary
    case secondary
}

nonisolated struct SubsonicServer: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var baseURL: String
    var secondaryBaseURL: String?
    var activeURLSlot: ServerURLSlot
    var username: String
    var remoteUserId: String?

    var displayName: String {
        name.isEmpty ? baseURL : name
    }

    var stableId: String { remoteUserId ?? "" }

    var secondaryURL: String? {
        let trimmed = secondaryBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasSecondaryURL: Bool {
        secondaryURL != nil
    }

    var isUsingSecondaryURL: Bool {
        activeURLSlot == .secondary && hasSecondaryURL
    }

    var activeBaseURL: String {
        isUsingSecondaryURL ? (secondaryURL ?? baseURL) : baseURL
    }

    init(
        name: String = "",
        baseURL: String,
        username: String,
        secondaryBaseURL: String? = nil,
        activeURLSlot: ServerURLSlot = .primary
    ) {
        self.id = UUID()
        self.name = name
        self.baseURL = baseURL
        self.secondaryBaseURL = secondaryBaseURL
        self.activeURLSlot = activeURLSlot
        self.username = username
        self.remoteUserId = nil
        sanitizeURLSlots()
    }

    mutating func sanitizeURLSlots() {
        baseURL = Self.normalizedServerURL(baseURL)

        let trimmed = secondaryBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        secondaryBaseURL = trimmed.isEmpty ? nil : Self.normalizedServerURL(trimmed)
        if secondaryBaseURL == nil {
            activeURLSlot = .primary
        }
    }

    private static func normalizedServerURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !trimmed.contains("://") else { return trimmed }
        return "https://\(trimmed)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL
        case secondaryBaseURL
        case activeURLSlot
        case username
        case remoteUserId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try container.decode(String.self, forKey: .baseURL)
        secondaryBaseURL = try container.decodeIfPresent(String.self, forKey: .secondaryBaseURL)
        activeURLSlot = try container.decodeIfPresent(ServerURLSlot.self, forKey: .activeURLSlot) ?? .primary
        username = try container.decode(String.self, forKey: .username)
        remoteUserId = try container.decodeIfPresent(String.self, forKey: .remoteUserId)
        sanitizeURLSlots()
    }
}
