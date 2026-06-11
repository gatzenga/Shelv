import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    static let shared = LibraryViewModel()

    @Published var albums: [Album] = []
    @Published var artists: [Artist] = []
    @Published var sortOption: LibrarySortOption = .name
    @Published var albumSortDirection: SortDirection = .ascending
    @Published var artistSortOption: ArtistSortOption = .name
    @Published var artistSortDirection: SortDirection = .ascending
    @Published var isLoadingAlbums: Bool = false
    @Published var isLoadingArtists: Bool = false
    @Published var errorMessage: String?

    var sortedAlbums: [Album] {
        // Name immer A-Z, unabhängig von direction
        if sortOption == .name { return albums }
        return albumSortDirection == sortOption.naturalDirection
            ? albums
            : Array(albums.reversed())
    }

    var sortedArtists: [Artist] {
        let base: [Artist]
        switch artistSortOption {
        case .name:
            return artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .mostPlayed:
            let counts = Dictionary(grouping: albums, by: { $0.artistId ?? "" })
                .mapValues { $0.compactMap { $0.playCount }.reduce(0, +) }
            base = artists.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
        }
        return artistSortDirection == artistSortOption.naturalDirection
            ? base
            : Array(base.reversed())
    }

    // MARK: - Favorites
    @Published var starredSongs: [Song] = []
    @Published var starredAlbums: [Album] = []
    @Published var starredArtists: [Artist] = []
    @Published var isLoadingStarred: Bool = false

    // MARK: - Playlists
    @Published var playlists: [Playlist] = []
    @Published var isLoadingPlaylists: Bool = false

    private let api = SubsonicAPIService.shared

    // MARK: - Reset (bei Serverwechsel)

    func reset() {
        albums = []
        artists = []
        starredSongs = []
        starredAlbums = []
        starredArtists = []
        playlists = []
        errorMessage = nil
    }

    // MARK: - Albums

    func loadAlbums() async {
        guard !isLoadingAlbums else { return }
        guard !OfflineModeService.shared.isOffline else { isLoadingAlbums = false; return }

        if albums.isEmpty, let sid = AppState.shared.serverStore.activeServer?.stableId, !sid.isEmpty {
            let cached: [Album]? = await Task.detached(priority: .utility) {
                LibraryViewModel.loadLibraryCache([Album].self, name: "albums", serverId: sid)
            }.value
            if let cached, !cached.isEmpty { albums = cached }
        }

        isLoadingAlbums = albums.isEmpty
        errorMessage = nil
        do {
            // "year" und "mostPlayed" client-seitig sortieren, damit auch Alben ohne
            // Plays/Jahr in der Liste erscheinen. "recentlyAdded" bleibt serverseitig.
            let type: AlbumListType
            switch sortOption {
            case .name, .year, .mostPlayed: type = .alphabeticalByName
            case .recentlyAdded:            type = .newest
            }
            var all: [Album] = []
            let pageSize = 500
            var offset = 0
            while true {
                let page = try await api.getAlbumList(type: type, size: pageSize, offset: offset)
                all.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
            }
            albums = all
            if sortOption == .year {
                albums = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
            } else if sortOption == .mostPlayed {
                albums = albums.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
            }
            if let sid = AppState.shared.serverStore.activeServer?.stableId, !sid.isEmpty {
                let toSave = all
                Task.detached(priority: .utility) {
                    LibraryViewModel.saveLibraryCache(toSave, name: "albums", serverId: sid)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingAlbums = false
    }

    // MARK: - Artists

    func loadArtists() async {
        guard !isLoadingArtists else { return }
        guard !OfflineModeService.shared.isOffline else { isLoadingArtists = false; return }

        if artists.isEmpty, let sid = AppState.shared.serverStore.activeServer?.stableId, !sid.isEmpty {
            let cached: [Artist]? = await Task.detached(priority: .utility) {
                LibraryViewModel.loadLibraryCache([Artist].self, name: "artists", serverId: sid)
            }.value
            if let cached, !cached.isEmpty { artists = cached }
        }

        isLoadingArtists = artists.isEmpty
        errorMessage = nil
        do {
            artists = try await api.getAllArtists()
            artists = artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if let sid = AppState.shared.serverStore.activeServer?.stableId, !sid.isEmpty {
                let toSave = artists
                Task.detached(priority: .utility) {
                    LibraryViewModel.saveLibraryCache(toSave, name: "artists", serverId: sid)
                }
            }
            let map = Dictionary(artists.compactMap { artist -> (String, String)? in
                guard let cover = artist.coverArt else { return nil }
                return (artist.name, cover)
            }, uniquingKeysWith: { first, _ in first })
            NotificationCenter.default.post(name: .libraryArtistsLoaded, object: map)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingArtists = false
    }

    func applySortToAlbums() {
        switch sortOption {
        case .name:
            albums = albums.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .mostPlayed:
            albums = albums.sorted { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .recentlyAdded:
            break // already sorted by server
        case .year:
            albums = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }

    // MARK: - Starred / Favorites

    func loadStarred() async {
        if let serverId = AppState.shared.serverStore.activeServer?.stableId, !serverId.isEmpty {
            let sid = serverId
            let cached: Starred2Result? = await Task.detached(priority: .utility) {
                LibraryViewModel.loadStarredCache(serverId: sid)
            }.value
            if let cached {
                starredSongs = cached.song ?? []
                starredAlbums = cached.album ?? []
                starredArtists = cached.artist ?? []
            }
        }

        guard !OfflineModeService.shared.isOffline else { isLoadingStarred = false; return }
        isLoadingStarred = starredSongs.isEmpty && starredAlbums.isEmpty && starredArtists.isEmpty

        do {
            let result = try await api.getStarred()
            starredSongs = result.song ?? []
            starredAlbums = result.album ?? []
            starredArtists = result.artist ?? []
            if let serverId = AppState.shared.serverStore.activeServer?.stableId, !serverId.isEmpty {
                let sid = serverId
                let songs = starredSongs; let albums = starredAlbums; let artists = starredArtists
                Task.detached(priority: .utility) {
                    LibraryViewModel.saveStarredCache(songs: songs, albums: albums, artists: artists, serverId: sid)
                }
                let starredIds = Set(starredSongs.map(\.id))
                await DownloadDatabase.shared.syncFavorites(serverId: sid, starredSongIds: starredIds)
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingStarred = false
    }

    func isSongStarred(_ song: Song) -> Bool {
        starredSongs.contains { $0.id == song.id }
    }

    func isAlbumStarred(_ album: Album) -> Bool {
        starredAlbums.contains { $0.id == album.id }
    }

    func isArtistStarred(_ artist: Artist) -> Bool {
        starredArtists.contains { $0.id == artist.id }
    }

    func toggleStarSong(_ song: Song) async {
        let wasStarred = isSongStarred(song)
        // Optimistic update
        if wasStarred {
            starredSongs.removeAll { $0.id == song.id }
        } else {
            starredSongs.append(song)
        }
        do {
            if wasStarred {
                try await api.unstar(songId: song.id)
            } else {
                try await api.star(songId: song.id)
            }
        } catch {
            // Rollback
            if wasStarred {
                starredSongs.append(song)
            } else {
                starredSongs.removeAll { $0.id == song.id }
            }
            errorMessage = error.localizedDescription
        }
    }

    func toggleStarAlbum(_ album: Album) async {
        let wasStarred = isAlbumStarred(album)
        if wasStarred {
            starredAlbums.removeAll { $0.id == album.id }
        } else {
            starredAlbums.append(album)
        }
        do {
            if wasStarred {
                try await api.unstar(albumId: album.id)
            } else {
                try await api.star(albumId: album.id)
            }
        } catch {
            if wasStarred {
                starredAlbums.append(album)
            } else {
                starredAlbums.removeAll { $0.id == album.id }
            }
            errorMessage = error.localizedDescription
        }
    }

    func toggleStarArtist(_ artist: Artist) async {
        let wasStarred = isArtistStarred(artist)
        if wasStarred {
            starredArtists.removeAll { $0.id == artist.id }
        } else {
            starredArtists.append(artist)
        }
        do {
            if wasStarred {
                try await api.unstar(artistId: artist.id)
            } else {
                try await api.star(artistId: artist.id)
            }
        } catch {
            if wasStarred {
                starredArtists.append(artist)
            } else {
                starredArtists.removeAll { $0.id == artist.id }
            }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Playlists

    func loadPlaylists() async {
        if playlists.isEmpty, let serverId = AppState.shared.serverStore.activeServer?.stableId {
            playlists = loadPlaylistsCache(serverId: serverId)
        }
        guard !OfflineModeService.shared.isOffline else { isLoadingPlaylists = false; return }
        isLoadingPlaylists = playlists.isEmpty
        do {
            playlists = try await api.getPlaylists()
            if let serverId = AppState.shared.serverStore.activeServer?.stableId {
                savePlaylistsCache(playlists, serverId: serverId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingPlaylists = false
    }

    func loadPlaylistDetail(id: String) async -> PlaylistDetail? {
        if OfflineModeService.shared.isOffline {
            return loadPlaylistDetailCache(id: id)
        }
        do {
            let detail = try await api.getPlaylist(id: id)
            savePlaylistDetailCache(detail)
            let freshCount = detail.songs?.count ?? detail.songCount
            if let idx = playlists.firstIndex(where: { $0.id == id }) {
                let p = playlists[idx]
                playlists[idx] = Playlist(id: p.id, name: p.name, comment: p.comment,
                                          songCount: freshCount, duration: detail.duration, coverArt: p.coverArt)
            }
            return detail
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    nonisolated private static var libraryCacheDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_library_cache")
    }

    nonisolated private static func saveLibraryCache<T: Encodable>(_ value: T, name: String, serverId: String) {
        let dir = libraryCacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: dir.appendingPathComponent("\(name)_\(serverId).json"))
    }

    nonisolated private static func loadLibraryCache<T: Decodable>(_ type: T.Type, name: String, serverId: String) -> T? {
        let url = libraryCacheDir.appendingPathComponent("\(name)_\(serverId).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static var playlistCacheDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_playlist_cache")
    }

    nonisolated private static var starredCacheDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_starred_cache")
    }

    nonisolated private static func saveStarredCache(songs: [Song], albums: [Album], artists: [Artist], serverId: String) {
        let dir = starredCacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(songs).write(to: dir.appendingPathComponent("starred_songs_\(serverId).json"))
        try? JSONEncoder().encode(albums).write(to: dir.appendingPathComponent("starred_albums_\(serverId).json"))
        try? JSONEncoder().encode(artists).write(to: dir.appendingPathComponent("starred_artists_\(serverId).json"))
    }

    nonisolated private static func loadStarredCache(serverId: String) -> Starred2Result? {
        let dir = starredCacheDir
        let dec = JSONDecoder()
        let songs   = (try? Data(contentsOf: dir.appendingPathComponent("starred_songs_\(serverId).json")))
            .flatMap { try? dec.decode([Song].self, from: $0) }
        let albums  = (try? Data(contentsOf: dir.appendingPathComponent("starred_albums_\(serverId).json")))
            .flatMap { try? dec.decode([Album].self, from: $0) }
        let artists = (try? Data(contentsOf: dir.appendingPathComponent("starred_artists_\(serverId).json")))
            .flatMap { try? dec.decode([Artist].self, from: $0) }
        guard songs != nil || albums != nil || artists != nil else { return nil }
        return Starred2Result(artist: artists, album: albums, song: songs)
    }

    private func savePlaylistsCache(_ playlists: [Playlist], serverId: String) {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_list_\(serverId).json")
        try? FileManager.default.createDirectory(at: Self.playlistCacheDir, withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func loadPlaylistsCache(serverId: String) -> [Playlist] {
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_list_\(serverId).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
    }

    private func savePlaylistDetailCache(_ detail: PlaylistDetail) {
        let dir = Self.playlistCacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("playlist_\(detail.id).json")
        try? JSONEncoder().encode(detail).write(to: url)
    }

    private func loadPlaylistDetailCache(id: String) -> PlaylistDetail? {
        let url = Self.playlistCacheDir.appendingPathComponent("playlist_\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlaylistDetail.self, from: data)
    }

    func createPlaylist(name: String) async {
        do {
            let created = try await api.createPlaylist(name: name)
            playlists.append(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await api.deletePlaylist(id: playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            if let entry = await PlayLogService.shared.registryEntry(playlistId: playlist.id) {
                CloudKitSyncService.debugLog("[LibraryDelete] playlistId=\(playlist.id) was recap, deleting marker=\(entry.ckRecordName ?? "nil")")
                if let ckName = entry.ckRecordName {
                    await CloudKitSyncService.shared.deleteRecapMarker(ckRecordName: ckName)
                }
                await PlayLogService.shared.deleteRegistryEntry(playlistId: playlist.id)
                NotificationCenter.default.post(name: .recapRegistryUpdated, object: nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renamePlaylist(_ playlist: Playlist, newName: String) async {
        do {
            try await api.updatePlaylist(id: playlist.id, name: newName)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[idx] = Playlist(id: playlist.id, name: newName, comment: playlist.comment,
                                          songCount: playlist.songCount, duration: playlist.duration,
                                          coverArt: playlist.coverArt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addSongsToPlaylist(_ playlist: Playlist, songIds: [String]) async -> Bool {
        do {
            try await api.updatePlaylist(id: playlist.id, songIdsToAdd: songIds)
            if let refreshed = try? await api.getPlaylists() {
                playlists = refreshed
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeSongsFromPlaylist(_ playlist: Playlist, indices: [Int]) async {
        do {
            try await api.updatePlaylist(id: playlist.id, songIndicesToRemove: indices)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                let p = playlists[idx]
                playlists[idx] = Playlist(id: p.id, name: p.name, comment: p.comment,
                                          songCount: max(0, (p.songCount ?? 0) - indices.count),
                                          duration: p.duration, coverArt: p.coverArt)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func syncPlaylistOrder(_ playlist: Playlist, songs: [Song]) async {
        // Remove all songs and re-add in desired order
        let count = songs.count
        guard count > 0 else { return }
        let removeIndices = Array(0..<count)
        do {
            try await api.updatePlaylist(id: playlist.id, songIndicesToRemove: removeIndices)
            try await api.updatePlaylist(id: playlist.id, songIdsToAdd: songs.map(\.id))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
