import Foundation

// Übergangs-Schicht: bildet die historischen macOS-API-Signaturen auf die
// geteilte SubsonicAPIService-Implementierung (ShelvCore) ab. Aufrufer können
// schrittweise auf die geteilten Signaturen umgestellt werden; danach kann
// diese Datei schrumpfen bzw. verschwinden.

typealias SearchResult3 = SearchResult
typealias Starred2Result = StarredResult

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

extension SubsonicAPIService {
    // MARK: - ServerConfig-Pfad (Login-Flow der Mac-App)

    func setConfig(_ config: ServerConfig) {
        let server = SubsonicServer(baseURL: config.serverURL, username: config.username)
        setCredentials(server: server, password: config.password)
    }

    func clearConfig() {
        activeServer = nil
        activePassword = nil
    }

    var hasConfig: Bool {
        guard activeServer != nil else { return false }
        #if DEBUG
        if isDemoActive { return true }   // Demo-Server ist bewusst passwortlos
        #endif
        return activePassword?.isEmpty == false
    }

    var currentConfig: ServerConfig? {
        guard let server = activeServer, let password = activePassword else { return nil }
        return ServerConfig(serverURL: server.baseURL, username: server.username, password: password)
    }

    /// auth/login mit den aktiven Credentials (Navidrome-User-ID für stableId).
    func authLogin() async throws -> String {
        guard let server = activeServer else { throw SubsonicAPIError.noServer }
        guard let password = activePassword ?? KeychainService.load(for: server.id) else {
            throw SubsonicAPIError.noPassword
        }
        return try await authLogin(server: server, password: password)
    }

    // MARK: - Signatur-Aliase

    func getAlbumList(type: AlbumListType, size: Int = 50, offset: Int = 0) async throws -> [Album] {
        try await getAlbumList(type: type.rawValue, size: size, offset: offset)
    }

    func streamURL(songId: String, timeOffset: Int = 0) -> URL? {
        streamURL(for: songId, timeOffset: timeOffset)
    }

    func rawStreamURL(songId: String) -> URL? {
        rawStreamURL(for: songId)
    }

    func downloadURL(songId: String) -> URL? {
        downloadURL(for: songId)
    }

    func coverArtURL(id: String, size: Int? = nil) -> URL? {
        coverArtURL(for: id, size: size ?? 300)
    }

    func downloadURL(forConfig cfg: ServerConfig, songId: String,
                     transcoding: (codec: TranscodingCodec, bitrate: Int)? = nil) -> URL? {
        let server = SubsonicServer(baseURL: cfg.serverURL, username: cfg.username)
        return downloadURL(for: songId, server: server, password: cfg.password, transcoding: transcoding)
    }

    func coverArtURL(forConfig cfg: ServerConfig, id: String, size: Int? = nil) -> URL? {
        let server = SubsonicServer(baseURL: cfg.serverURL, username: cfg.username)
        return coverArtURL(for: id, server: server, password: cfg.password, size: size ?? 600)
    }
}
