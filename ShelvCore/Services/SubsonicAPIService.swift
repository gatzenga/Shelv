import Foundation
import Combine
import CryptoKit
import Security

enum SubsonicAPIError: LocalizedError, ServerConnectivityErrorProviding {
    case noServer
    case noPassword
    case protectedDataUnavailable
    case credentialAccessFailed(OSStatus)
    case invalidURL
    case httpError(Int)
    case networkError(Error)
    case apiError(Int, String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .noServer:              return String(localized: "no_server_configured")
        case .noPassword:            return String(localized: "no_password_found")
        case .protectedDataUnavailable:
            return String(localized: "no_password_found")
        case .credentialAccessFailed:
            return String(localized: "no_password_found")
        case .invalidURL:            return String(localized: "invalid_server_url")
        case .httpError(let code):   return "\(String(localized: "server_returned_an_error")) (HTTP \(code))"
        case .networkError(let e):
            if let urlError = e as? URLError {
                switch urlError.code {
                case .timedOut:
                    return String(localized: "connection_timed_out_please_check_your_network")
                case .notConnectedToInternet:
                    return String(localized: "no_internet_connection")
                case .cannotConnectToHost, .cannotFindHost:
                    return String(localized: "server_not_reachable_please_check_the_url")
                case .networkConnectionLost:
                    return String(localized: "connection_lost_please_try_again")
                case .secureConnectionFailed:
                    return String(localized: "secure_connection_failed_please_check_the_server_certificate")
                default:
                    return String(localized: "network_error_please_try_again")
                }
            }
            return String(localized: "network_error_please_try_again")
        case .apiError(_, let m):
            return m ?? String(localized: "server_returned_an_error")
        case .decodingError:
            return String(localized: "unexpected_server_response")
        }
    }

    nonisolated var underlyingConnectivityError: Error? {
        guard case .networkError(let rootError) = self else { return nil }
        return rootError
    }
}

extension SubsonicAPIError: ShortcutRemoteErrorClassifying {
    nonisolated var shortcutPlaybackError: ShortcutPlaybackError {
        switch self {
        case .noServer:
            return .noActiveServer
        case .networkError(let error):
            if error is CancellationError { return .cancelled }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return .cancelled
            }
            return .noNetwork
        case .httpError(let code):
            return code == 404 ? .notFound : .playbackFailed
        case .apiError(let code, _):
            return code == 70 ? .notFound : .playbackFailed
        case .noPassword, .protectedDataUnavailable, .credentialAccessFailed,
             .invalidURL, .decodingError:
            return .playbackFailed
        }
    }
}

/// Ergebnis von `getPlayQueue` — die serverseitig gespeicherte Wiedergabe-Queue.
nonisolated struct SubsonicPlayQueue {
    let songs: [Song]
    let currentSongId: String?
    /// Server-Zeitstempel der letzten Änderung (ISO-String), falls geliefert.
    let changed: String?
}

/// Immutable credentials for work that must stay bound to one server even if
/// the user switches the active server while the request sequence is running.
nonisolated struct SubsonicServerRequestContext: Sendable {
    let server: SubsonicServer
    fileprivate let password: String
    fileprivate let credentialGeneration: UInt64

    var serverId: String { server.stableId }
}

private nonisolated struct Envelope<T: Decodable>: Decodable {
    let response: T

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

extension Envelope: Sendable where T: Sendable {}

private nonisolated struct StatusCheck: Decodable, Sendable {
    let status: String
    let error: APIError?

    struct APIError: Decodable, Sendable {
        let code: Int
        let message: String?
    }
}

private nonisolated struct AlbumListBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let albumList2: AlbumListContainer?
}

private nonisolated struct ArtistsBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let artists: ArtistsContainer?
}

private nonisolated struct AlbumBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let album: AlbumDetail?
}

private nonisolated struct ArtistBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let artist: ArtistDetail?
}

private nonisolated struct ArtistInfoBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let artistInfo2: ArtistInfo?
}

private nonisolated struct SearchBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let searchResult3: SearchResult?
}

private nonisolated struct SongBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let song: Song?
}

private nonisolated struct PingBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
}

private nonisolated struct PlayQueueBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let playQueue: PlayQueueDetail?

    struct PlayQueueDetail: Decodable, Sendable {
        let entry: [Song]?
        let current: String?
        let position: Int?
        let changed: String?
    }
}


private nonisolated struct PingInfoBody: Decodable, Sendable {
    let status: String
    let version: String
    let type: String?
    let serverVersion: String?
    let error: StatusCheck.APIError?
}

private nonisolated struct ScanStatusBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let scanStatus: ScanStatusDetail?

    struct ScanStatusDetail: Decodable, Sendable {
        let scanning: Bool
        let count: Int?
    }
}

nonisolated struct ServerInfo {
    let apiVersion: String
    let serverVersion: String?
    let serverType: String?
}

nonisolated struct ScanStatus {
    let scanning: Bool
    let count: Int
}

nonisolated struct AlbumListContainer: Decodable, Sendable {
    let album: [Album]?
}

nonisolated struct ArtistsContainer: Decodable, Sendable {
    let index: [ArtistIndex]?
}

nonisolated struct ArtistIndex: Decodable, Sendable {
    let name: String
    let artist: [Artist]?
}

nonisolated struct AlbumDetail: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let sortName: String?
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let starred: Date?
    let song: [Song]?

    var isStarred: Bool { starred != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, sortName, artist, artistId, coverArt, songCount, duration, year, genre, starred, song
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sortName = try c.decodeIfPresent(String.self, forKey: .sortName)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        songCount = try c.decodeIfPresent(Int.self, forKey: .songCount)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        starred = FlexibleDate.decode(c, .starred)
        song = try c.decodeIfPresent([Song].self, forKey: .song)
    }

    init(id: String, name: String, sortName: String? = nil, artist: String? = nil, artistId: String? = nil,
         coverArt: String? = nil, songCount: Int? = nil, duration: Int? = nil,
         year: Int? = nil, genre: String? = nil, starred: Date? = nil, song: [Song]? = nil) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.artist = artist
        self.artistId = artistId
        self.coverArt = coverArt
        self.songCount = songCount
        self.duration = duration
        self.year = year
        self.genre = genre
        self.starred = starred
        self.song = song
    }
}

nonisolated struct ArtistDetail: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let sortName: String?
    let albumCount: Int?
    let coverArt: String?
    let album: [Album]?

    init(
        id: String,
        name: String,
        sortName: String? = nil,
        albumCount: Int? = nil,
        coverArt: String? = nil,
        album: [Album]? = nil
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.albumCount = albumCount
        self.coverArt = coverArt
        self.album = album
    }
}

nonisolated struct ArtistInfo: Decodable, Sendable {
    let biography: String?
}

nonisolated struct SearchResult: Decodable, Sendable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

nonisolated struct StarredResult: Decodable, Sendable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

private nonisolated struct RandomSongsBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let randomSongs: RandomSongsList?
    struct RandomSongsList: Decodable, Sendable { let song: [Song]? }
}

private nonisolated struct TopSongsBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let topSongs: TopSongsList?
    struct TopSongsList: Decodable, Sendable { let song: [Song]? }
}

private nonisolated struct SimilarSongsBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let similarSongs: SimilarSongsList?
    struct SimilarSongsList: Decodable, Sendable { let song: [Song]? }
}

private nonisolated struct SimilarSongs2Body: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let similarSongs2: SimilarSongsList?
    struct SimilarSongsList: Decodable, Sendable { let song: [Song]? }
}

private nonisolated struct StarredBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let starred2: StarredResult?
}

private nonisolated struct PlaylistsBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let playlists: PlaylistsContainer?

    struct PlaylistsContainer: Decodable, Sendable {
        let playlist: [Playlist]?
    }
}

