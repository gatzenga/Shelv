import Foundation
import Combine
import CryptoKit

enum SubsonicAPIError: LocalizedError {
    case noServer
    case noPassword
    case invalidURL
    case networkError(Error)
    case apiError(Int, String?)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .noServer:              return tr("No server configured", "Kein Server konfiguriert")
        case .noPassword:            return tr("No password found", "Kein Passwort gefunden")
        case .invalidURL:            return tr("Invalid server URL", "Ungültige Server-URL")
        case .networkError(let e):
            if let urlError = e as? URLError {
                switch urlError.code {
                case .timedOut:
                    return tr("Connection timed out. Please check your network.", "Zeitüberschreitung. Bitte Netzwerkverbindung prüfen.")
                case .notConnectedToInternet:
                    return tr("No internet connection.", "Keine Internetverbindung.")
                case .cannotConnectToHost, .cannotFindHost:
                    return tr("Server not reachable. Please check the URL.", "Server nicht erreichbar. Bitte URL prüfen.")
                case .networkConnectionLost:
                    return tr("Connection lost. Please try again.", "Verbindung verloren. Bitte erneut versuchen.")
                case .secureConnectionFailed:
                    return tr("Secure connection failed. Please check the server certificate.", "Sichere Verbindung fehlgeschlagen. Bitte Serverzertifikat prüfen.")
                default:
                    return tr("Network error. Please try again.", "Netzwerkfehler. Bitte erneut versuchen.")
                }
            }
            return tr("Network error. Please try again.", "Netzwerkfehler. Bitte erneut versuchen.")
        case .apiError(_, let m):
            return m ?? tr("Server returned an error.", "Server hat einen Fehler zurückgegeben.")
        case .decodingError:
            return tr("Unexpected server response.", "Unerwartete Serverantwort.")
        }
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let response: T

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

private struct StatusCheck: Decodable {
    let status: String
    let error: APIError?

    struct APIError: Decodable {
        let code: Int
        let message: String?
    }
}

private struct AlbumListBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let albumList2: AlbumListContainer?
}

private struct ArtistsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let artists: ArtistsContainer?
}

private struct AlbumBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let album: AlbumDetail?
}

private struct ArtistBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let artist: ArtistDetail?
}

private struct SearchBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let searchResult3: SearchResult?
}

private struct SongBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let song: Song?
}

private struct PingBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
}


private struct PingInfoBody: Decodable {
    let status: String
    let version: String
    let type: String?
    let serverVersion: String?
    let error: StatusCheck.APIError?
}

private struct ScanStatusBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let scanStatus: ScanStatusDetail?

    struct ScanStatusDetail: Decodable {
        let scanning: Bool
        let count: Int
    }
}

struct ServerInfo {
    let apiVersion: String
    let serverVersion: String?
}

struct ScanStatus {
    let scanning: Bool
    let count: Int
}

struct AlbumListContainer: Decodable {
    let album: [Album]?
}

struct ArtistsContainer: Decodable {
    let index: [ArtistIndex]?
}

struct ArtistIndex: Decodable {
    let name: String
    let artist: [Artist]?
}

struct AlbumDetail: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let duration: Int?
    let year: Int?
    let genre: String?
    let song: [Song]?
}

struct ArtistDetail: Decodable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?
    let album: [Album]?
}

struct SearchResult: Decodable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

struct StarredResult: Decodable {
    let artist: [Artist]?
    let album: [Album]?
    let song: [Song]?
}

private struct StarredBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let starred2: StarredResult?
}

private struct PlaylistsBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let playlists: PlaylistsContainer?

    struct PlaylistsContainer: Decodable {
        let playlist: [Playlist]?
    }
}

private struct PlaylistBody: Decodable {
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

private struct CreatePlaylistBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let playlist: PlaylistBody.PlaylistDetail?
}

class SubsonicAPIService: ObservableObject {
    static let shared = SubsonicAPIService()

    private let credentialLock = NSLock()
    private var _activeServer: SubsonicServer?
    private var _activePassword: String?

    var activeServer: SubsonicServer? {
        get { credentialLock.withLock { _activeServer } }
        set { credentialLock.withLock { _activeServer = newValue } }
    }

    var activePassword: String? {
        get { credentialLock.withLock { _activePassword } }
        set { credentialLock.withLock { _activePassword = newValue } }
    }

