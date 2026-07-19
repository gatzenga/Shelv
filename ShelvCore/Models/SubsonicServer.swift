import Foundation
import CryptoKit

nonisolated enum ServerURLSlot: String, Codable, Sendable {
    case primary
    case secondary
}

/// The two URL spellings used by Subsonic-compatible servers. Navidrome and
/// OpenSubsonic normally accept the extensionless form, while original
/// Subsonic installations may require the historical `.view` suffix.
nonisolated enum SubsonicRESTPathStyle: Hashable, Sendable {
    case extensionless
    case viewSuffix

    func endpointPath(for method: String) -> String {
        switch self {
        case .extensionless:
            return method
        case .viewSuffix:
            return method.hasSuffix(".view") ? method : "\(method).view"
        }
    }

    var alternate: Self {
        switch self {
        case .extensionless: return .viewSuffix
        case .viewSuffix: return .extensionless
        }
    }
}

/// Request compatibility selected independently for every configured server.
/// The current Navidrome/OpenSubsonic request remains the default; fallbacks
/// are adopted only after that server rejects it.
nonisolated struct SubsonicRequestCompatibility: Hashable, Sendable {
    static let currentAPIVersion = "1.16.1"
    static let minimumTokenAPIVersion = "1.13.0"
    static let current = Self(
        pathStyle: .extensionless,
        apiVersion: currentAPIVersion
    )

    let pathStyle: SubsonicRESTPathStyle
    let apiVersion: String

    func endpointPath(for method: String) -> String {
        pathStyle.endpointPath(for: method)
    }

    func retryingAlternatePath() -> Self {
        Self(pathStyle: pathStyle.alternate, apiVersion: apiVersion)
    }

    func retrying(afterHTTPStatus statusCode: Int) -> Self? {
        statusCode == 404 ? retryingAlternatePath() : nil
    }

    func retrying(
        afterHTTPStatus statusCode: Int,
        responseData: Data,
        responseFormat: SubsonicResponseFormat = .json
    ) -> Self? {
        if let alternatePath = retrying(afterHTTPStatus: statusCode) {
            return alternatePath
        }
        let envelope: CompatibilityEnvelope?
        switch responseFormat {
        case .json:
            envelope = try? JSONDecoder().decode(
                CompatibilityEnvelope.self,
                from: responseData
            )
        case .xml:
            envelope = try? SubsonicXMLDecoder().decode(
                CompatibilityEnvelope.self,
                from: responseData
            )
        }
        guard let response = envelope?.response,
        response.status == "failed",
        let errorCode = response.error?.code else {
            return nil
        }
        return retrying(
            afterAPIErrorCode: errorCode,
            advertisedServerVersion: response.version
        )
    }

    /// Error 30 means the client advertises a newer protocol than the server.
    /// Token authentication starts at 1.13.0, which is the deliberate minimum
    /// supported by Shelv.
    func retryingOlderAPIVersion(advertisedServerVersion: String?) -> Self? {
        let target = Self.supportedVersion(from: advertisedServerVersion)
            ?? Self.minimumTokenAPIVersion
        guard target != apiVersion else { return nil }
        return Self(pathStyle: pathStyle, apiVersion: target)
    }

    /// Error 20 means a previously cached older protocol is no longer accepted.
    func retryingCurrentAPIVersion() -> Self? {
        guard apiVersion != Self.currentAPIVersion else { return nil }
        return Self(pathStyle: pathStyle, apiVersion: Self.currentAPIVersion)
    }

    func retrying(
        afterAPIErrorCode errorCode: Int,
        advertisedServerVersion: String?
    ) -> Self? {
        switch errorCode {
        case 20:
            return retryingCurrentAPIVersion()
        case 30:
            return retryingOlderAPIVersion(
                advertisedServerVersion: advertisedServerVersion
            )
        default:
            return nil
        }
    }

    private static func supportedVersion(from rawValue: String?) -> String? {
        guard let rawValue,
              let server = parsedVersion(rawValue),
              let minimum = parsedVersion(minimumTokenAPIVersion),
              let current = parsedVersion(currentAPIVersion),
              server >= minimum else {
            return nil
        }
        return server >= current ? currentAPIVersion : server.normalized
    }

    private static func parsedVersion(_ rawValue: String) -> ParsedVersion? {
        let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        let patchComponent = components.count == 3 ? components[2] : "0"
        guard (2...3).contains(components.count),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(patchComponent) else {
            return nil
        }
        return ParsedVersion(major: major, minor: minor, patch: patch)
    }

    private struct ParsedVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        var normalized: String { "\(major).\(minor).\(patch)" }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

    private struct CompatibilityEnvelope: Decodable {
        let response: CompatibilityResponse

        enum CodingKeys: String, CodingKey {
            case response = "subsonic-response"
        }
    }

    private struct CompatibilityResponse: Decodable {
        let status: String
        let version: String?
        let error: CompatibilityError?
    }

    private struct CompatibilityError: Decodable {
        let code: Int
    }
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

    /// Stable account identity for standard Subsonic servers that do not expose
    /// Navidrome's native user UUID. The password is deliberately excluded so a
    /// credential change does not detach downloads, play history, or sync data.
    var derivedStableId: String {
        Self.derivedStableId(baseURL: baseURL, username: username)
    }

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

    static func derivedStableId(baseURL: String, username: String) -> String {
        let canonicalURL = canonicalIdentityURL(baseURL)
        let canonicalUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = "\(canonicalURL)\n\(canonicalUsername)"
        let digest = SHA256.hash(data: Data(source.utf8))
        return "subsonic-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalIdentityURL(_ value: String) -> String {
        let normalized = normalizedServerURL(value)
        guard var components = URLComponents(string: normalized) else {
            return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" { path = "" }
        components.percentEncodedPath = path
        return components.string ?? normalized
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