private nonisolated struct PlaylistBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let playlist: PlaylistDetail?

    struct PlaylistDetail: Decodable, Sendable {
        let id: String
        let name: String
        let comment: String?
        let songCount: Int?
        let duration: Int?
        let coverArt: String?
        let entry: [Song]?
    }
}

private nonisolated struct CreatePlaylistBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let playlist: PlaylistBody.PlaylistDetail?
}

private nonisolated struct InternetRadioStationsBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let internetRadioStations: InternetRadioStationsContainer?

    struct InternetRadioStationsContainer: Decodable, Sendable {
        let internetRadioStation: [RadioStation]?
    }
}

nonisolated class SubsonicAPIService: ObservableObject, @unchecked Sendable {
    nonisolated static let shared = SubsonicAPIService()
    nonisolated private static let requestTimeout: TimeInterval = 10

    private let credentialLock = NSLock()
    private let compatibilityLock = NSLock()
    nonisolated(unsafe) private var _activeServer: SubsonicServer?
    nonisolated(unsafe) private var _activePassword: String?
    nonisolated(unsafe) private var _credentialGeneration: UInt64 = 0
    nonisolated(unsafe) private var requestCompatibilityByServer: [String: SubsonicRequestCompatibility] = [:]

    nonisolated var activeServer: SubsonicServer? {
        get { credentialLock.withLock { _activeServer } }
        set {
            credentialLock.withLock {
                _activeServer = newValue
                _credentialGeneration &+= 1
            }
        }
    }

    nonisolated var activePassword: String? {
        get { credentialLock.withLock { _activePassword } }
        set {
            credentialLock.withLock {
                _activePassword = newValue
                _credentialGeneration &+= 1
            }
        }
    }

    nonisolated func setCredentials(server: SubsonicServer, password: String?) {
        credentialLock.withLock {
            _activeServer = server
            _activePassword = password
            _credentialGeneration &+= 1
        }
    }

    /// Captures the exact active credential epoch used by a multi-page library
    /// refresh. The monotonic epoch detects A-to-B-to-A switches as stale too.
    nonisolated func captureLibraryRequestContext(
        serverKey: String,
        stableId: String?
    ) -> LibraryAPIRequestContext? {
        credentialLock.withLock {
            guard let server = _activeServer,
                  server.id.uuidString == serverKey,
                  (server.stableId.isEmpty ? nil : server.stableId) == stableId
            else {
                return nil
            }
            return LibraryAPIRequestContext(
                serverKey: serverKey,
                stableId: stableId,
                credentialGeneration: _credentialGeneration
            )
        }
    }

    nonisolated func isLibraryRequestContextCurrent(
        _ context: LibraryAPIRequestContext
    ) -> Bool {
        credentialLock.withLock {
            guard let server = _activeServer else { return false }
            return server.id.uuidString == context.serverKey
                && (server.stableId.isEmpty ? nil : server.stableId) == context.stableId
                && _credentialGeneration == context.credentialGeneration
        }
    }

    #if DEBUG
    /// Aktiv, wenn der Demo-Server gewählt ist. Alle Daten-Methoden liefern dann
    /// `DemoContent`-Daten statt echter Netzwerk-Antworten. Siehe `DemoContent`.
    nonisolated var isDemoActive: Bool { activeServer?.baseURL == DemoContent.serverBaseURL }
    #endif

    private let clientName = "Shelv"
    private let decoder = SubsonicAPIService.makeDecoder()
    private let responseFormatPreferences = SubsonicResponseFormatPreferences.shared
    private let responseRequestGate = SubsonicResponseRequestGate()

    nonisolated private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            if let date = FlexibleDate.parseISOString(raw) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(raw)")
        }
        return d
    }

    nonisolated private static func decodeOffMain<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data,
        format: SubsonicResponseFormat = .json
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            switch format {
            case .json:
                return try makeDecoder().decode(type, from: data)
            case .xml:
                return try SubsonicXMLDecoder().decode(type, from: data)
            }
        }.value
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()

    private init() {}

    private func resolveCachedCredentials() throws -> (
        server: SubsonicServer,
        password: String
    ) {
        try credentialLock.withLock {
            guard let server = _activeServer else { throw SubsonicAPIError.noServer }
            guard let password = _activePassword else { throw SubsonicAPIError.noPassword }
            return (server, password)
        }
    }

    /// Resolves a missing credential without holding the lock while awaiting
    /// Keychain access. Generation validation prevents a late lookup for an
    /// old server from being installed after a switch or same-ID edit.
    private func resolveCredentials() async throws -> (
        server: SubsonicServer,
        password: String,
        generation: UInt64
    ) {
        await ServerStore.shared.waitUntilReady()
        try Task.checkCancellation()

        for _ in 0..<2 {
            let snapshot: (server: SubsonicServer, password: String?, generation: UInt64) =
                try credentialLock.withLock {
                    guard let server = _activeServer else {
                        throw SubsonicAPIError.noServer
                    }
                    return (server, _activePassword, _credentialGeneration)
                }
            if let password = snapshot.password {
                return (snapshot.server, password, snapshot.generation)
            }

            let lookup = await ServerStore.shared.credentialLookup(for: snapshot.server)
            try Task.checkCancellation()
            let installed = credentialLock.withLock {
                guard _credentialGeneration == snapshot.generation,
                      _activeServer?.id == snapshot.server.id else {
                    return false
                }
                if case .available(let password) = lookup {
                    _activePassword = password
                }
                return true
            }
            guard installed else { continue }

            switch lookup {
            case .available(let password):
                return (snapshot.server, password, snapshot.generation)
            case .missing:
                throw SubsonicAPIError.noPassword
            case .protectedDataUnavailable:
                throw SubsonicAPIError.protectedDataUnavailable
            case .failed(let status):
                throw SubsonicAPIError.credentialAccessFailed(status)
            }
        }
        throw CancellationError()
    }

    func resolvedActiveCredentials() async throws -> (
        server: SubsonicServer,
        password: String
    ) {
        let credentials = try await resolveCredentials()
        return (credentials.server, credentials.password)
    }

    func resolvedActiveRequestContext(
        expectedServerId: String? = nil
    ) async throws -> SubsonicServerRequestContext {
        let credentials = try await resolveCredentials()
        if let expectedServerId,
           credentials.server.stableId != expectedServerId {
            throw CancellationError()
        }
        return SubsonicServerRequestContext(
            server: credentials.server,
            password: credentials.password,
            credentialGeneration: credentials.generation
        )
    }

    private func makeAuthParams(
        server: SubsonicServer,
        password: String,
        apiVersion: String,
        responseFormat: SubsonicResponseFormat = .json
    ) -> [URLQueryItem] {
        let s = makeSalt()
        let t = makeToken(password: password, salt: s)
        return [
            URLQueryItem(name: "u", value: server.username),
            URLQueryItem(name: "t", value: t),
            URLQueryItem(name: "s", value: s),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: responseFormat.queryValue)
        ]
    }

    nonisolated private func makeSalt() -> String {
        // Kryptographisch sicherer Zufall (CSPRNG) statt randomElement(); 16 Bytes → 32 Hex-Zeichen.
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        // Fallback (sollte praktisch nie greifen): SystemRandomNumberGenerator ist auf Apple ebenfalls CSPRNG.
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }

    nonisolated private func makeToken(password: String, salt: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func authParams() throws -> [URLQueryItem] {
        let creds = try resolveCachedCredentials()
        let compatibility = requestCompatibility(for: creds.server)
        return makeAuthParams(
            server: creds.server,
            password: creds.password,
            apiVersion: compatibility.apiVersion
        )
    }

    private func buildURL(path: String, extra: [URLQueryItem] = []) throws -> URL {
        let creds = try resolveCachedCredentials()
        return try buildURL(
            for: creds.server,
            password: creds.password,
            path: path,
            extra: extra
        )
    }

    private func activeRequestSignature(
        for server: SubsonicServer,
        generation: UInt64
    ) -> String {
        "\(server.id.uuidString)|\(server.activeBaseURL)|\(generation)"
    }

    private func isCurrentActiveRequest(_ signature: String) -> Bool {
        credentialLock.withLock {
            guard let server = _activeServer else { return false }
            return activeRequestSignature(
                for: server,
                generation: _credentialGeneration
            ) == signature
        }
    }

    private func notifyServerErrorIfCurrentRequest(_ signature: String, message: String?) async {
        await MainActor.run {
            guard self.isCurrentActiveRequest(signature) else { return }
            OfflineModeService.shared.notifyServerErrorIfPresentationAllowed(message)
        }
    }

    private func presentConnectivityErrorIfCurrentRequest(_ signature: String, error: Error) async {
        await MainActor.run {
            guard self.isCurrentActiveRequest(signature) else { return }
            OfflineModeService.shared.presentConnectivityErrorIfNeeded(error)
        }
    }

    private func clearServerErrorIfCurrentRequest(_ signature: String) async {
        await MainActor.run {
            guard self.isCurrentActiveRequest(signature) else { return }
            OfflineModeService.shared.clearServerError()
        }
    }

    #if DEBUG
    private func clearServerErrorForDemoRequest() async {
        await MainActor.run {
            OfflineModeService.shared.clearServerError()
        }
    }
    #endif

    private func fetchData(
        path: String,
        extra: [URLQueryItem] = [],
        retries: Int = 0,
        responseFormat: SubsonicResponseFormat = .json,
        credentials resolvedCredentials: (
            server: SubsonicServer,
            password: String,
            generation: UInt64
        )? = nil
    ) async throws -> Data {
        let creds: (server: SubsonicServer, password: String, generation: UInt64)
        if let resolvedCredentials {
            creds = resolvedCredentials
        } else {
            creds = try await resolveCredentials()
        }
        let requestSignature = activeRequestSignature(
            for: creds.server,
            generation: creds.generation
        )
        await NetworkStatus.shared.waitUntilReady()
        if !NetworkStatus.shared.hasNetwork {
            let networkError = SubsonicAPIError.networkError(URLError(.notConnectedToInternet))
            ConnectivityDebugLog.log("request failed: \(path) -> no network")
            await presentConnectivityErrorIfCurrentRequest(requestSignature, error: networkError)
            throw networkError
        }
        var lastError: Error?
        var compatibility = requestCompatibility(for: creds.server)
        var attemptedCompatibilities: Set<SubsonicRequestCompatibility> = []

        compatibilityAttempts: while attemptedCompatibilities.insert(compatibility).inserted {
            let url = try buildURL(
                for: creds.server,
                password: creds.password,
                path: path,
                extra: extra,
                compatibility: compatibility,
                responseFormat: responseFormat
            )

            for attempt in 0...retries {
                if attempt > 0 {
                    try await Task.sleep(for: .milliseconds(500 * attempt))
                    try Task.checkCancellation()
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = Self.requestTimeout
                let startedAt = Date()
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        throw CancellationError()
                    }
                    lastError = error
                    let isRetryable = (error as? URLError).map {
                        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains($0.code)
                    } ?? false
                    if !isRetryable || attempt == retries {
                        let elapsed = Date().timeIntervalSince(startedAt)
                        ConnectivityDebugLog.log("request failed: \(path) -> \(ConnectivityDebugLog.short(error)) after \(String(format: "%.2f", elapsed))s")
                        break compatibilityAttempts
                    }
                    continue
                }

                let elapsed = Date().timeIntervalSince(startedAt)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                if let adjusted = compatibility.retrying(
                    afterHTTPStatus: statusCode,
                    responseData: data,
                    responseFormat: responseFormat
                ), !attemptedCompatibilities.contains(adjusted) {
                    compatibility = adjusted
                    continue compatibilityAttempts
                }

                guard (200...299).contains(statusCode) else {
                    let httpError = SubsonicAPIError.httpError(statusCode)
                    ConnectivityDebugLog.log("request failed: \(path) -> HTTP \(statusCode) after \(String(format: "%.2f", elapsed))s")
                    await notifyServerErrorIfCurrentRequest(requestSignature, message: httpError.localizedDescription)
                    throw httpError
                }

                rememberRequestCompatibility(compatibility, for: creds.server)
                // Server hat geantwortet -> Banner ausblenden, aber nur wenn diese Antwort
                // noch zur aktuell ausgewählten URL gehört.
                await clearServerErrorIfCurrentRequest(requestSignature)
                return data
            }
        }
        let rootError = lastError ?? URLError(.unknown)
        let networkError = SubsonicAPIError.networkError(rootError)
        await presentConnectivityErrorIfCurrentRequest(requestSignature, error: networkError)
        throw networkError
    }

    private func check(status: String, error: StatusCheck.APIError?) throws {
        if status == "failed" {
            throw SubsonicAPIError.apiError(error?.code ?? 0, error?.message)
        }
    }

    nonisolated private func authParams(
        for server: SubsonicServer,
        password: String,
        apiVersion: String,
        responseFormat: SubsonicResponseFormat = .json
    ) -> [URLQueryItem] {
        let s = makeSalt()
        let t = makeToken(password: password, salt: s)
        return [
            URLQueryItem(name: "u", value: server.username),
            URLQueryItem(name: "t", value: t),
            URLQueryItem(name: "s", value: s),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: responseFormat.queryValue)
        ]
    }

    nonisolated private func buildURL(
        for server: SubsonicServer,
        password: String,
        path: String,
        extra: [URLQueryItem] = [],
        compatibility: SubsonicRequestCompatibility? = nil,
        responseFormat: SubsonicResponseFormat = .json
    ) throws -> URL {
        let compatibility = compatibility ?? requestCompatibility(for: server)
        var base = server.activeBaseURL
        if base.hasSuffix("/") { base.removeLast() }
        let endpointPath = compatibility.endpointPath(for: path)
        guard var comps = URLComponents(string: "\(base)/rest/\(endpointPath)") else {
            throw SubsonicAPIError.invalidURL
        }
        comps.queryItems = authParams(
            for: server,
            password: password,
            apiVersion: compatibility.apiVersion,
            responseFormat: responseFormat
        ) + extra
        guard let url = comps.url else { throw SubsonicAPIError.invalidURL }
        return url
    }

    nonisolated private func compatibilityCacheKey(for server: SubsonicServer) -> String {
        "\(server.id.uuidString)|\(server.activeBaseURL)"
    }

    nonisolated private func requestCompatibility(
        for server: SubsonicServer
    ) -> SubsonicRequestCompatibility {
        compatibilityLock.withLock {
            requestCompatibilityByServer[compatibilityCacheKey(for: server)] ?? .current
        }
    }

    nonisolated private func rememberRequestCompatibility(
        _ compatibility: SubsonicRequestCompatibility,
        for server: SubsonicServer
    ) {
        compatibilityLock.withLock {
            requestCompatibilityByServer[compatibilityCacheKey(for: server)] = compatibility
        }
    }

    private func fetchData(
        for server: SubsonicServer,
        password: String,
        path: String,
        extra: [URLQueryItem] = [],
        responseFormat: SubsonicResponseFormat = .json
    ) async throws -> Data {
        await NetworkStatus.shared.waitUntilReady()
        guard NetworkStatus.shared.hasNetwork else {
            throw SubsonicAPIError.networkError(URLError(.notConnectedToInternet))
        }

        var compatibility = requestCompatibility(for: server)
        var attemptedCompatibilities: Set<SubsonicRequestCompatibility> = []

        while attemptedCompatibilities.insert(compatibility).inserted {
            let url = try buildURL(
                for: server,
                password: password,
                path: path,
                extra: extra,
                compatibility: compatibility,
                responseFormat: responseFormat
            )
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = Self.requestTimeout
                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
                if let adjusted = compatibility.retrying(
                    afterHTTPStatus: statusCode,
                    responseData: data,
                    responseFormat: responseFormat
                ), !attemptedCompatibilities.contains(adjusted) {
                    compatibility = adjusted
                    continue
                }
                guard (200...299).contains(statusCode) else {
                    throw SubsonicAPIError.httpError(statusCode)
                }
                rememberRequestCompatibility(compatibility, for: server)
                return data
            } catch let error as SubsonicAPIError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                throw SubsonicAPIError.networkError(error)
            }
        }

        throw SubsonicAPIError.apiError(0, "No compatible Subsonic request format")
    }

    private func fetchDecoded<Value: Decodable & Sendable>(
        _ type: Value.Type,
        path: String,
        extra: [URLQueryItem] = [],
        retries: Int = 0
    ) async throws -> Value {
        let credentials = try await resolveCredentials()
        return try await fetchDecoded(
            type,
            server: credentials.server,
            path: path,
            extra: extra,
            fetch: { [self] format in
                try await fetchData(
                    path: path,
                    extra: extra,
                    retries: retries,
                    responseFormat: format,
                    credentials: credentials
                )
            },
            quietFetch: { [self] format in
                try await fetchData(
                    for: credentials.server,
                    password: credentials.password,
                    path: path,
                    extra: extra,
                    responseFormat: format
                )
            }
        )
    }

    private func fetchDecoded<Value: Decodable & Sendable>(
        _ type: Value.Type,
        for server: SubsonicServer,
        password: String,
        path: String,
        extra: [URLQueryItem] = []
    ) async throws -> Value {
        try await fetchDecoded(
            type,
            server: server,
            path: path,
            extra: extra,
            fetch: { [self] format in
                try await fetchData(
                    for: server,
                    password: password,
                    path: path,
                    extra: extra,
                    responseFormat: format
                )
            },
            quietFetch: { [self] format in
                try await fetchData(
                    for: server,
                    password: password,
                    path: path,
                    extra: extra,
                    responseFormat: format
                )
            }
        )
    }

    private func fetchDecoded<Value: Decodable & Sendable>(
        _ type: Value.Type,
        server: SubsonicServer,
        path: String,
        extra: [URLQueryItem],
        fetch: @escaping @Sendable (SubsonicResponseFormat) async throws -> Data,
        quietFetch: @escaping @Sendable (SubsonicResponseFormat) async throws -> Data
    ) async throws -> Value {
        let serverKey = responseFormatServerKey(for: server)
        let selection = responseFormatPreferences.selection(
            serverKey: serverKey,
            endpoint: path
        )
        let primaryFormat = selection.preferredFormat
        let requestKey = responseRequestKey(
            serverKey: serverKey,
            path: path,
            extra: extra
        )

        let result: SubsonicResponseNegotiationResult<Value>
        do {
            result = try await SubsonicResponseNegotiator.load(
                primaryFormat: primaryFormat,
                fallbackFormat: selection.fallbackFormat,
                fetch: { [responseRequestGate] format in
                    guard format != primaryFormat else {
                        return try await fetch(format)
                    }
                    return try await responseRequestGate.data(
                        for: "\(requestKey)|\(format.rawValue)"
                    ) {
                        try await fetch(format)
                    }
                },
                decode: { data, format in
                    try await Self.decodeOffMain(type, from: data, format: format)
                }
            )
        } catch let failure as SubsonicResponseDecodingFailure {
            if failure.fallbackFormat == .xml {
                responseFormatPreferences.recordXMLFailure(
                    serverKey: serverKey,
                    endpoint: path
                )
            }
            throw SubsonicAPIError.decodingError(failure)
        }

        switch (primaryFormat, result.format) {
        case (.json, .json):
            // A normal JSON response must not erase an XML decision learned
            // concurrently from another request to the same endpoint.
            break
        case (.xml, .json):
            responseFormatPreferences.recordJSONSuccess(
                serverKey: serverKey,
                endpoint: path
            )
        case (.json, .xml):
            responseFormatPreferences.recordXMLSuccess(
                serverKey: serverKey,
                endpoint: path
            )
        case (.xml, .xml):
            if case .xml(let shouldReprobeJSON) = selection,
               shouldReprobeJSON {
                scheduleJSONReprobe(
                    type,
                    serverKey: serverKey,
                    path: path,
                    fetch: quietFetch
                )
            }
        }
        return result.value
    }

    private func scheduleJSONReprobe<Value: Decodable & Sendable>(
        _ type: Value.Type,
        serverKey: String,
        path: String,
        fetch: @escaping @Sendable (SubsonicResponseFormat) async throws -> Data
    ) {
        guard responseFormatPreferences.claimJSONReprobe(
            serverKey: serverKey,
            endpoint: path
        ) else { return }

        Task(priority: .utility) { [responseFormatPreferences] in
            do {
                let data = try await fetch(.json)
                do {
                    _ = try await Self.decodeOffMain(type, from: data, format: .json)
                    responseFormatPreferences.finishJSONReprobe(
                        serverKey: serverKey,
                        endpoint: path,
                        decodedSuccessfully: true,
                        receivedResponse: true
                    )
                } catch {
                    responseFormatPreferences.finishJSONReprobe(
                        serverKey: serverKey,
                        endpoint: path,
                        decodedSuccessfully: false,
                        receivedResponse: true
                    )
                }
            } catch {
                responseFormatPreferences.finishJSONReprobe(
                    serverKey: serverKey,
                    endpoint: path,
                    decodedSuccessfully: false,
                    receivedResponse: false
                )
            }
        }
    }

    nonisolated private func responseFormatServerKey(for server: SubsonicServer) -> String {
        "\(server.id.uuidString)|\(server.activeBaseURL)|\(server.username)"
    }

    nonisolated private func responseFormatServerFingerprint(_ info: ServerInfo) -> String {
        [info.apiVersion, info.serverType, info.serverVersion]
            .compactMap { value in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: "|")
    }

    nonisolated private func responseRequestKey(
        serverKey: String,
        path: String,
        extra: [URLQueryItem]
    ) -> String {
        let query = extra.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(serverKey)|\(path)|\(query)"
    }

    func ping() async throws {
        #if DEBUG
        if isDemoActive {
            await clearServerErrorForDemoRequest()
            return
        }
        #endif
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "ping"
        ).response
        try check(status: body.status, error: body.error)
    }

    @discardableResult
    func ping(server: SubsonicServer, password: String) async throws -> ServerInfo {
        #if DEBUG
        if server.baseURL == DemoContent.serverBaseURL || server.activeBaseURL == DemoContent.serverBaseURL {
            return ServerInfo(
                apiVersion: SubsonicRequestCompatibility.currentAPIVersion,
                serverVersion: "Shelv Demo",
                serverType: "demo"
            )
        }
        #endif
        let body = try await fetchDecoded(
            Envelope<PingInfoBody>.self,
            for: server,
            password: password,
            path: "ping"
        ).response
        try check(status: body.status, error: body.error)
        let info = ServerInfo(
            apiVersion: body.version,
            serverVersion: body.serverVersion,
            serverType: body.type
        )
        responseFormatPreferences.noteServerFingerprint(
            responseFormatServerFingerprint(info),
            serverKey: responseFormatServerKey(for: server)
        )
        return info
    }

    func startScan(server: SubsonicServer, password: String) async throws {
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            for: server,
            password: password,
            path: "startScan"
        ).response
        try check(status: body.status, error: body.error)
    }

    func getScanStatus(server: SubsonicServer, password: String) async throws -> ScanStatus {
        let body = try await fetchDecoded(
            Envelope<ScanStatusBody>.self,
            for: server,
            password: password,
            path: "getScanStatus"
        ).response
        try check(status: body.status, error: body.error)
        let detail = body.scanStatus
        return ScanStatus(scanning: detail?.scanning ?? false, count: detail?.count ?? 0)
    }

    func getAlbumList(type: String, size: Int = 20, offset: Int = 0) async throws -> [Album] {
        #if DEBUG
        if isDemoActive { return offset > 0 ? [] : DemoContent.albumList(type: type) }
        #endif
        let body = try await fetchDecoded(Envelope<AlbumListBody>.self, path: "getAlbumList2", extra: [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "size", value: "\(size)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]).response
        try check(status: body.status, error: body.error)
        return body.albumList2?.album ?? []
    }

    func getRecentlyAdded(size: Int = 20) async throws -> [Album] {
        try await getAlbumList(type: "newest", size: size)
    }

    func getRecentlyPlayed(size: Int = 20) async throws -> [Album] {
        try await getAlbumList(type: "recent", size: size)
    }

    func getFrequentlyPlayed(size: Int = 20) async throws -> [Album] {
        try await getAlbumList(type: "frequent", size: size)
    }

    func getAllArtists() async throws -> [Artist] {
        #if DEBUG
        if isDemoActive { return DemoContent.artists }
        #endif
        let body = try await fetchDecoded(
            Envelope<ArtistsBody>.self,
            path: "getArtists"
        ).response
        try check(status: body.status, error: body.error)
        let indices = body.artists?.index ?? []
        return indices.flatMap { $0.artist ?? [] }
    }

    func getAlbum(id: String, retries: Int = 0) async throws -> AlbumDetail {
        #if DEBUG
        if isDemoActive {
            guard let d = DemoContent.albumDetail(id: id) else { throw SubsonicAPIError.apiError(0, "Album not found") }
            return d
        }
        #endif
        let body = try await fetchDecoded(Envelope<AlbumBody>.self, path: "getAlbum", extra: [
            URLQueryItem(name: "id", value: id)
        ], retries: retries).response
        try check(status: body.status, error: body.error)
        guard let album = body.album else { throw SubsonicAPIError.apiError(0, "Album not found") }
        return album
    }

    func getArtist(id: String, retries: Int = 0) async throws -> ArtistDetail {
        #if DEBUG
        if isDemoActive {
            guard let d = DemoContent.artistDetail(id: id) else { throw SubsonicAPIError.apiError(0, "Artist not found") }
            return d
        }
        #endif
        let body = try await fetchDecoded(Envelope<ArtistBody>.self, path: "getArtist", extra: [
            URLQueryItem(name: "id", value: id)
        ], retries: retries).response
        try check(status: body.status, error: body.error)
        guard let artist = body.artist else { throw SubsonicAPIError.apiError(0, "Artist not found") }
        return artist
    }

    func getArtistInfo(id: String) async throws -> ArtistInfo {
        #if DEBUG
        if isDemoActive { return ArtistInfo(biography: nil) }
        #endif
        let body = try await fetchDecoded(Envelope<ArtistInfoBody>.self, path: "getArtistInfo2", extra: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: "0")
        ]).response
        try check(status: body.status, error: body.error)
        return body.artistInfo2 ?? ArtistInfo(biography: nil)
    }

    func getSong(id: String, retries: Int = 0) async throws -> Song {
        let body = try await fetchDecoded(Envelope<SongBody>.self, path: "getSong", extra: [
            URLQueryItem(name: "id", value: id)
        ], retries: retries).response
        try check(status: body.status, error: body.error)
        guard let song = body.song else { throw SubsonicAPIError.apiError(0, "Song not found") }
        return song
    }

    func getSong(id: String, context: SubsonicServerRequestContext) async throws -> Song {
        let body = try await fetchDecoded(
            Envelope<SongBody>.self,
            for: context.server,
            password: context.password,
            path: "getSong",
            extra: [URLQueryItem(name: "id", value: id)]
        ).response
        try check(status: body.status, error: body.error)
        guard let song = body.song else { throw SubsonicAPIError.apiError(0, "Song not found") }
        return song
    }

    func getSongsOrdered(ids: [String]) async throws -> [Song] {
        let indexed = Array(ids.enumerated())
        let pairs = await withTaskGroup(of: (Int, Song?).self) { group in
            for (i, id) in indexed {
                group.addTask { (i, try? await self.getSong(id: id)) }
            }
            var result: [(Int, Song)] = []
            for await (i, song) in group {
                if let song { result.append((i, song)) }
            }
            return result
        }
        return pairs.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func search(query: String) async throws -> SearchResult {
        #if DEBUG
        if isDemoActive { return DemoContent.search(query: query) }
        #endif
        let body = try await fetchDecoded(Envelope<SearchBody>.self, path: "search3", extra: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: "10"),
            URLQueryItem(name: "albumCount", value: "10"),
            URLQueryItem(name: "songCount", value: "20")
        ]).response
        try check(status: body.status, error: body.error)
        return body.searchResult3 ?? SearchResult(artist: nil, album: nil, song: nil)
    }

    func getNewestSongs(albumCount: Int = 10) async throws -> [Song] {
        try await fetchSongsFromAlbums(type: "newest", albumCount: albumCount)
    }

    func getFrequentSongs(albumCount: Int = 30, limit: Int = 100) async throws -> [Song] {
        let albums = try await getAlbumList(type: "frequent", size: albumCount)
        let allSongs = try await withThrowingTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask { (try await self.getAlbum(id: album.id)).song ?? [] }
            }
            var songs: [Song] = []
            for try await albumSongs in group { songs.append(contentsOf: albumSongs) }
            return songs
        }
        return Array(allSongs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(limit))
    }

    func getRandomSongs(
        size: Int = 500,
        genre: String? = nil,
        retries: Int = 0
    ) async throws -> [Song] {
        var extra = [URLQueryItem(name: "size", value: "\(size)")]
        if let g = genre { extra.append(URLQueryItem(name: "genre", value: g)) }
        let body = try await fetchDecoded(
            Envelope<RandomSongsBody>.self,
            path: "getRandomSongs",
            extra: extra,
            retries: retries
        ).response
        try check(status: body.status, error: body.error)
        return body.randomSongs?.song ?? []
    }

    func getRecentSongs(albumCount: Int = 30, limit: Int = 100) async throws -> [Song] {
        let albums = try await getAlbumList(type: "recent", size: albumCount)
        let indexed = Array(albums.enumerated())
        let songsByIndex = try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
            for (i, album) in indexed {
                group.addTask { (i, (try await self.getAlbum(id: album.id)).song ?? []) }
            }
            var result: [(Int, [Song])] = []
            for try await pair in group { result.append(pair) }
            return result
        }
        let ordered = songsByIndex.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        return Array(ordered.prefix(limit))
    }

    private func fetchSongsFromAlbums(type: String, albumCount: Int) async throws -> [Song] {
        let albums = try await getAlbumList(type: type, size: albumCount)
        return try await withThrowingTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask { (try await self.getAlbum(id: album.id)).song ?? [] }
            }
            var songs: [Song] = []
            for try await albumSongs in group { songs.append(contentsOf: albumSongs) }
            return songs
        }
    }

    func scrobble(songId: String, submission: Bool = true, playedAt: Double? = nil) async throws {
        #if DEBUG
        if isDemoActive { return }
        #endif
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "scrobble",
            extra: scrobbleQueryItems(
                songId: songId,
                submission: submission,
                playedAt: playedAt
            )
        ).response
        try check(status: body.status, error: body.error)
    }

    /// Servergebundene Variante für die persistente Outbox. Sie verwendet nicht
    /// den global aktiven Server und kann deshalb auch nach einem Serverwechsel
    /// niemals einen alten Play an die falsche Instanz senden.
    func scrobble(
        songId: String,
        submission: Bool = true,
        playedAt: Double? = nil,
        server: SubsonicServer,
        password: String
    ) async throws {
        #if DEBUG
        if server.baseURL == DemoContent.serverBaseURL || server.activeBaseURL == DemoContent.serverBaseURL {
            return
        }
        #endif
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            for: server,
            password: password,
            path: "scrobble",
            extra: scrobbleQueryItems(songId: songId, submission: submission, playedAt: playedAt)
        ).response
        try check(status: body.status, error: body.error)
    }

    private func scrobbleQueryItems(
        songId: String,
        submission: Bool,
        playedAt: Double?
    ) -> [URLQueryItem] {
        var extra = [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "submission", value: submission ? "true" : "false")
        ]
        if let ts = playedAt {
            // Subsonic erwartet Millisekunden seit Epoch
            extra.append(URLQueryItem(name: "time", value: String(Int64(ts * 1000))))
        }
        return extra
    }

    /// Speichert die Wiedergabe-Queue serverseitig (`savePlayQueue`).
    /// - Parameter songIds: Reihenfolge der Songs. Leer = gespeicherte Queue löschen.
    /// - Parameter current: ID des aktuellen Songs (nur relevant, wenn `songIds` nicht leer).
    /// - Parameter positionMs: Position im aktuellen Song in Millisekunden.
    func savePlayQueue(songIds: [String], current: String?, positionMs: Int) async throws {
        #if DEBUG
        if isDemoActive { return }
        #endif
        var extra = songIds.map { URLQueryItem(name: "id", value: $0) }
        if !songIds.isEmpty {
            if let current { extra.append(URLQueryItem(name: "current", value: current)) }
            extra.append(URLQueryItem(name: "position", value: String(positionMs)))
        }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "savePlayQueue",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    func savePlayQueue(
        songIds: [String],
        current: String?,
        positionMs: Int,
        context: SubsonicServerRequestContext
    ) async throws {
        #if DEBUG
        if context.server.baseURL == DemoContent.serverBaseURL
            || context.server.activeBaseURL == DemoContent.serverBaseURL {
            return
        }
        #endif
        var extra = songIds.map { URLQueryItem(name: "id", value: $0) }
        if !songIds.isEmpty {
            if let current { extra.append(URLQueryItem(name: "current", value: current)) }
            extra.append(URLQueryItem(name: "position", value: String(positionMs)))
        }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            for: context.server,
            password: context.password,
            path: "savePlayQueue",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    /// Liest die serverseitig gespeicherte Wiedergabe-Queue (`getPlayQueue`).
    /// Liefert `nil`, wenn keine Queue gespeichert ist.
    func getPlayQueue() async throws -> SubsonicPlayQueue? {
        #if DEBUG
        if isDemoActive { return nil }
        #endif
        let body = try await fetchDecoded(
            Envelope<PlayQueueBody>.self,
            path: "getPlayQueue"
        ).response
        try check(status: body.status, error: body.error)
        guard let q = body.playQueue, let entries = q.entry, !entries.isEmpty else { return nil }
        return SubsonicPlayQueue(
            songs: entries,
            currentSongId: q.current,
            changed: q.changed
        )
    }

    /// Ähnliche Songs zu einer Song-ID.
    func getSimilarSongs(id: String, count: Int = 50, retries: Int = 0) async throws -> [Song] {
        let body = try await fetchDecoded(Envelope<SimilarSongsBody>.self, path: "getSimilarSongs", extra: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: "\(count)")
        ], retries: retries).response
        try check(status: body.status, error: body.error)
        return body.similarSongs?.song ?? []
    }

    /// Ähnliche Songs über die ID3/OpenSubsonic-Variante, typischerweise für Artist-IDs.
    func getSimilarSongs2(id: String, count: Int = 50, retries: Int = 0) async throws -> [Song] {
        let body = try await fetchDecoded(Envelope<SimilarSongs2Body>.self, path: "getSimilarSongs2", extra: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: "\(count)")
        ], retries: retries).response
        try check(status: body.status, error: body.error)
        return body.similarSongs2?.song ?? []
    }

    /// Top-Songs eines Künstlers (macOS-Künstlerseite).
    func getTopSongs(
        artistName: String,
        count: Int = 50,
        retries: Int = 0
    ) async throws -> [Song] {
        let body = try await fetchDecoded(Envelope<TopSongsBody>.self, path: "getTopSongs", extra: [
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "count", value: "\(count)")
        ], retries: retries).response
        try check(status: body.status, error: body.error)
        return body.topSongs?.song ?? []
    }

    /// Alle Alben alphabetisch, mit Paging (macOS-Lyrics-Bulk-Download).
    func getAllAlbums(size: Int = 500, offset: Int = 0) async throws -> [Album] {
        try await getAlbumList(type: "alphabeticalByName", size: size, offset: offset)
    }

    /// Ping mit Server-Metadaten für den aktiven Server (macOS-Serververwaltung).
    func getServerInfo() async throws -> ServerInfo {
        let body = try await fetchDecoded(
            Envelope<PingInfoBody>.self,
            path: "ping"
        ).response
        try check(status: body.status, error: body.error)
        let info = ServerInfo(
            apiVersion: body.version,
            serverVersion: body.serverVersion,
            serverType: body.type
        )
        if let server = activeServer {
            responseFormatPreferences.noteServerFingerprint(
                responseFormatServerFingerprint(info),
                serverKey: responseFormatServerKey(for: server)
            )
        }
        return info
    }

    /// Scan auf dem aktiven Server starten (macOS-Serververwaltung).
    func startScan() async throws -> ScanStatus {
        let body = try await fetchDecoded(
            Envelope<ScanStatusBody>.self,
            path: "startScan"
        ).response
        try check(status: body.status, error: body.error)
        return ScanStatus(scanning: body.scanStatus?.scanning ?? false, count: body.scanStatus?.count ?? 0)
    }

    /// Scan-Status des aktiven Servers (macOS-Serververwaltung).
    func getScanStatus() async throws -> ScanStatus {
        let body = try await fetchDecoded(
            Envelope<ScanStatusBody>.self,
            path: "getScanStatus"
        ).response
        try check(status: body.status, error: body.error)
        return ScanStatus(scanning: body.scanStatus?.scanning ?? false, count: body.scanStatus?.count ?? 0)
    }

    /// Frequently-Played-Fallback: Top-Alben nach Play-Count, adaptiver Threshold.
    func frequentMixFallbackSongs() async throws -> [Song] {
        let allFrequent = try await getAlbumList(type: "frequent", size: 500)
        let sorted = allFrequent.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        let maxPC = sorted.first?.playCount ?? 0
        let threshold = max(maxPC / 50, 1)
        var filtered = sorted.filter { ($0.playCount ?? 0) >= threshold }
        if filtered.count < 30 { filtered = Array(sorted.prefix(30)) }
        if filtered.count > 80 { filtered = Array(sorted.prefix(80)) }
        let songs = try await withThrowingTaskGroup(of: [Song].self) { group in
            for album in filtered {
                group.addTask { (try? await self.getAlbum(id: album.id))?.song ?? [] }
            }
            var all: [Song] = []
            for try await albumSongs in group { all.append(contentsOf: albumSongs) }
            return all
        }
        return Array(songs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(50))
    }

    /// Validates credentials through the standard Subsonic API. Navidrome's
    /// native login is used only as an optional source for its stable user UUID.
    /// Every other server receives a deterministic account identity derived
    /// from its canonical primary URL and username.
    func validatedStableId(server: SubsonicServer, password: String) async throws -> String {
        let info = try await ping(server: server, password: password)
        if Self.isNavidrome(serverType: info.serverType),
           let nativeId = try? await navidromeUserId(server: server, password: password),
           !nativeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nativeId
        }
        return server.derivedStableId
    }

    nonisolated private static func isNavidrome(serverType: String?) -> Bool {
        serverType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveContains("navidrome") == true
    }

    private func navidromeUserId(server: SubsonicServer, password: String) async throws -> String {
        var base = server.activeBaseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/auth/login") else { throw SubsonicAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": server.username, "password": password])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw SubsonicAPIError.httpError(http.statusCode)
        }
        struct AuthResponse: Decodable { let id: String }
        return try decoder.decode(AuthResponse.self, from: data).id
    }

    func streamURL(for songId: String, timeOffset: Int = 0) -> URL? {
        var extras = [URLQueryItem(name: "id", value: songId)]
        if let fmt = TranscodingPolicy.currentStreamFormat() {
            extras.append(URLQueryItem(name: "format", value: fmt.codec.rawValue))
            extras.append(URLQueryItem(name: "maxBitRate", value: "\(fmt.bitrate)"))
        } else {
            extras.append(URLQueryItem(name: "format", value: "raw"))
        }
        if timeOffset > 0 {
            extras.append(URLQueryItem(name: "timeOffset", value: "\(timeOffset)"))
        }
        return try? buildURL(path: "stream", extra: extras)
    }

    func rawStreamURL(for songId: String) -> URL? {
        try? buildURL(path: "stream", extra: [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "format", value: "raw")
        ])
    }

    func downloadURL(for songId: String) -> URL? {
        try? buildURL(path: "download", extra: [
            URLQueryItem(name: "id", value: songId)
        ])
    }

    nonisolated func downloadURL(for songId: String, server: SubsonicServer, password: String,
                                 transcoding: (codec: TranscodingCodec, bitrate: Int)? = nil) -> URL? {
        if let t = transcoding {
            return try? buildURL(for: server, password: password, path: "stream", extra: [
                URLQueryItem(name: "id", value: songId),
                URLQueryItem(name: "format", value: t.codec.rawValue),
                URLQueryItem(name: "maxBitRate", value: "\(t.bitrate)")
            ])
        }
        return try? buildURL(for: server, password: password, path: "download", extra: [
            URLQueryItem(name: "id", value: songId)
        ])
    }

    nonisolated func coverArtURL(for artId: String, server: SubsonicServer, password: String, size: Int = 600) -> URL? {
        try? buildURL(for: server, password: password, path: "getCoverArt", extra: [
            URLQueryItem(name: "id", value: artId),
            URLQueryItem(name: "size", value: "\(size)")
        ])
    }

    func coverArtURL(for artId: String, size: Int = 300) -> URL? {
        #if DEBUG
        // Demo-Server ist passwortlos → buildURL würde werfen. Synthetische URL mit der
        // demo_-Asset-ID, damit der Cover-Loader (Mac: CoverArtView) sie als Asset auflöst.
        if isDemoActive { return URL(string: "demo://shelv/getCoverArt?id=\(artId)&size=\(size)") }
        #endif
        return try? buildURL(path: "getCoverArt", extra: [
            URLQueryItem(name: "id", value: artId),
            URLQueryItem(name: "size", value: "\(size)")
        ])
    }

    // MARK: - Favorites (star/unstar/getStarred2)

    func getStarred() async throws -> StarredResult {
        #if DEBUG
        if isDemoActive { return DemoContent.starred }
        #endif
        let body = try await fetchDecoded(
            Envelope<StarredBody>.self,
            path: "getStarred2"
        ).response
        try check(status: body.status, error: body.error)
        return body.starred2 ?? StarredResult(artist: nil, album: nil, song: nil)
    }

    func star(songId: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var extra: [URLQueryItem] = []
        if let id = songId   { extra.append(URLQueryItem(name: "id",       value: id)) }
        if let id = albumId  { extra.append(URLQueryItem(name: "albumId",  value: id)) }
        if let id = artistId { extra.append(URLQueryItem(name: "artistId", value: id)) }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "star",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    func unstar(songId: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var extra: [URLQueryItem] = []
        if let id = songId   { extra.append(URLQueryItem(name: "id",       value: id)) }
        if let id = albumId  { extra.append(URLQueryItem(name: "albumId",  value: id)) }
        if let id = artistId { extra.append(URLQueryItem(name: "artistId", value: id)) }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "unstar",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    // MARK: - Playlists

    func getPlaylists() async throws -> [Playlist] {
        #if DEBUG
        if isDemoActive { return DemoContent.playlists }
        #endif
        let body = try await fetchDecoded(
            Envelope<PlaylistsBody>.self,
            path: "getPlaylists"
        ).response
        try check(status: body.status, error: body.error)
        return body.playlists?.playlist ?? []
    }

    func getPlaylists(context: SubsonicServerRequestContext) async throws -> [Playlist] {
        #if DEBUG
        if context.server.baseURL == DemoContent.serverBaseURL
            || context.server.activeBaseURL == DemoContent.serverBaseURL {
            return DemoContent.playlists
        }
        #endif
        let body = try await fetchDecoded(
            Envelope<PlaylistsBody>.self,
            for: context.server,
            password: context.password,
            path: "getPlaylists"
        ).response
        try check(status: body.status, error: body.error)
        return body.playlists?.playlist ?? []
    }

    func getPlaylist(id: String) async throws -> Playlist {
        #if DEBUG
        if isDemoActive {
            guard let p = DemoContent.playlist(id: id) else { throw SubsonicAPIError.apiError(0, "Playlist not found") }
            return p
        }
        #endif
        let body = try await fetchDecoded(Envelope<PlaylistBody>.self, path: "getPlaylist", extra: [
            URLQueryItem(name: "id", value: id)
        ]).response
        try check(status: body.status, error: body.error)
        guard let detail = body.playlist else {
            throw SubsonicAPIError.apiError(0, "Playlist not found")
        }
        var playlist = Playlist(
            id: detail.id, name: detail.name, comment: detail.comment,
            songCount: detail.songCount, duration: detail.duration, coverArt: detail.coverArt
        )
        playlist.songs = detail.entry ?? []
        return playlist
    }

    func getPlaylist(id: String, context: SubsonicServerRequestContext) async throws -> Playlist {
        #if DEBUG
        if context.server.baseURL == DemoContent.serverBaseURL
            || context.server.activeBaseURL == DemoContent.serverBaseURL {
            guard let playlist = DemoContent.playlist(id: id) else {
                throw SubsonicAPIError.apiError(0, "Playlist not found")
            }
            return playlist
        }
        #endif
        let body = try await fetchDecoded(
            Envelope<PlaylistBody>.self,
            for: context.server,
            password: context.password,
            path: "getPlaylist",
            extra: [URLQueryItem(name: "id", value: id)]
        ).response
        try check(status: body.status, error: body.error)
        guard let detail = body.playlist else {
            throw SubsonicAPIError.apiError(0, "Playlist not found")
        }
        var playlist = Playlist(
            id: detail.id, name: detail.name, comment: detail.comment,
            songCount: detail.songCount, duration: detail.duration, coverArt: detail.coverArt
        )
        playlist.songs = detail.entry ?? []
        return playlist
    }

    func createPlaylist(name: String, songIds: [String] = [], comment: String? = nil) async throws -> Playlist {
        var extra = [URLQueryItem(name: "name", value: name)]
        extra += songIds.map { URLQueryItem(name: "songId", value: $0) }
        let body = try await fetchDecoded(
            Envelope<CreatePlaylistBody>.self,
            path: "createPlaylist",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
        guard let detail = body.playlist else {
            throw SubsonicAPIError.apiError(0, "Create playlist failed")
        }
        if let comment {
            try? await updatePlaylist(id: detail.id, comment: comment)
        }
        return Playlist(
            id: detail.id, name: detail.name, comment: detail.comment,
            songCount: detail.songCount, duration: detail.duration, coverArt: detail.coverArt
        )
    }

    func createPlaylist(
        name: String,
        songIds: [String] = [],
        comment: String? = nil,
        context: SubsonicServerRequestContext
    ) async throws -> Playlist {
        var extra = [URLQueryItem(name: "name", value: name)]
        extra += songIds.map { URLQueryItem(name: "songId", value: $0) }
        let body = try await fetchDecoded(
            Envelope<CreatePlaylistBody>.self,
            for: context.server,
            password: context.password,
            path: "createPlaylist",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
        guard let detail = body.playlist else {
            throw SubsonicAPIError.apiError(0, "Create playlist failed")
        }
        if let comment {
            try? await updatePlaylist(id: detail.id, comment: comment, context: context)
        }
        return Playlist(
            id: detail.id, name: detail.name, comment: detail.comment,
            songCount: detail.songCount, duration: detail.duration, coverArt: detail.coverArt
        )
    }

    func updatePlaylist(id: String, name: String? = nil, comment: String? = nil,
                        songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = []) async throws {
        var extra = [URLQueryItem(name: "playlistId", value: id)]
        if let n = name    { extra.append(URLQueryItem(name: "name",    value: n)) }
        if let c = comment { extra.append(URLQueryItem(name: "comment", value: c)) }
        extra += songIdsToAdd.map         { URLQueryItem(name: "songIdToAdd",          value: $0) }
        extra += normalizedPlaylistRemovalIndices(songIndicesToRemove)
            .map { URLQueryItem(name: "songIndexToRemove", value: "\($0)") }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "updatePlaylist",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    func updatePlaylist(
        id: String,
        name: String? = nil,
        comment: String? = nil,
        songIdsToAdd: [String] = [],
        songIndicesToRemove: [Int] = [],
        context: SubsonicServerRequestContext
    ) async throws {
        var extra = [URLQueryItem(name: "playlistId", value: id)]
        if let name { extra.append(URLQueryItem(name: "name", value: name)) }
        if let comment { extra.append(URLQueryItem(name: "comment", value: comment)) }
        extra += songIdsToAdd.map { URLQueryItem(name: "songIdToAdd", value: $0) }
        extra += normalizedPlaylistRemovalIndices(songIndicesToRemove)
            .map { URLQueryItem(name: "songIndexToRemove", value: "\($0)") }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            for: context.server,
            password: context.password,
            path: "updatePlaylist",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    private func normalizedPlaylistRemovalIndices(_ indices: [Int]) -> [Int] {
        Array(Set(indices.filter { $0 >= 0 })).sorted(by: >)
    }

    func deletePlaylist(id: String) async throws {
        let body = try await fetchDecoded(Envelope<PingBody>.self, path: "deletePlaylist", extra: [
            URLQueryItem(name: "id", value: id)
        ]).response
        try check(status: body.status, error: body.error)
    }

    func deletePlaylist(id: String, context: SubsonicServerRequestContext) async throws {
        #if DEBUG
        if context.server.baseURL == DemoContent.serverBaseURL
            || context.server.activeBaseURL == DemoContent.serverBaseURL {
            return
        }
        #endif
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            for: context.server,
            password: context.password,
            path: "deletePlaylist",
            extra: [URLQueryItem(name: "id", value: id)]
        ).response
        try check(status: body.status, error: body.error)
    }

    // MARK: - Internet Radio Stations

    func getInternetRadioStations() async throws -> [RadioStation] {
        #if DEBUG
        if isDemoActive {
            return [
                RadioStation(id: "demo-radio-1", name: "Shelv Radio", streamURL: "https://example.com/listen/shelv/radio.mp3"),
                RadioStation(id: "demo-radio-2", name: "Late Night Shelf", streamURL: "https://example.com/hls/late-night/live.m3u8")
            ]
        }
        #endif
        let body = try await fetchDecoded(
            Envelope<InternetRadioStationsBody>.self,
            path: "getInternetRadioStations"
        ).response
        try check(status: body.status, error: body.error)
        return body.internetRadioStations?.internetRadioStation ?? []
    }

    func createInternetRadioStation(name: String, streamURL: String, homePageURL: String? = nil) async throws {
        var extra = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "streamUrl", value: streamURL)
        ]
        if let homePageURL, !homePageURL.isEmpty {
            extra.append(URLQueryItem(name: "homePageUrl", value: homePageURL))
        }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "createInternetRadioStation",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    func updateInternetRadioStation(id: String, name: String, streamURL: String, homePageURL: String? = nil) async throws {
        var extra = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "streamUrl", value: streamURL)
        ]
        if let homePageURL, !homePageURL.isEmpty {
            extra.append(URLQueryItem(name: "homePageUrl", value: homePageURL))
        }
        let body = try await fetchDecoded(
            Envelope<PingBody>.self,
            path: "updateInternetRadioStation",
            extra: extra
        ).response
        try check(status: body.status, error: body.error)
    }

    func deleteInternetRadioStation(id: String) async throws {
        let body = try await fetchDecoded(Envelope<PingBody>.self, path: "deleteInternetRadioStation", extra: [
            URLQueryItem(name: "id", value: id)
        ]).response
        try check(status: body.status, error: body.error)
    }

    // MARK: - Lyrics (OpenSubsonic)

    func getLyricsBySongId(songId: String) async throws -> StructuredLyrics? {
        let body = try await fetchDecoded(Envelope<LyricsListBody>.self, path: "getLyricsBySongId", extra: [
            URLQueryItem(name: "id", value: songId)
        ]).response
        try check(status: body.status, error: body.error)
        return body.lyricsList?.structuredLyrics?.first
    }

    /// URL für getLyricsBySongId — nutzbar mit Background-URLSession.
    nonisolated func lyricsURL(for songId: String, server: SubsonicServer, password: String) -> URL? {
        let responseFormat = SubsonicResponseFormatPreferences.shared.selection(
            serverKey: responseFormatServerKey(for: server),
            endpoint: "getLyricsBySongId"
        ).preferredFormat
        return try? buildURL(for: server, password: password, path: "getLyricsBySongId", extra: [
            URLQueryItem(name: "id", value: songId)
        ], responseFormat: responseFormat)
    }

    /// Parst die Antwort eines getLyricsBySongId-Calls. Returnt nil bei API-Fehler oder leerer Response.
    nonisolated func parseLyricsResponse(data: Data) -> StructuredLyrics? {
        if let body = try? Self.makeDecoder().decode(
            Envelope<LyricsListBody>.self,
            from: data
        ).response {
            guard body.status != "failed" else { return nil }
            return body.lyricsList?.structuredLyrics?.first
        }
        guard let body = try? SubsonicXMLDecoder().decode(
            Envelope<LyricsListBody>.self,
            from: data
        ).response,
        body.status != "failed" else { return nil }
        return body.lyricsList?.structuredLyrics?.first
    }
}

nonisolated struct StructuredLyrics: Codable, Sendable {
    let synced: Bool
    let lang: String?
    let line: [LyricsLine]?

    struct LyricsLine: Codable, Sendable {
        let start: Int?
        let value: String
    }
}

private nonisolated struct LyricsListBody: Decodable, Sendable {
    let status: String
    let error: StatusCheck.APIError?
    let lyricsList: LyricsList?

    struct LyricsList: Decodable, Sendable {
        let structuredLyrics: [StructuredLyrics]?
    }
}
