import Foundation
import Combine
import CryptoKit
import Security

enum SubsonicAPIError: LocalizedError {
    case noServer
    case noPassword
    case invalidURL
    case httpError(Int)
    case networkError(Error)
    case apiError(Int, String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .noServer:              return String(localized: "no_server_configured")
        case .noPassword:            return String(localized: "no_password_found")
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
}

/// Ergebnis von `getPlayQueue` — die serverseitig gespeicherte Wiedergabe-Queue.
nonisolated struct SubsonicPlayQueue {
    let songs: [Song]
    let currentSongId: String?
    /// Server-Zeitstempel der letzten Änderung (ISO-String), falls geliefert.
    let changed: String?
}

private nonisolated struct Envelope<T: Decodable>: Decodable {
    let response: T

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

private nonisolated struct StatusCheck: Decodable {
    let status: String
    let error: APIError?

    struct APIError: Decodable {
        let code: Int
        let message: String?
    }
}

private nonisolated struct AlbumListBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let albumList2: AlbumListContainer?
}

private nonisolated struct ArtistsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let artists: ArtistsContainer?
}

private nonisolated struct AlbumBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let album: AlbumDetail?
}

private nonisolated struct ArtistBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let artist: ArtistDetail?
}

private nonisolated struct ArtistInfoBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let artistInfo2: ArtistInfo?
}

private nonisolated struct SearchBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let searchResult3: SearchResult?
}

private nonisolated struct SongBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let song: Song?
}

private nonisolated struct PingBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
}

private nonisolated struct PlayQueueBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let playQueue: PlayQueueDetail?

    struct PlayQueueDetail: Decodable {
        let entry: [Song]?
        let current: String?
        let position: Int?
        let changed: String?
    }
}


private nonisolated struct PingInfoBody: Decodable {
    let status: String
    let version: String
    let type: String?
    let serverVersion: String?
    let error: StatusCheck.APIError?
}

private nonisolated struct ScanStatusBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let scanStatus: ScanStatusDetail?

    struct ScanStatusDetail: Decodable {
        let scanning: Bool
        let count: Int
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

nonisolated struct AlbumListContainer: Decodable {
    let album: [Album]?
}

nonisolated struct ArtistsContainer: Decodable {
    let index: [ArtistIndex]?
}

nonisolated struct ArtistIndex: Decodable {
    let name: String
    let artist: [Artist]?
}

nonisolated struct AlbumDetail: Decodable, Identifiable {
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

nonisolated struct ArtistDetail: Decodable, Identifiable {
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

nonisolated struct ArtistInfo: Decodable {
    let biography: String?
}

nonisolated struct SearchResult: Decodable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

nonisolated struct StarredResult: Decodable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

private nonisolated struct RandomSongsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let randomSongs: RandomSongsList?
    struct RandomSongsList: Decodable { let song: [Song]? }
}

private nonisolated struct TopSongsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let topSongs: TopSongsList?
    struct TopSongsList: Decodable { let song: [Song]? }
}

private nonisolated struct SimilarSongsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let similarSongs: SimilarSongsList?
    struct SimilarSongsList: Decodable { let song: [Song]? }
}

private nonisolated struct SimilarSongs2Body: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let similarSongs2: SimilarSongsList?
    struct SimilarSongsList: Decodable { let song: [Song]? }
}

private nonisolated struct StarredBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let starred2: StarredResult?
}

private nonisolated struct PlaylistsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let playlists: PlaylistsContainer?

    struct PlaylistsContainer: Decodable {
        let playlist: [Playlist]?
    }
}

private nonisolated struct PlaylistBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let playlist: PlaylistDetail?

    struct PlaylistDetail: Decodable {
        let id: String
        let name: String
        let comment: String?
        let songCount: Int?
        let duration: Int?
        let coverArt: String?
        let entry: [Song]?
    }
}

private nonisolated struct CreatePlaylistBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let playlist: PlaylistBody.PlaylistDetail?
}