    func setCredentials(server: SubsonicServer, password: String?) {
        credentialLock.withLock {
            _activeServer = server
            _activePassword = password
        }
    }

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
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
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
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
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
        var base = creds.server.baseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard var comps = URLComponents(string: "\(base)/rest/\(path)") else {
            throw SubsonicAPIError.invalidURL
        }
        comps.queryItems = makeAuthParams(server: creds.server, password: creds.password) + extra
        guard let url = comps.url else { throw SubsonicAPIError.invalidURL }
        return url
    }

    private func fetchData(path: String, extra: [URLQueryItem] = [], retries: Int = 2) async throws -> Data {
        let url = try buildURL(path: path, extra: extra)
        var lastError: Error?
        for attempt in 0...retries {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(500 * attempt))
                try Task.checkCancellation()
            }
            do {
                let (data, _) = try await session.data(from: url)
                return data
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                lastError = error
                let isRetryable = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains($0.code)
                } ?? false
                if !isRetryable || attempt == retries { break }
            }
        }
        throw SubsonicAPIError.networkError(lastError!)
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
        var base = server.baseURL
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
        do {
            let (data, _) = try await session.data(from: url)
            return data
        } catch {
            throw SubsonicAPIError.networkError(error)
        }
    }

    func ping() async throws {
        let data = try await fetchData(path: "ping")
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    func ping(server: SubsonicServer, password: String) async throws -> ServerInfo {
        let data = try await fetchData(for: server, password: password, path: "ping")
        let body = try decoder.decode(Envelope<PingInfoBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return ServerInfo(apiVersion: body.version, serverVersion: body.serverVersion)
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
        let data = try await fetchData(path: "getArtists")
        let body = try decoder.decode(Envelope<ArtistsBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        let indices = body.artists?.index ?? []
        return indices.flatMap { $0.artist ?? [] }
    }

    func getAlbum(id: String) async throws -> AlbumDetail {
        let data = try await fetchData(path: "getAlbum", extra: [
            URLQueryItem(name: "id", value: id)
        ])
        let body = try decoder.decode(Envelope<AlbumBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        guard let album = body.album else { throw SubsonicAPIError.apiError(0, "Album not found") }
        return album
    }

    func getArtist(id: String) async throws -> ArtistDetail {
        let data = try await fetchData(path: "getArtist", extra: [
            URLQueryItem(name: "id", value: id)
        ])
        let body = try decoder.decode(Envelope<ArtistBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        guard let artist = body.artist else { throw SubsonicAPIError.apiError(0, "Artist not found") }
        return artist
    }

    func getSong(id: String) async throws -> Song {
        let data = try await fetchData(path: "getSong", extra: [
            URLQueryItem(name: "id", value: id)
        ])
        let body = try decoder.decode(Envelope<SongBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        guard let song = body.song else { throw SubsonicAPIError.apiError(0, "Song not found") }
        return song
    }

    func search(query: String) async throws -> SearchResult {
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

    func getFrequentSongs(limit: Int = 100) async throws -> [Song] {
        let albums = try await getAlbumList(type: "frequent", size: 30)
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

    func getRecentSongs(limit: Int = 100) async throws -> [Song] {
        let albums = try await getAlbumList(type: "recent", size: 30)
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

    func scrobble(songId: String, playedAt: Double? = nil) async throws {
        var extra = [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "submission", value: "true")
        ]
        if let ts = playedAt {
            // Subsonic erwartet Millisekunden seit Epoch
            extra.append(URLQueryItem(name: "time", value: String(Int64(ts * 1000))))
        }
        _ = try await fetchData(path: "scrobble", extra: extra)
    }

    func authLogin(server: SubsonicServer, password: String) async throws -> String {
        var base = server.baseURL
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

    func streamURL(for songId: String) -> URL? {
        var extras = [URLQueryItem(name: "id", value: songId)]
        if let fmt = TranscodingPolicy.currentStreamFormat() {
            extras.append(URLQueryItem(name: "format", value: fmt.codec.rawValue))
            extras.append(URLQueryItem(name: "maxBitRate", value: "\(fmt.bitrate)"))
        } else {
            extras.append(URLQueryItem(name: "format", value: "raw"))
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
                URLQueryItem(name: "maxBitRate", value: "\(t.bitrate)"),
                URLQueryItem(name: "estimateContentLength", value: "true")
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
        try? buildURL(path: "getCoverArt", extra: [
            URLQueryItem(name: "id", value: artId),
            URLQueryItem(name: "size", value: "\(size)")
        ])
    }

    // MARK: - Favorites (star/unstar/getStarred2)

    func getStarred() async throws -> StarredResult {
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
        let data = try await fetchData(path: "getPlaylists")
        let body = try decoder.decode(Envelope<PlaylistsBody>.self, from: data).response
        try check(status: body.status, error: body.error)
        return body.playlists?.playlist ?? []
    }

    func getPlaylist(id: String) async throws -> Playlist {
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
        extra += songIndicesToRemove.map  { URLQueryItem(name: "songIndexToRemove",     value: "\($0)") }
        let data = try await fetchData(path: "updatePlaylist", extra: extra)
        let body = try decoder.decode(Envelope<PingBody>.self, from: data).response
        try check(status: body.status, error: body.error)
    }

    func deletePlaylist(id: String) async throws {
        let data = try await fetchData(path: "deletePlaylist", extra: [
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
}

struct StructuredLyrics: Decodable {
    let synced: Bool
    let lang: String?
    let line: [LyricsLine]?

    struct LyricsLine: Decodable {
        let start: Int?
        let value: String
    }
}

private struct LyricsListBody: Decodable {
    let status: String
    let error: StatusCheck.APIError?
    let lyricsList: LyricsList?

    struct LyricsList: Decodable {
        let structuredLyrics: [StructuredLyrics]?
    }
}
