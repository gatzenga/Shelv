import Foundation
import Combine
import CryptoKit

class SubsonicAPIService: ObservableObject {
    static let shared = SubsonicAPIService()

    private var config: ServerConfig?
    private let clientName = "shelv-desktop"
    private let apiVersion = "1.16.1"

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private init() {}

    func setConfig(_ config: ServerConfig) {
        self.config = config
    }

    func clearConfig() {
        self.config = nil
    }

    var hasConfig: Bool { config != nil && config!.isValid }
    var currentConfig: ServerConfig? { config }

    #if DEBUG
    var isDemoActive: Bool { config?.serverURL == DemoContent.serverBaseURL }
    #endif

    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }

    private func authParams(config: ServerConfig) -> [URLQueryItem] {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10)
        let token = md5(config.password + salt)
        return [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: String(salt)),
            URLQueryItem(name: "v", value: apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    private func buildURL(endpoint: String, params: [URLQueryItem] = []) throws -> URL {
        guard let cfg = config else { throw APIError.notConfigured }
        var base = cfg.serverURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard var components = URLComponents(string: base + "/rest/" + endpoint) else {
            throw APIError.invalidURL
        }
        components.queryItems = authParams(config: cfg) + params
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    private func fetch<T: Decodable>(_ type: T.Type, endpoint: String, params: [URLQueryItem] = []) async throws -> T {
        let url = try buildURL(endpoint: endpoint, params: params)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError
        }
        Task { @MainActor in OfflineModeService.shared.clearServerError() }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func fetchSubsonic(endpoint: String, params: [URLQueryItem] = []) async throws -> SubsonicResponseBody {
        let wrapper = try await fetch(SubsonicResponse.self, endpoint: endpoint, params: params)
        let body = wrapper.subsonicResponse
        if body.status != "ok" {
            if body.error?.code == 70 {
                throw APIError.notFound
            }
            throw APIError.serverError(body.error?.message ?? String(localized: "unknown_error"))
        }
        return body
    }

    func getArtists() async throws -> [ArtistIndex] {
        let body = try await fetchSubsonic(endpoint: "getArtists")
        return body.artists?.index ?? []
    }

    func getArtist(id: String) async throws -> ArtistDetail {
        #if DEBUG
        if isDemoActive {
            guard let d = DemoContent.artistDetail(id: id) else { throw APIError.missingData }
            return d
        }
        #endif
        let body = try await fetchSubsonic(endpoint: "getArtist", params: [
            URLQueryItem(name: "id", value: id)
        ])
        guard let artist = body.artist else { throw APIError.missingData }
        return artist
    }

    func getAlbumList(type: AlbumListType, size: Int = 50, offset: Int = 0) async throws -> [Album] {
        #if DEBUG
        if isDemoActive { return offset > 0 ? [] : DemoContent.albumList(type: type) }
        #endif
        let body = try await fetchSubsonic(endpoint: "getAlbumList2", params: [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "size", value: "\(size)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ])
        return body.albumList2?.album ?? []
    }

    func getAlbum(id: String) async throws -> AlbumDetail {
        #if DEBUG
        if isDemoActive {
            guard let d = DemoContent.albumDetail(id: id) else { throw APIError.missingData }
            return d
        }
        #endif
        let body = try await fetchSubsonic(endpoint: "getAlbum", params: [
            URLQueryItem(name: "id", value: id)
        ])
        guard let album = body.album else { throw APIError.missingData }
        return album
    }

    func getSong(id: String) async throws -> Song {
        let body = try await fetchSubsonic(endpoint: "getSong", params: [
            URLQueryItem(name: "id", value: id)
        ])
        guard let song = body.song else { throw APIError.missingData }
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

    func getArtistInfo(id: String) async throws -> ArtistInfo {
        #if DEBUG
        if isDemoActive { return ArtistInfo(biography: nil) }
        #endif
        let body = try await fetchSubsonic(endpoint: "getArtistInfo2", params: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "count", value: "0")
        ])
        return body.artistInfo2 ?? ArtistInfo(biography: nil)
    }

    func getRandomSongs(size: Int = 100, genre: String? = nil) async throws -> [Song] {
        var params = [URLQueryItem(name: "size", value: "\(size)")]
        if let g = genre { params.append(URLQueryItem(name: "genre", value: g)) }
        let body = try await fetchSubsonic(endpoint: "getRandomSongs", params: params)
        return body.randomSongs?.song ?? []
    }

    func getTopSongs(artistName: String, count: Int = 50) async throws -> [Song] {
        let body = try await fetchSubsonic(endpoint: "getTopSongs", params: [
            URLQueryItem(name: "artist", value: artistName),
            URLQueryItem(name: "count", value: "\(count)")
        ])
        return body.topSongs?.song ?? []
    }

    func scrobble(songId: String, submission: Bool = true, playedAt: Double? = nil) async throws {
        var params = [
            URLQueryItem(name: "id", value: songId),
            URLQueryItem(name: "submission", value: submission ? "true" : "false")
        ]
        if let ts = playedAt {
            params.append(URLQueryItem(name: "time", value: String(Int64(ts * 1000))))
        }
        _ = try await fetchSubsonic(endpoint: "scrobble", params: params)
    }

    func search(query: String) async throws -> SearchResult3 {
        #if DEBUG
        if isDemoActive { return DemoContent.search(query: query) }
        #endif
        let body = try await fetchSubsonic(endpoint: "search3", params: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: "10"),
            URLQueryItem(name: "albumCount", value: "20"),
            URLQueryItem(name: "songCount", value: "30")
        ])
        return body.searchResult3 ?? SearchResult3(artist: [], album: [], song: [])
    }

    func getStarred() async throws -> Starred2Result {
        #if DEBUG
        if isDemoActive { return DemoContent.starred }
        #endif
        let body = try await fetchSubsonic(endpoint: "getStarred2")
        return body.starred2 ?? Starred2Result(artist: nil, album: nil, song: nil)
    }

    func star(songId: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var params: [URLQueryItem] = []
        if let id = songId { params.append(URLQueryItem(name: "id", value: id)) }
        if let id = albumId { params.append(URLQueryItem(name: "albumId", value: id)) }
        if let id = artistId { params.append(URLQueryItem(name: "artistId", value: id)) }
        _ = try await fetchSubsonic(endpoint: "star", params: params)
    }

    func unstar(songId: String? = nil, albumId: String? = nil, artistId: String? = nil) async throws {
        var params: [URLQueryItem] = []
        if let id = songId { params.append(URLQueryItem(name: "id", value: id)) }
        if let id = albumId { params.append(URLQueryItem(name: "albumId", value: id)) }
        if let id = artistId { params.append(URLQueryItem(name: "artistId", value: id)) }
        _ = try await fetchSubsonic(endpoint: "unstar", params: params)
    }

    func coverArtURL(id: String, size: Int? = nil) -> URL? {
        guard let cfg = config else { return nil }
        var base = cfg.serverURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard var components = URLComponents(string: base + "/rest/getCoverArt") else { return nil }
        var items = authParams(config: cfg)
        items.append(URLQueryItem(name: "id", value: id))
        if let s = size { items.append(URLQueryItem(name: "size", value: "\(s)")) }
        components.queryItems = items
        return components.url
    }

    func streamURL(songId: String, timeOffset: Int = 0) -> URL? {
        guard let cfg = config else { return nil }
        var base = cfg.serverURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard var components = URLComponents(string: base + "/rest/stream") else { return nil }
        var items = authParams(config: cfg)
        items.append(URLQueryItem(name: "id", value: songId))
        if let fmt = TranscodingPolicy.currentStreamFormat() {
            items.append(URLQueryItem(name: "format", value: fmt.codec.rawValue))
            items.append(URLQueryItem(name: "maxBitRate", value: "\(fmt.bitrate)"))
        } else {
            items.append(URLQueryItem(name: "format", value: "raw"))
        }
        if timeOffset > 0 {
            items.append(URLQueryItem(name: "timeOffset", value: "\(timeOffset)"))
        }
        components.queryItems = items
        return components.url
    }

    func rawStreamURL(songId: String) -> URL? {
        guard let cfg = config else { return nil }
        var base = cfg.serverURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard var components = URLComponents(string: base + "/rest/stream") else { return nil }
        var items = authParams(config: cfg)
        items.append(URLQueryItem(name: "id", value: songId))
        items.append(URLQueryItem(name: "format", value: "raw"))
        components.queryItems = items
        return components.url
    }

    func downloadURL(songId: String) -> URL? {
        guard let cfg = config else { return nil }
        return downloadURL(forConfig: cfg, songId: songId)
    }

    func downloadURL(forConfig cfg: ServerConfig, songId: String,
                     transcoding: (codec: TranscodingCodec, bitrate: Int)? = nil) -> URL? {
        var base = cfg.serverURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        let path = transcoding != nil ? "/rest/stream" : "/rest/download"
        guard var components = URLComponents(string: base + path) else { return nil }
        var items = authParams(config: cfg)
        items.append(URLQueryItem(name: "id", value: songId))
        if let t = transcoding {
            items.append(URLQueryItem(name: "format", value: t.codec.rawValue))
            items.append(URLQueryItem(name: "maxBitRate", value: "\(t.bitrate)"))
        }
        components.queryItems = items
        return components.url
    }

    func coverArtURL(forConfig cfg: ServerConfig, id: String, size: Int? = nil) -> URL? {
        var base = cfg.serverURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard var components = URLComponents(string: base + "/rest/getCoverArt") else { return nil }
        var items = authParams(config: cfg)
        items.append(URLQueryItem(name: "id", value: id))
        if let s = size { items.append(URLQueryItem(name: "size", value: "\(s)")) }
        components.queryItems = items
        return components.url
    }
    func getNewestSongs(albumCount: Int = 10) async throws -> [Song] {
        try await fetchSongsFromAlbums(type: .newest, albumCount: albumCount)
    }
    func getFrequentSongs(albumCount: Int = 50, limit: Int = 100) async throws -> [Song] {
        let albums = try await getAlbumList(type: .frequent, size: albumCount)
        let allSongs = try await withThrowingTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask { try await self.getAlbum(id: album.id).song }
            }
            var songs: [Song] = []
            for try await albumSongs in group { songs.append(contentsOf: albumSongs) }
            return songs
        }
        return Array(allSongs.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }.prefix(limit))
    }
    func frequentMixFallbackSongs() async throws -> [Song] {
        let allFrequent = try await getAlbumList(type: .frequent, size: 500)
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
    func getRecentSongs(albumCount: Int = 50, limit: Int = 100) async throws -> [Song] {
        let albums = try await getAlbumList(type: .recentlyPlayed, size: albumCount)
        let indexed = Array(albums.enumerated())
        let songsByIndex = try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
            for (i, album) in indexed {
                group.addTask { (i, try await self.getAlbum(id: album.id).song) }
            }
            var result: [(Int, [Song])] = []
            for try await pair in group { result.append(pair) }
            return result
        }
        let ordered = songsByIndex.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        return Array(ordered.prefix(limit))
    }

    private func fetchSongsFromAlbums(type: AlbumListType, albumCount: Int) async throws -> [Song] {
        let albums = try await getAlbumList(type: type, size: albumCount)
        return try await withThrowingTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask { try await self.getAlbum(id: album.id).song }
            }
            var songs: [Song] = []
            for try await albumSongs in group { songs.append(contentsOf: albumSongs) }
            return songs
        }
    }

    func ping() async throws {
        _ = try await fetchSubsonic(endpoint: "ping")
    }

    func authLogin() async throws -> String {
        guard let cfg = config else { throw APIError.notConfigured }
        var base = cfg.serverURL
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard let url = URL(string: "\(base)/auth/login") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["username": cfg.username, "password": cfg.password])
        let (data, _) = try await URLSession.shared.data(for: request)
        struct AuthResponse: Decodable { let id: String }
        do {
            return try JSONDecoder().decode(AuthResponse.self, from: data).id
        } catch {
            throw APIError.decodingError(error)
        }
    }

    func getServerInfo() async throws -> ServerInfo {
        let body = try await fetchSubsonic(endpoint: "ping")
        return ServerInfo(
            apiVersion: body.version,
            serverVersion: body.serverVersion,
            serverType: body.type
        )
    }

    func startScan() async throws -> ScanStatusBody {
        let body = try await fetchSubsonic(endpoint: "startScan")
        guard let status = body.scanStatus else { throw APIError.missingData }
        return status
    }

    func getScanStatus() async throws -> ScanStatusBody {
        let body = try await fetchSubsonic(endpoint: "getScanStatus")
        guard let status = body.scanStatus else { throw APIError.missingData }
        return status
    }

    func getAllArtists() async throws -> [Artist] {
        #if DEBUG
        if isDemoActive { return DemoContent.artists }
        #endif
        let indices = try await getArtists()
        return indices.flatMap { $0.artist }
    }

    func getPlaylists() async throws -> [Playlist] {
        #if DEBUG
        if isDemoActive { return DemoContent.playlists }
        #endif
        let body = try await fetchSubsonic(endpoint: "getPlaylists")
        return body.playlists?.playlist ?? []
    }

    func getPlaylist(id: String) async throws -> PlaylistDetail {
        #if DEBUG
        if isDemoActive {
            guard let d = DemoContent.playlistDetail(id: id) else { throw APIError.missingData }
            return d
        }
        #endif
        let body = try await fetchSubsonic(endpoint: "getPlaylist", params: [
            URLQueryItem(name: "id", value: id)
        ])
        guard let detail = body.playlist else { throw APIError.missingData }
        return detail
    }

    func createPlaylist(name: String, songIds: [String] = [], comment: String? = nil) async throws -> Playlist {
        var params: [URLQueryItem] = [URLQueryItem(name: "name", value: name)]
        for id in songIds {
            params.append(URLQueryItem(name: "songId", value: id))
        }
        let body = try await fetchSubsonic(endpoint: "createPlaylist", params: params)
        guard let detail = body.playlist else { throw APIError.missingData }
        if let comment {
            try? await updatePlaylist(id: detail.id, comment: comment)
        }
        return Playlist(id: detail.id, name: detail.name, comment: comment ?? detail.comment,
                        songCount: detail.songCount, duration: detail.duration, coverArt: detail.coverArt)
    }

    func updatePlaylist(id: String, name: String? = nil, comment: String? = nil, songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = []) async throws {
        var params: [URLQueryItem] = [URLQueryItem(name: "playlistId", value: id)]
        if let name { params.append(URLQueryItem(name: "name", value: name)) }
        if let comment { params.append(URLQueryItem(name: "comment", value: comment)) }
        for songId in songIdsToAdd {
            params.append(URLQueryItem(name: "songIdToAdd", value: songId))
        }
        for index in songIndicesToRemove {
            params.append(URLQueryItem(name: "songIndexToRemove", value: "\(index)"))
        }
        _ = try await fetchSubsonic(endpoint: "updatePlaylist", params: params)
    }

    func getLyricsBySongId(songId: String) async throws -> StructuredLyrics? {
        let body = try await fetchSubsonic(endpoint: "getLyricsBySongId", params: [
            URLQueryItem(name: "id", value: songId)
        ])
        return body.lyricsList?.structuredLyrics?.first
    }

    func getAllAlbums(size: Int = 500, offset: Int = 0) async throws -> [Album] {
        try await getAlbumList(type: .alphabeticalByName, size: size, offset: offset)
    }

    func deletePlaylist(id: String) async throws {
        _ = try await fetchSubsonic(endpoint: "deletePlaylist", params: [
            URLQueryItem(name: "id", value: id)
        ])
    }
}

struct ServerInfo {
    let apiVersion: String
    let serverVersion: String?
    let serverType: String?
}

enum AlbumListType: String {
    case newest
    case recentlyPlayed = "recent"
    case frequent
    case random
    case starred
    case alphabeticalByName
    case alphabeticalByArtist
    case byYear
    case byGenre
}

enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case httpError
    case decodingError(Error)
    case serverError(String)
    case notFound
    case missingData

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(localized: "no_server_configured")
        case .invalidURL:
            return String(localized: "invalid_server_url")
        case .httpError:
            return String(localized: "http_error_from_server")
        case .decodingError(let e):
            return String(format: String(localized: "could_not_read_response_format"), e.localizedDescription)
        case .serverError(let msg):
            return String(format: String(localized: "server_error_format"), msg)
        case .notFound:
            return String(localized: "not_found")
        case .missingData:
            return String(localized: "unexpected_empty_response")
        }
    }
}