private nonisolated struct InternetRadioStationsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let internetRadioStations: InternetRadioStationsContainer?

    struct InternetRadioStationsContainer: Decodable {
        let internetRadioStation: [RadioStation]?
    }
}

nonisolated class SubsonicAPIService: ObservableObject, @unchecked Sendable {
    nonisolated static let shared = SubsonicAPIService()
    nonisolated private static let requestTimeout: TimeInterval = 10

    private let credentialLock = NSLock()
    nonisolated(unsafe) private var _activeServer: SubsonicServer?
    nonisolated(unsafe) private var _activePassword: String?

    nonisolated var activeServer: SubsonicServer? {
        get { credentialLock.withLock { _activeServer } }
        set { credentialLock.withLock { _activeServer = newValue } }
    }

    nonisolated var activePassword: String? {
        get { credentialLock.withLock { _activePassword } }
        set { credentialLock.withLock { _activePassword = newValue } }
    }

    nonisolated func setCredentials(server: SubsonicServer, password: String?) {
        credentialLock.withLock {
            _activeServer = server
            _activePassword = password
        }
    }

    #if DEBUG
    /// Aktiv, wenn der Demo-Server gewählt ist. Alle Daten-Methoden liefern dann
    /// `DemoContent`-Daten statt echter Netzwerk-Antworten. Siehe `DemoContent`.
    nonisolated var isDemoActive: Bool { activeServer?.baseURL == DemoContent.serverBaseURL }
    #endif

    private let apiVersion = "1.16.1"
    private let clientName = "Shelv"
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)

            let normalized: String
            if let dotRange = raw.range(of: "."),
               let zRange = raw.range(of: "Z", options: .backwards),
               dotRange.upperBound <= zRange.lowerBound {
                let fractional = String(raw[dotRange.upperBound..<zRange.lowerBound])
                let trimmed = String(fractional.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
                normalized = String(raw[raw.startIndex..<dotRange.lowerBound]) + "." + trimmed + "Z"
            } else if let dotRange = raw.range(of: "."),
                      let plusRange = raw.range(of: "+", range: dotRange.upperBound..<raw.endIndex) {
                let fractional = String(raw[dotRange.upperBound..<plusRange.lowerBound])
                let trimmed = String(fractional.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
                normalized = String(raw[raw.startIndex..<dotRange.lowerBound]) + "." + trimmed + String(raw[plusRange.lowerBound...])
            } else {
                normalized = raw
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: normalized) { return date }

            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: normalized) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(raw)")
        }
        return d
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config)
    }()

    private init() {}

    private func resolveCredentials() throws -> (server: SubsonicServer, password: String) {
        try credentialLock.withLock {
            guard let s = _activeServer else { throw SubsonicAPIError.noServer }
            if _activePassword == nil {
                _activePassword = KeychainService.load(for: s.id)
            }
            guard let p = _activePassword else { throw SubsonicAPIError.noPassword }
            return (s, p)
        }
    }

    private func makeAuthParams(server: SubsonicServer, password: String) -> [URLQueryItem] {
        let s = makeSalt()
        let t = makeToken(password: password, salt: s)
        return [
            URLQueryItem(name: "u", value: server.username),
            URLQueryItem(name: "t", value: t),
            URLQueryItem(name: "s", value: s),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
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
        let creds = try resolveCredentials()
        return makeAuthParams(server: creds.server, password: creds.password)
    }

    private func buildURL(path: String, extra: [URLQueryItem] = []) throws -> URL {
        let creds = try resolveCredentials()
        var base = creds.server.activeBaseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: "\(base)/rest/\(path)") else {
            throw SubsonicAPIError.invalidURL
        }
        comps.queryItems = makeAuthParams(server: creds.server, password: creds.password) + extra
        guard let url = comps.url else { throw SubsonicAPIError.invalidURL }
        return url
    }

    private func activeRequestSignature(for server: SubsonicServer) -> String {
        "\(server.id.uuidString)|\(server.activeBaseURL)"
    }

    private func isCurrentActiveRequest(_ signature: String) -> Bool {
        credentialLock.withLock {
            guard let server = _activeServer else { return false }
            return activeRequestSignature(for: server) == signature
        }
    }

    private func notifyServerErrorIfCurrentRequest(_ signature: String, message: String?) async {
        await MainActor.run {
            guard self.isCurrentActiveRequest(signature) else { return }
            OfflineModeService.shared.notifyServerErrorIfPresentationAllowed(message)
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

    private func fetchData(path: String, extra: [URLQueryItem] = [], retries: Int = 0) async throws -> Data {
        let creds = try resolveCredentials()
        let requestSignature = activeRequestSignature(for: creds.server)
        let url = try buildURL(for: creds.server, password: creds.password, path: path, extra: extra)
        await NetworkStatus.shared.waitUntilReady()
        if !NetworkStatus.shared.hasNetwork {
            let networkError = SubsonicAPIError.networkError(URLError(.notConnectedToInternet))
            ConnectivityDebugLog.log("request failed: \(path) -> no network")
            await notifyServerErrorIfCurrentRequest(requestSignature, message: networkError.localizedDescription)
            throw networkError
        }
        var lastError: Error?
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
                    break
                }
                continue
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let httpError = SubsonicAPIError.httpError(http.statusCode)
                ConnectivityDebugLog.log("request failed: \(path) -> HTTP \(http.statusCode) after \(String(format: "%.2f", elapsed))s")
                await notifyServerErrorIfCurrentRequest(requestSignature, message: httpError.localizedDescription)
                throw httpError
            } else {
                // Server hat geantwortet -> Banner ausblenden, aber nur wenn diese Antwort
                // noch zur aktuell ausgewählten URL gehört.
                await clearServerErrorIfCurrentRequest(requestSignature)
                return data
            }
        }
        let rootError = lastError ?? URLError(.unknown)
        let networkError = SubsonicAPIError.networkError(rootError)
        await notifyServerErrorIfCurrentRequest(requestSignature, message: networkError.localizedDescription)
        throw networkError
    }

    private func check(status: String, error: StatusCheck.APIError?) throws {
        if status == "failed" {
            throw SubsonicAPIError.apiError(error?.code ?? 0, error?.message)
        }
    }

    nonisolated private func authParams(for server: SubsonicServer, password: String) -> [URLQueryItem] {
        let s = makeSalt()
        let t = makeToken(password: password, salt: s)
        return [
            URLQueryItem(name: "u", value: server.username),
            URLQueryItem(name: "t", value: t),
            URLQueryItem(name: "s", value: s),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    nonisolated private func buildURL(for server: SubsonicServer, password: String, path: String, extra: [URLQueryItem] = []) throws -> URL {
        var base = server.activeBaseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: "\(base)/rest/\(path)") else {
            throw SubsonicAPIError.invalidURL
        }
        comps.queryItems = authParams(for: server, password: password) + extra
        guard let url = comps.url else { throw SubsonicAPIError.invalidURL }
        return url
    }

    private func fetchData(for server: SubsonicServer, password: String, path: String, extra: [URLQueryItem] = []) async throws -> Data {
        let url = try buildURL(for: server, password: password, path: path, extra: extra)
        await NetworkStatus.shared.waitUntilReady()
        guard NetworkStatus.shared.hasNetwork else {
            throw SubsonicAPIError.networkError(URLError(.notConnectedToInternet))
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = Self.requestTimeout
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw SubsonicAPIError.httpError(http.statusCode)
            }
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

    func ping() async throws {
        #if DEBUG
        if isDemoActive {
            await clearServerErrorForDemoRequest()
            return
        }
        #endif
        let data = try await fetchData(path: "ping")
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    @discardableResult
    func ping(server: SubsonicServer, password: String) async throws -> ServerInfo {
        #if DEBUG
        if server.baseURL == DemoContent.serverBaseURL || server.activeBaseURL == DemoContent.serverBaseURL {
            return ServerInfo(apiVersion: apiVersion, serverVersion: "Shelv Demo", serverType: "demo")
        }
        #endif
        let data = try await fetchData(for: server, password: password, path: "ping")
        let body = try decoder.decode(Envelope<PingInfoBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return ServerInfo(apiVersion: body.version, serverVersion: body.serverVersion, serverType: body.type)
    }

    func startScan(server: SubsonicServer, password: String) async throws {
        let data = try await fetchData(for: server, password: password, path: "startScan")
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    func getScanStatus(server: SubsonicServer, password: String) async throws -> ScanStatus {
        let data = try await fetchData(for: server, password: password, path: "getScanStatus")
        let body = try decoder.decode(Envelope<ScanStatusBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        let detail = body.scanStatus
        return ScanStatus(scanning: detail?.scanning ?? false, count: detail?.count ?? 0)
    }

    func getAlbumList(type: String, size: Int = 20, offset: Int = 0) async throws -> [Album] {
        #if DEBUG
        if isDemoActive { return offset > 0 ? [] : DemoContent.albumList(type: type) }
        #endif
        let data = try await fetchData(path: "getAlbumList2", extra: [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "size", value: "\(size)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ])
        let body = try decoder.decode(Envelope<AlbumListBody>.self, from: data).response
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
        let data = try await fetchData(path: "getArtists")
        let body = try decoder.decode(Envelope<ArtistsBody>.self, from: data).response
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
        let data = try await fetchData(path: "getAlbum", extra: [
            URLQueryItem(name: "id", value: id)
        ], retries: retries)
        let body = try decoder.decode(Envelope<AlbumBody>.self, from: data).response
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
        let data = try await fetchData(path: "getArtist", extra: [
            URLQueryItem(name: "id", value: id)
        ], retries: retries)
        let body = try decoder.decode(Envelope<ArtistBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        guard let artist = body.artist else { throw SubsonicAPIError.apiError(0, "Artist not found") }
        return artist
    }

    func getArtistInfo(id: String) async throws -> ArtistInfo {
        #if DEBUG
        if isDemoActive { return ArtistInfo(biography: nil) }
        #endif
        let data = try await fetchData(path: "getArtistInfo2", extra: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: "0")
        ])
        let body = try decoder.decode(Envelope<ArtistInfoBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return body.artistInfo2 ?? ArtistInfo(biography: nil)
    }

    func getSong(id: String, retries: Int = 0) async throws -> Song {
        let data = try await fetchData(path: "getSong", extra: [
            URLQueryItem(name: "id", value: id)
        ], retries: retries)
        let body = try decoder.decode(Envelope<SongBody>.self, from: data).response
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
        let data = try await fetchData(path: "search3", extra: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: "10"),
            URLQueryItem(name: "albumCount", value: "10"),
            URLQueryItem(name: "songCount", value: "20")
        ])
        let body = try decoder.decode(Envelope<SearchBody>.self, from: data).response
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
        let data = try await fetchData(path: "getRandomSongs", extra: extra, retries: retries)
        let body = try decoder.decode(Envelope<RandomSongsBody>.self, from: data).response
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
        let data = try await fetchData(
            path: "scrobble",
            extra: scrobbleQueryItems(songId: songId, submission: submission, playedAt: playedAt)
        )
        try validateScrobbleResponse(data)
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
        let data = try await fetchData(
            for: server,
            password: password,
            path: "scrobble",
            extra: scrobbleQueryItems(songId: songId, submission: submission, playedAt: playedAt)
        )
        try validateScrobbleResponse(data)
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

    private func validateScrobbleResponse(_ data: Data) throws {
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
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
        let data = try await fetchData(path: "savePlayQueue", extra: extra)
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    /// Liest die serverseitig gespeicherte Wiedergabe-Queue (`getPlayQueue`).
    /// Liefert `nil`, wenn keine Queue gespeichert ist.
    func getPlayQueue() async throws -> SubsonicPlayQueue? {
        #if DEBUG
        if isDemoActive { return nil }
        #endif
        let data = try await fetchData(path: "getPlayQueue")
        let body = try decoder.decode(Envelope<PlayQueueBody>.self, from: data).response
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
        let data = try await fetchData(path: "getSimilarSongs", extra: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: "\(count)")
        ], retries: retries)
        let body = try decoder.decode(Envelope<SimilarSongsBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return body.similarSongs?.song ?? []
    }

    /// Ähnliche Songs über die ID3/OpenSubsonic-Variante, typischerweise für Artist-IDs.
    func getSimilarSongs2(id: String, count: Int = 50, retries: Int = 0) async throws -> [Song] {
        let data = try await fetchData(path: "getSimilarSongs2", extra: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: "\(count)")
        ], retries: retries)
        let body = try decoder.decode(Envelope<SimilarSongs2Body>.self, from: data).response
        try check(status: body.status, error: body.error)
        return body.similarSongs2?.song ?? []
    }

    /// Top-Songs eines Künstlers (macOS-Künstlerseite).
    func getTopSongs(
        artistName: String,
        count: Int = 50,
        retries: Int = 0
    ) async throws -> [Song] {
        let data = try await fetchData(path: "getTopSongs", extra: [
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "count", value: "\(count)")
        ], retries: retries)
        let body = try decoder.decode(Envelope<TopSongsBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return body.topSongs?.song ?? []
    }

    /// Alle Alben alphabetisch, mit Paging (macOS-Lyrics-Bulk-Download).
    func getAllAlbums(size: Int = 500, offset: Int = 0) async throws -> [Album] {
        try await getAlbumList(type: "alphabeticalByName", size: size, offset: offset)
    }

    /// Ping mit Server-Metadaten für den aktiven Server (macOS-Serververwaltung).
    func getServerInfo() async throws -> ServerInfo {
        let data = try await fetchData(path: "ping")
        let body = try decoder.decode(Envelope<PingInfoBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return ServerInfo(apiVersion: body.version, serverVersion: body.serverVersion, serverType: body.type)
    }

    /// Scan auf dem aktiven Server starten (macOS-Serververwaltung).
    func startScan() async throws -> ScanStatus {
        let data = try await fetchData(path: "startScan")
        let body = try decoder.decode(Envelope<ScanStatusBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return ScanStatus(scanning: body.scanStatus?.scanning ?? false, count: body.scanStatus?.count ?? 0)
    }

    /// Scan-Status des aktiven Servers (macOS-Serververwaltung).
    func getScanStatus() async throws -> ScanStatus {
        let data = try await fetchData(path: "getScanStatus")
        let body = try decoder.decode(Envelope<ScanStatusBody>.self, from: data).response
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

    func authLogin(server: SubsonicServer, password: String) async throws -> String {
        var base = server.activeBaseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/auth/login") else { throw SubsonicAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": server.username, "password": password])
        let (data, _) = try await session.data(for: request)
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
        let data = try await fetchData(path: "getStarred2")
        let body = try decoder.decode(Envelope<StarredBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return body.starred2 ?? StarredResult(artist: nil, album: nil, song: nil)
    }

    func star(songId: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var extra: [URLQueryItem] = []
        if let id = songId   { extra.append(URLQueryItem(name: "id",       value: id)) }
        if let id = albumId  { extra.append(URLQueryItem(name: "albumId",  value: id)) }
        if let id = artistId { extra.append(URLQueryItem(name: "artistId", value: id)) }
        let data = try await fetchData(path: "star", extra: extra)
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    func unstar(songId: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var extra: [URLQueryItem] = []
        if let id = songId   { extra.append(URLQueryItem(name: "id",       value: id)) }
        if let id = albumId  { extra.append(URLQueryItem(name: "albumId",  value: id)) }
        if let id = artistId { extra.append(URLQueryItem(name: "artistId", value: id)) }
        let data = try await fetchData(path: "unstar", extra: extra)
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    // MARK: - Playlists

    func getPlaylists() async throws -> [Playlist] {
        #if DEBUG
        if isDemoActive { return DemoContent.playlists }
        #endif
        let data = try await fetchData(path: "getPlaylists")
        let body = try decoder.decode(Envelope<PlaylistsBody>.self, from: data).response
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
        let data = try await fetchData(path: "getPlaylist", extra: [
            URLQueryItem(name: "id", value: id)
        ])
        let body = try decoder.decode(Envelope<PlaylistBody>.self, from: data).response
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
        let data = try await fetchData(path: "createPlaylist", extra: extra)
        let body = try decoder.decode(Envelope<CreatePlaylistBody>.self, from: data).response
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

    func updatePlaylist(id: String, name: String? = nil, comment: String? = nil,
                        songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = []) async throws {
        var extra = [URLQueryItem(name: "playlistId", value: id)]
        if let n = name    { extra.append(URLQueryItem(name: "name",    value: n)) }
        if let c = comment { extra.append(URLQueryItem(name: "comment", value: c)) }
        extra += songIdsToAdd.map         { URLQueryItem(name: "songIdToAdd",          value: $0) }
        extra += normalizedPlaylistRemovalIndices(songIndicesToRemove)
            .map { URLQueryItem(name: "songIndexToRemove", value: "\($0)") }
        let data = try await fetchData(path: "updatePlaylist", extra: extra)
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    private func normalizedPlaylistRemovalIndices(_ indices: [Int]) -> [Int] {
        Array(Set(indices.filter { $0 >= 0 })).sorted(by: >)
    }

    func deletePlaylist(id: String) async throws {
        let data = try await fetchData(path: "deletePlaylist", extra: [
            URLQueryItem(name: "id", value: id)
        ])
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
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
        let data = try await fetchData(path: "getInternetRadioStations")
        let body = try decoder.decode(Envelope<InternetRadioStationsBody>.self, from: data).response
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
        let data = try await fetchData(path: "createInternetRadioStation", extra: extra)
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
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
        let data = try await fetchData(path: "updateInternetRadioStation", extra: extra)
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    func deleteInternetRadioStation(id: String) async throws {
        let data = try await fetchData(path: "deleteInternetRadioStation", extra: [
            URLQueryItem(name: "id", value: id)
        ])
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    // MARK: - Lyrics (OpenSubsonic)

    func getLyricsBySongId(songId: String) async throws -> StructuredLyrics? {
        let data = try await fetchData(path: "getLyricsBySongId", extra: [
            URLQueryItem(name: "id", value: songId)
        ])
        let body = try decoder.decode(Envelope<LyricsListBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return body.lyricsList?.structuredLyrics?.first
    }

    /// URL für getLyricsBySongId — nutzbar mit Background-URLSession.
    nonisolated func lyricsURL(for songId: String, server: SubsonicServer, password: String) -> URL? {
        try? buildURL(for: server, password: password, path: "getLyricsBySongId", extra: [
            URLQueryItem(name: "id", value: songId)
        ])
    }

    /// Parst die Antwort eines getLyricsBySongId-Calls. Returnt nil bei API-Fehler oder leerer Response.
    nonisolated func parseLyricsResponse(data: Data) -> StructuredLyrics? {
        let dec = JSONDecoder()
        guard let body = try? dec.decode(Envelope<LyricsListBody>.self, from: data).response,
              body.status != "failed" else { return nil }
        return body.lyricsList?.structuredLyrics?.first
    }
}

nonisolated struct StructuredLyrics: Codable {
    let synced: Bool
    let lang: String?
    let line: [LyricsLine]?

    struct LyricsLine: Codable {
        let start: Int?
        let value: String
    }
}

private nonisolated struct LyricsListBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let lyricsList: LyricsList?

    struct LyricsList: Decodable {
        let structuredLyrics: [StructuredLyrics]?
    }
}
