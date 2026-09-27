import CryptoKit
import Foundation

nonisolated struct LastFMAPIError: Error, Equatable, Sendable {
    let code: Int
    let message: String

    // https://www.last.fm/api/errorcodes
    static let authenticationFailed = 4
    static let invalidSessionKey = 9
    static let invalidAPIKey = 10
    static let invalidSignature = 13
    static let unauthorizedToken = 14
    static let suspendedAPIKey = 26
}

/// A scrobbled track as Last.fm reports it.
nonisolated struct LastFMTrack: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String?
}

/// Thin client for the few Last.fm web service calls Shelv needs. Every call
/// is signed, so it also works for listeners who hide their history.
nonisolated struct LastFMClient: Sendable {
    let apiKey: String
    let sharedSecret: String
    var session: URLSession = .shared

    static let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// Page where the listener grants Shelv access to their account.
    static func authorizationURL(apiKey: String, token: String, callback: String?) -> URL? {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        if let callback { items.append(URLQueryItem(name: "cb", value: callback)) }
        components?.queryItems = items
        return components?.url
    }

    /// `api_sig` as Last.fm defines it: every parameter except `format` and
    /// `callback`, sorted by name, concatenated as name + value, followed by
    /// the shared secret, MD5 hashed.
    static func signature(for parameters: [String: String], sharedSecret: String) -> String {
        let payload = parameters
            .filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + sharedSecret
        return Insecure.MD5.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Auth

    func requestToken() async throws -> String {
        let response: TokenResponse = try await call("auth.getToken")
        return response.token
    }

    func requestSession(token: String) async throws -> (username: String, sessionKey: String) {
        let response: SessionResponse = try await call("auth.getSession", ["token": token])
        return (response.session.name, response.session.key)
    }

    /// The cheapest call that proves key, secret and session are all valid.
    func authenticatedUsername(sessionKey: String) async throws -> String {
        let response: UserInfoResponse = try await call("user.getInfo", ["sk": sessionKey])
        return response.user.name
    }

    // MARK: - Listening data

    func recentTracks(
        username: String,
        sessionKey: String,
        page: Int,
        limit: Int = 200
    ) async throws -> (tracks: [LastFMTrack], totalPages: Int) {
        let response: RecentTracksResponse = try await call("user.getRecentTracks", [
            "user": username,
            "sk": sessionKey,
            "limit": String(limit),
            "page": String(page),
        ])
        let tracks = response.recenttracks.track.items
            // The track playing right now is not a finished scrobble yet.
            .filter { $0.attributes?.nowplaying != "true" }
            .map { LastFMTrack(title: $0.name, artist: $0.artist.text, album: $0.album?.text.nilIfEmpty) }
        return (tracks, Int(response.recenttracks.attributes?.totalPages ?? "") ?? 1)
    }

    func topTracks(
        username: String,
        sessionKey: String,
        page: Int,
        limit: Int = 100
    ) async throws -> (tracks: [LastFMTrack], totalPages: Int) {
        let response: TopTracksResponse = try await call("user.getTopTracks", [
            "user": username,
            "sk": sessionKey,
            "period": "overall",
            "limit": String(limit),
            "page": String(page),
        ])
        let tracks = response.toptracks.track.items
            .map { LastFMTrack(title: $0.name, artist: $0.artist.name, album: nil) }
        return (tracks, Int(response.toptracks.attributes?.totalPages ?? "") ?? 1)
    }

    // MARK: - Transport

    private func call<Response: Decodable>(
        _ method: String,
        _ extra: [String: String] = [:]
    ) async throws -> Response {
        var parameters = extra
        parameters["method"] = method
        parameters["api_key"] = apiKey
        parameters["api_sig"] = Self.signature(for: parameters, sharedSecret: sharedSecret)
        parameters["format"] = "json"

        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Shelv", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)

        // Last.fm reports failures in the body, sometimes with HTTP 200.
        if let failure = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw LastFMAPIError(code: failure.error, message: failure.message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

// MARK: - Wire format

private nonisolated struct ErrorResponse: Decodable {
    let error: Int
    let message: String
}

private nonisolated struct TokenResponse: Decodable {
    let token: String
}

private nonisolated struct SessionResponse: Decodable {
    nonisolated struct Session: Decodable {
        let name: String
        let key: String
    }
    let session: Session
}

private nonisolated struct UserInfoResponse: Decodable {
    nonisolated struct User: Decodable { let name: String }
    let user: User
}

private nonisolated struct PageAttributes: Decodable {
    let totalPages: String?
}

/// Last.fm sends a single object instead of an array when a page holds
/// exactly one item.
private nonisolated struct OneOrMany<Element: Decodable>: Decodable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let many = try? container.decode([Element].self) {
            items = many
        } else if let one = try? container.decode(Element.self) {
            items = [one]
        } else {
            items = []
        }
    }
}

private nonisolated struct TextValue: Decodable {
    let text: String
    enum CodingKeys: String, CodingKey { case text = "#text" }
}

private nonisolated struct RecentTracksResponse: Decodable {
    nonisolated struct Track: Decodable {
        nonisolated struct Attributes: Decodable { let nowplaying: String? }
        let name: String
        let artist: TextValue
        let album: TextValue?
        let attributes: Attributes?
        enum CodingKeys: String, CodingKey {
            case name, artist, album
            case attributes = "@attr"
        }
    }
    nonisolated struct Page: Decodable {
        let track: OneOrMany<Track>
        let attributes: PageAttributes?
        enum CodingKeys: String, CodingKey {
            case track
            case attributes = "@attr"
        }
    }
    let recenttracks: Page
}

private nonisolated struct TopTracksResponse: Decodable {
    nonisolated struct Track: Decodable {
        nonisolated struct Artist: Decodable { let name: String }
        let name: String
        let artist: Artist
    }
    nonisolated struct Page: Decodable {
        let track: OneOrMany<Track>
        let attributes: PageAttributes?
        enum CodingKeys: String, CodingKey {
            case track
            case attributes = "@attr"
        }
    }
    let toptracks: Page
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
