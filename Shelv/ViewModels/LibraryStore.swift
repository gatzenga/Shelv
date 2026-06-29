import Foundation
import SwiftUI
import Combine

@MainActor
class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var albums: [Album] = []
    @Published var artists: [Artist] = []
    @Published var recentlyAdded: [Album] = []
    @Published var recentlyPlayed: [Album] = []
    @Published var frequentlyPlayed: [Album] = []
    @Published var randomAlbums: [Album] = []
    @Published var isLoadingAlbums: Bool = false
    @Published var isLoadingArtists: Bool = false
    @Published var isLoadingDiscover: Bool = false
    @Published var errorMessage: String?

    @Published var starredSongs: [Song] = []
    @Published var starredAlbums: [Album] = []
    @Published var starredArtists: [Artist] = []
    @Published var isLoadingStarred: Bool = false

    @Published var playlists: [Playlist] = []
    @Published var isLoadingPlaylists: Bool = false

    var isLoading: Bool { isLoadingAlbums || isLoadingArtists || isLoadingDiscover }

    @Published var reloadID = UUID()

    private let api = SubsonicAPIService.shared
    private let libraryRepository = LibraryRepository.shared

    nonisolated static var libraryDir: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_library", isDirectory: true)
    }

    nonisolated static func diskURL(name: String, serverID: UUID) -> URL {
        libraryDir.appendingPathComponent("\(name)_\(serverID).json")
    }

    nonisolated static func diskCacheSizeBytes() -> Int {
        FileManager.default.directorySize(at: libraryDir)
            + FileManager.default.directorySize(at: LibraryDatabase.defaultDBURL.deletingLastPathComponent())
    }

    private func save<T: Encodable>(_ value: T, name: String, serverID: UUID) {
        let url = Self.diskURL(name: name, serverID: serverID)
        guard let data = try? JSONEncoder().encode(value) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: Self.libraryDir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated private static func readFromDisk<T: Decodable>(_ type: T.Type, name: String, serverID: UUID) -> T? {
        let url = diskURL(name: name, serverID: serverID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private var activeServerID: UUID? { api.activeServer?.id }

    private var activeServerKeys: (serverKey: String, stableId: String?)? {
        guard let server = api.activeServer else { return nil }
        let stableId = server.stableId.isEmpty ? nil : server.stableId
        return (server.id.uuidString, stableId)
    }

    #if DEBUG
    private func applyLargeLibraryFixtureAlbums(count: Int, sortBy: String) async {
        guard !isLoadingAlbums else { return }
        isLoadingAlbums = albums.isEmpty
        errorMessage = nil

        let source: [Album]
        if albums.count == count, albums.first?.id.hasPrefix("fixture-album-") == true {
            source = albums
        } else {
            source = await Task.detached(priority: .userInitiated) {
                DemoContent.largeLibraryAlbums(count: count)
            }.value
        }

        albums = LibraryRepository.locallySortedAlbums(source, sortBy: sortBy)
        isLoadingAlbums = false
    }

    private func applyLargeLibraryFixtureArtists(albumCount: Int) async {
        guard !isLoadingArtists else { return }
        isLoadingArtists = artists.isEmpty
        errorMessage = nil

        if artists.first?.id.hasPrefix("fixture-artist-") != true {
            artists = await Task.detached(priority: .userInitiated) {
                DemoContent.largeLibraryArtists(albumCount: albumCount)
            }.value
        }

        isLoadingArtists = false
    }
    #endif

    func loadDiscover() async {
        guard !OfflineModeService.shared.isOffline else { return }
        isLoadingDiscover = true
        do {
            async let added    = api.getRecentlyAdded(size: 20)
            async let played   = api.getRecentlyPlayed(size: 20)
            async let frequent = api.getFrequentlyPlayed(size: 20)
            let (a, p, f) = try await (added, played, frequent)
            recentlyAdded    = a
            recentlyPlayed   = p
            frequentlyPlayed = f
            if randomAlbums.isEmpty {
                randomAlbums = try await api.getAlbumList(type: "random", size: 20)
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        isLoadingDiscover = false
    }

    func refreshRandomAlbums() async {
        guard !OfflineModeService.shared.isOffline else { return }
        do {
            randomAlbums = try await api.getAlbumList(type: "random", size: 20)
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func loadAlbums(sortBy: String = "alphabeticalByName") async {
        #if DEBUG
        if let count = DemoContent.largeLibraryFixtureAlbumCount {
            await applyLargeLibraryFixtureAlbums(count: count, sortBy: sortBy)
            return
        }
        #endif

        if albums.isEmpty, let keys = activeServerKeys {
            let cacheSort = LibraryRepository.albumCacheSort(for: sortBy)
            let cached = await libraryRepository.cachedAlbums(
                serverKey: keys.serverKey,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
            if !cached.isEmpty {
                albums = cached
            } else if let id = activeServerID {
                let serverID = id
                let legacyCached: [Album]? = await Task.detached(priority: .userInitiated) {
                    Self.readFromDisk([Album].self, name: "albums", serverID: serverID)
                }.value
                if let legacyCached, !legacyCached.isEmpty {
                    albums = legacyCached
                    await libraryRepository.storeAlbums(legacyCached, serverKey: keys.serverKey, stableId: keys.stableId)
                }
            }
        } else if albums.isEmpty, let id = activeServerID {
            let serverID = id
            let cached: [Album]? = await Task.detached(priority: .userInitiated) {
                Self.readFromDisk([Album].self, name: "albums", serverID: serverID)
            }.value
            if let cached, !cached.isEmpty { albums = cached }
        }

        guard !OfflineModeService.shared.isOffline else { isLoadingAlbums = false; return }

        isLoadingAlbums = albums.isEmpty

        do {
            guard let keys = activeServerKeys else {
                isLoadingAlbums = false
                return
            }
            let result = try await libraryRepository.refreshAlbums(
                serverKey: keys.serverKey,
                stableId: keys.stableId,
                sortBy: sortBy
            )
            albums = result
            if let id = activeServerID {
                UserDefaults.standard.set(result.count, forKey: "shelv_albumCount_\(id)")
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        isLoadingAlbums = false
    }

    func applyAlbumSort(sortBy: String) async {
        let currentAlbums = albums
        #if DEBUG
        if DemoContent.isLargeLibraryFixtureEnabled {
            albums = LibraryRepository.locallySortedAlbums(currentAlbums, sortBy: sortBy)
            return
        }
        #endif

        if let keys = activeServerKeys {
            let cacheSort = LibraryRepository.albumCacheSort(for: sortBy)
            let cached = await libraryRepository.cachedAlbums(
                serverKey: keys.serverKey,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
            if !cached.isEmpty || currentAlbums.isEmpty {
                albums = cached
                return
            }
        }
        albums = LibraryRepository.locallySortedAlbums(currentAlbums, sortBy: sortBy)
    }

    func loadArtists() async {
        #if DEBUG
        if let count = DemoContent.largeLibraryFixtureAlbumCount {
            await applyLargeLibraryFixtureArtists(albumCount: count)
            return
        }
        #endif

        if artists.isEmpty, let keys = activeServerKeys {
            let cached = await libraryRepository.cachedArtists(serverKey: keys.serverKey)
            if !cached.isEmpty {
                artists = cached
            } else if let id = activeServerID {
                let serverID = id
                let legacyCached: [Artist]? = await Task.detached(priority: .userInitiated) {
                    Self.readFromDisk([Artist].self, name: "artists", serverID: serverID)
                }.value
                if let legacyCached, !legacyCached.isEmpty {
                    artists = legacyCached
                    await libraryRepository.storeArtists(legacyCached, serverKey: keys.serverKey, stableId: keys.stableId)
                }
            }
        } else if artists.isEmpty, let id = activeServerID {
            let serverID = id
            let cached: [Artist]? = await Task.detached(priority: .userInitiated) {
                Self.readFromDisk([Artist].self, name: "artists", serverID: serverID)
            }.value
            if let cached, !cached.isEmpty { artists = cached }
        }

        guard !OfflineModeService.shared.isOffline else {
            // Notification auch aus Disk-Cache feuern damit DownloadStore.artistCoverByName befüllt wird
            let map = Dictionary(artists.compactMap { artist -> (String, String)? in
                guard let cover = artist.coverArt else { return nil }
                return (artist.name, cover)
            }, uniquingKeysWith: { first, _ in first })
            if !map.isEmpty {
                NotificationCenter.default.post(name: .libraryArtistsLoaded, object: map)
            }
            isLoadingArtists = false
            return
        }

        isLoadingArtists = artists.isEmpty

        do {
            guard let keys = activeServerKeys else {
                isLoadingArtists = false
                return
            }
            let result = try await libraryRepository.refreshArtists(
                serverKey: keys.serverKey,
                stableId: keys.stableId
            )
            artists = result
            if let id = activeServerID {
                UserDefaults.standard.set(result.count, forKey: "shelv_artistCount_\(id)")
            }
            let map = Dictionary(result.compactMap { artist -> (String, String)? in
                guard let cover = artist.coverArt else { return nil }
                return (artist.name, cover)
            }, uniquingKeysWith: { first, _ in first })
            NotificationCenter.default.post(name: .libraryArtistsLoaded, object: map)
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        isLoadingArtists = false
    }

    func resetInMemory() {
        albums = []
        artists = []
        recentlyAdded = []
        recentlyPlayed = []
        frequentlyPlayed = []
        randomAlbums = []
        starredSongs = []
        starredAlbums = []
        starredArtists = []
        playlists = []
        reloadID = UUID()
    }

    func clearCache() {
        resetInMemory()
        try? FileManager.default.removeItem(at: Self.libraryDir)
        Task {
            do {
                try await LibraryDatabase.shared.removeAllFiles()
            } catch {
                DBErrorLog.logPlayLog("LibraryStore clearCache: \(error.localizedDescription)")
            }
        }
    }

    func fetchAlbumSongs(_ album: Album) async throws -> [Song] {
        if OfflineModeService.shared.isOffline {
            return DownloadStore.shared.albums.first { $0.albumId == album.id }?.songs.map { $0.asSong() } ?? []
        }
        let detail = try await api.getAlbum(id: album.id)
        return detail.song ?? []
    }

    func fetchAllSongs(for artist: Artist) async -> [Song] {
        if OfflineModeService.shared.isOffline {
            return DownloadStore.shared.artists
                .first { $0.artistId == artist.id || $0.name == artist.name }?
                .albums.flatMap { $0.songs.map { $0.asSong() } } ?? []
        }
        guard let artistDetail = try? await api.getArtist(id: artist.id),
              let albums = artistDetail.album, !albums.isEmpty else { return [] }
        let indexed = Array(albums.enumerated())
        return await withTaskGroup(of: (Int, [Song]).self) { group in
            for (i, album) in indexed {
                group.addTask {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song else { return (i, []) }
                    return (i, songs)
                }
            }
            var results: [(Int, [Song])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        }
    }

    func loadStarred() async {
        if let id = activeServerID {
            let serverID = id
            let cached: StarredResult? = await Task.detached(priority: .userInitiated) {
                guard let songs = Self.readFromDisk([Song].self, name: "starred_songs", serverID: serverID),
                      let albums = Self.readFromDisk([Album].self, name: "starred_albums", serverID: serverID),
                      let artists = Self.readFromDisk([Artist].self, name: "starred_artists", serverID: serverID) else { return nil }
                return StarredResult(artist: artists, album: albums, song: songs)
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
            starredSongs   = result.song   ?? []
            starredAlbums  = result.album  ?? []
            starredArtists = result.artist ?? []
            if let id = activeServerID {
                save(starredSongs,   name: "starred_songs",   serverID: id)
                save(starredAlbums,  name: "starred_albums",  serverID: id)
                save(starredArtists, name: "starred_artists", serverID: id)
            }
            if let stable = api.activeServer?.stableId, !stable.isEmpty {
                let starredIds = Set(starredSongs.map(\.id))
                await DownloadDatabase.shared.syncFavorites(serverId: stable, starredSongIds: starredIds)
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        isLoadingStarred = false
    }

    func toggleStarSong(_ song: Song) async {
        let isStarred = starredSongs.contains(where: { $0.id == song.id })
        if isStarred {
            starredSongs.removeAll { $0.id == song.id }
        } else {
            starredSongs.insert(song, at: 0)
        }
        do {
            if isStarred {
                try await api.unstar(songId: song.id)
            } else {
                try await api.star(songId: song.id)
            }
            if let id = activeServerID { save(starredSongs, name: "starred_songs", serverID: id) }
        } catch {
            if isStarred {
                starredSongs.insert(song, at: 0)
            } else {
                starredSongs.removeAll { $0.id == song.id }
            }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func toggleStarAlbum(_ album: Album) async {
        let isStarred = starredAlbums.contains(where: { $0.id == album.id })
        if isStarred {
            starredAlbums.removeAll { $0.id == album.id }
        } else {
            starredAlbums.insert(album, at: 0)
        }
        do {
            if isStarred {
                try await api.unstar(albumId: album.id)
            } else {
                try await api.star(albumId: album.id)
            }
            if let id = activeServerID { save(starredAlbums, name: "starred_albums", serverID: id) }
        } catch {
            if isStarred {
                starredAlbums.insert(album, at: 0)
            } else {
                starredAlbums.removeAll { $0.id == album.id }
            }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func toggleStarArtist(_ artist: Artist) async {
        let isStarred = starredArtists.contains(where: { $0.id == artist.id })
        if isStarred {
            starredArtists.removeAll { $0.id == artist.id }
        } else {
            starredArtists.insert(artist, at: 0)
        }
        do {
            if isStarred {
                try await api.unstar(artistId: artist.id)
            } else {
                try await api.star(artistId: artist.id)
            }
            if let id = activeServerID { save(starredArtists, name: "starred_artists", serverID: id) }
        } catch {
            if isStarred {
                starredArtists.insert(artist, at: 0)
            } else {
                starredArtists.removeAll { $0.id == artist.id }
            }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func isSongStarred(_ song: Song) -> Bool {
        starredSongs.contains(where: { $0.id == song.id })
    }

    func isAlbumStarred(_ album: Album) -> Bool {
        starredAlbums.contains(where: { $0.id == album.id })
    }

    func isArtistStarred(_ artist: Artist) -> Bool {
        starredArtists.contains(where: { $0.id == artist.id })
    }

    func loadPlaylists() async {
        if let id = activeServerID {
            let serverID = id
            let cached: [Playlist]? = await Task.detached(priority: .userInitiated) {
                Self.readFromDisk([Playlist].self, name: "playlists", serverID: serverID)
            }.value
            if let cached, !cached.isEmpty { playlists = cached }
        }

        guard !OfflineModeService.shared.isOffline else { isLoadingPlaylists = false; return }

        isLoadingPlaylists = playlists.isEmpty
        do {
            let result = try await api.getPlaylists()
            playlists = result
            if let id = activeServerID { save(result, name: "playlists", serverID: id) }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
        isLoadingPlaylists = false
    }

    func loadPlaylistDetail(id: String) async -> Playlist? {
        if OfflineModeService.shared.isOffline {
            guard let serverID = activeServerID else { return nil }
            var playlist = await Task.detached(priority: .userInitiated) {
                Self.readFromDisk(Playlist.self, name: "playlist_\(id)", serverID: serverID)
            }.value
            let songs = await Task.detached(priority: .userInitiated) {
                Self.readFromDisk([Song].self, name: "playlist_songs_\(id)", serverID: serverID)
            }.value
            playlist?.songs = songs
            return playlist
        }
        do {
            let result = try await api.getPlaylist(id: id)
            if let serverID = activeServerID {
                save(result, name: "playlist_\(id)", serverID: serverID)
                if let songs = result.songs {
                    save(songs, name: "playlist_songs_\(id)", serverID: serverID)
                }
                let freshCount = result.songs?.count ?? result.songCount
                if let idx = playlists.firstIndex(where: { $0.id == id }) {
                    let p = playlists[idx]
                    playlists[idx] = Playlist(id: p.id, name: p.name, comment: p.comment,
                                              songCount: freshCount, duration: result.duration, coverArt: p.coverArt,
                                              created: p.created, changed: p.changed)
                } else {
                    playlists.append(Playlist(id: result.id, name: result.name, comment: result.comment,
                                              songCount: freshCount, duration: result.duration, coverArt: result.coverArt,
                                              created: result.created, changed: result.changed))
                }
                save(playlists, name: "playlists", serverID: serverID)
            }
            return result
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
            return nil
        }
    }

    func createPlaylist(name: String, songIds: [String] = []) async {
        do {
            let created = try await api.createPlaylist(name: name, songIds: songIds)
            playlists.append(created)
            if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
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
        if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
    }

    func renamePlaylist(_ playlist: Playlist, newName: String, newComment: String? = nil) async {
        do {
            try await api.updatePlaylist(id: playlist.id, name: newName, comment: newComment)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                let updated = Playlist(
                    id: playlist.id, name: newName, comment: newComment ?? playlist.comment,
                    songCount: playlist.songCount, duration: playlist.duration, coverArt: playlist.coverArt,
                    created: playlist.created, changed: playlist.changed
                )
                playlists[idx] = updated
            }
            if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func addSongsToPlaylist(_ playlist: Playlist, songIds: [String]) async -> Bool {
        do {
            try await api.updatePlaylist(id: playlist.id, songIdsToAdd: songIds)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                let p = playlists[idx]
                playlists[idx] = Playlist(id: p.id, name: p.name, comment: p.comment,
                                          songCount: (p.songCount ?? 0) + songIds.count,
                                          duration: p.duration, coverArt: p.coverArt,
                                          created: p.created, changed: p.changed)
                if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
            }
            return true
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
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
                                          duration: p.duration, coverArt: p.coverArt,
                                          created: p.created, changed: p.changed)
                if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }
}

extension SubsonicAPIService {
    func getAllAlbums(size: Int = 500, offset: Int = 0, sortBy: String = "alphabeticalByName") async throws -> [Album] {
        try await getAlbumList(type: sortBy, size: size, offset: offset)
    }
}
