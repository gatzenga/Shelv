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
    private var discoverLoadGeneration = 0
    private var albumLoadGeneration = 0
    private var artistLoadGeneration = 0
    private var starredLoadGeneration = 0
    private var playlistLoadGeneration = 0
    private var isRefreshingAlbums = false
    private var isRefreshingArtists = false
    private var isRefreshingStarred = false
    private var isRefreshingPlaylists = false
    private var refreshingAlbumIdentity: ServerIdentity?
    private var refreshingArtistIdentity: ServerIdentity?
    private var refreshingStarredIdentity: ServerIdentity?
    private var refreshingPlaylistIdentity: ServerIdentity?
    private var albumRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var artistRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var starredRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    private var playlistRefreshWaiters: [CheckedContinuation<Void, Never>] = []

    private struct ServerIdentity: Equatable {
        let id: UUID
        let serverKey: String
        let stableId: String?
        let baseURL: String
        let username: String
    }

    nonisolated static var libraryDir: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shelv_library", isDirectory: true)
    }

    nonisolated static func diskURL(name: String, serverID: UUID) -> URL {
        libraryDir.appendingPathComponent("\(name.pathSafeComponent)_\(serverID).json")
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

    private var selectedServer: SubsonicServer? {
        api.activeServer ?? ServerStore.shared.activeServer
    }

    private var activeServerID: UUID? { selectedServer?.id }

    private var activeServerSignature: String? {
        guard let server = selectedServer else { return nil }
        return "\(server.id.uuidString)|\(server.activeBaseURL)"
    }

    private var activeServerIdentity: ServerIdentity? {
        guard let server = selectedServer else { return nil }
        return ServerIdentity(
            id: server.id,
            serverKey: server.id.uuidString,
            stableId: server.stableId.isEmpty ? nil : server.stableId,
            baseURL: server.activeBaseURL,
            username: server.username
        )
    }

    private func isCurrentAlbumLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && albumLoadGeneration == generation
            && activeServerIdentity == identity
    }

    private func isCurrentArtistLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && artistLoadGeneration == generation
            && activeServerIdentity == identity
    }

    private func isCurrentStarredLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && starredLoadGeneration == generation
            && activeServerIdentity == identity
    }

    private func isCurrentPlaylistLoad(_ generation: Int, identity: ServerIdentity) -> Bool {
        !Task.isCancelled
            && playlistLoadGeneration == generation
            && activeServerIdentity == identity
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

    @discardableResult
    func loadDiscover() async -> Bool {
        guard !OfflineModeService.shared.isOffline else { return false }
        discoverLoadGeneration += 1
        let generation = discoverLoadGeneration
        let requestSignature = activeServerSignature
        isLoadingDiscover = true
        errorMessage = nil
        defer {
            if generation == discoverLoadGeneration {
                isLoadingDiscover = false
            }
        }

        do {
            async let added    = api.getRecentlyAdded(size: 20)
            async let played   = api.getRecentlyPlayed(size: 20)
            async let frequent = api.getFrequentlyPlayed(size: 20)
            let (a, p, f) = try await (added, played, frequent)
            guard generation == discoverLoadGeneration, requestSignature == activeServerSignature else { return false }
            recentlyAdded    = a
            recentlyPlayed   = p
            frequentlyPlayed = f
            if randomAlbums.isEmpty {
                let random = try await api.getAlbumList(type: "random", size: 20)
                guard generation == discoverLoadGeneration, requestSignature == activeServerSignature else { return false }
                randomAlbums = random
            }
            return true
        } catch {
            if generation == discoverLoadGeneration, !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func refreshRandomAlbums() async {
        guard !OfflineModeService.shared.isOffline else { return }
        let requestSignature = activeServerSignature
        do {
            let random = try await api.getAlbumList(type: "random", size: 20)
            guard requestSignature == activeServerSignature else { return }
            randomAlbums = random
        } catch {
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error)
            }
        }
    }

    func loadAlbums(sortBy: String = "alphabeticalByName") async {
        #if DEBUG
        if let count = DemoContent.largeLibraryFixtureAlbumCount {
            await applyLargeLibraryFixtureAlbums(count: count, sortBy: sortBy)
            return
        }
        #endif

        let requestedIdentity = activeServerIdentity
        if isRefreshingAlbums,
           refreshingAlbumIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                albumRefreshWaiters.append(continuation)
            }
            guard let identity = requestedIdentity,
                  activeServerIdentity == identity,
                  !Task.isCancelled
            else { return }
            await applyAlbumSort(sortBy: sortBy)
            return
        }
        isRefreshingAlbums = true
        refreshingAlbumIdentity = requestedIdentity
        albumLoadGeneration &+= 1
        let generation = albumLoadGeneration
        defer {
            if albumLoadGeneration == generation {
                isRefreshingAlbums = false
                refreshingAlbumIdentity = nil
                isLoadingAlbums = false
                let waiters = albumRefreshWaiters
                albumRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }
        isLoadingAlbums = albums.isEmpty
        errorMessage = nil

        if albums.isEmpty {
            let cacheSort = LibraryRepository.albumCacheSort(for: sortBy)
            let cached = await libraryRepository.cachedAlbums(
                serverKey: identity.serverKey,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
            guard isCurrentAlbumLoad(generation, identity: identity) else { return }
            if !cached.isEmpty {
                albums = cached
            } else {
                let serverID = identity.id
                let legacyCached: [Album]? = await Task.detached(priority: .userInitiated) {
                    Self.readFromDisk([Album].self, name: "albums", serverID: serverID)
                }.value
                guard isCurrentAlbumLoad(generation, identity: identity) else { return }
                if let legacyCached, !legacyCached.isEmpty {
                    albums = legacyCached
                    await libraryRepository.storeAlbums(
                        legacyCached,
                        serverKey: identity.serverKey,
                        stableId: identity.stableId
                    )
                    guard isCurrentAlbumLoad(generation, identity: identity) else { return }
                }
            }
        }

        guard !OfflineModeService.shared.isOffline else { return }

        do {
            let result = try await libraryRepository.refreshAlbums(
                serverKey: identity.serverKey,
                stableId: identity.stableId,
                sortBy: sortBy
            )
            guard isCurrentAlbumLoad(generation, identity: identity) else { return }
            albums = result
            UserDefaults.standard.set(result.count, forKey: "shelv_albumCount_\(identity.id)")
        } catch {
            if isCurrentAlbumLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applyAlbumSort(sortBy: String) async {
        let currentAlbums = albums
        #if DEBUG
        if DemoContent.isLargeLibraryFixtureEnabled {
            albums = LibraryRepository.locallySortedAlbums(currentAlbums, sortBy: sortBy)
            return
        }
        #endif

        if let identity = activeServerIdentity {
            let generation = albumLoadGeneration
            let cacheSort = LibraryRepository.albumCacheSort(for: sortBy)
            let cached = await libraryRepository.cachedAlbums(
                serverKey: identity.serverKey,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
            guard !Task.isCancelled,
                  generation == albumLoadGeneration,
                  activeServerIdentity == identity
            else { return }
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

        let requestedIdentity = activeServerIdentity
        if isRefreshingArtists,
           refreshingArtistIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                artistRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingArtists = true
        refreshingArtistIdentity = requestedIdentity
        artistLoadGeneration &+= 1
        let generation = artistLoadGeneration
        defer {
            if artistLoadGeneration == generation {
                isRefreshingArtists = false
                refreshingArtistIdentity = nil
                isLoadingArtists = false
                let waiters = artistRefreshWaiters
                artistRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }
        isLoadingArtists = artists.isEmpty
        errorMessage = nil

        if artists.isEmpty {
            let cached = await libraryRepository.cachedArtists(serverKey: identity.serverKey)
            guard isCurrentArtistLoad(generation, identity: identity) else { return }
            if !cached.isEmpty {
                artists = cached
            } else {
                let serverID = identity.id
                let legacyCached: [Artist]? = await Task.detached(priority: .userInitiated) {
                    Self.readFromDisk([Artist].self, name: "artists", serverID: serverID)
                }.value
                guard isCurrentArtistLoad(generation, identity: identity) else { return }
                if let legacyCached, !legacyCached.isEmpty {
                    artists = legacyCached
                    await libraryRepository.storeArtists(
                        legacyCached,
                        serverKey: identity.serverKey,
                        stableId: identity.stableId
                    )
                    guard isCurrentArtistLoad(generation, identity: identity) else { return }
                }
            }
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
            return
        }

        do {
            let result = try await libraryRepository.refreshArtists(
                serverKey: identity.serverKey,
                stableId: identity.stableId
            )
            guard isCurrentArtistLoad(generation, identity: identity) else { return }
            artists = result
            UserDefaults.standard.set(result.count, forKey: "shelv_artistCount_\(identity.id)")
            let map = Dictionary(result.compactMap { artist -> (String, String)? in
                guard let cover = artist.coverArt else { return nil }
                return (artist.name, cover)
            }, uniquingKeysWith: { first, _ in first })
            NotificationCenter.default.post(name: .libraryArtistsLoaded, object: map)
        } catch {
            if isCurrentArtistLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func resetInMemory() {
        albumLoadGeneration &+= 1
        artistLoadGeneration &+= 1
        starredLoadGeneration &+= 1
        playlistLoadGeneration &+= 1
        isRefreshingAlbums = false
        isRefreshingArtists = false
        isRefreshingStarred = false
        isRefreshingPlaylists = false
        refreshingAlbumIdentity = nil
        refreshingArtistIdentity = nil
        refreshingStarredIdentity = nil
        refreshingPlaylistIdentity = nil
        let waiters = albumRefreshWaiters
            + artistRefreshWaiters
            + starredRefreshWaiters
            + playlistRefreshWaiters
        albumRefreshWaiters.removeAll()
        artistRefreshWaiters.removeAll()
        starredRefreshWaiters.removeAll()
        playlistRefreshWaiters.removeAll()
        waiters.forEach { $0.resume() }
        isLoadingAlbums = false
        isLoadingArtists = false
        isLoadingStarred = false
        isLoadingPlaylists = false
        resetDiscoverInMemory()
        albums = []
        artists = []
        starredSongs = []
        starredAlbums = []
        starredArtists = []
        playlists = []
        reloadID = UUID()
    }

    func resetDiscoverInMemory() {
        discoverLoadGeneration += 1
        recentlyAdded = []
        recentlyPlayed = []
        frequentlyPlayed = []
        randomAlbums = []
        errorMessage = nil
        isLoadingDiscover = false
    }

    func stopDiscoverLoadingForConnectionRecovery() {
        discoverLoadGeneration += 1
        errorMessage = nil
        isLoadingDiscover = false
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
        let artistDetail: ArtistDetail
        do {
            artistDetail = try await api.getArtist(id: artist.id)
        } catch {
            _ = OfflineModeService.shared.presentConnectivityErrorIfNeeded(
                error,
                userInitiated: true
            )
            return []
        }
        guard let albums = artistDetail.album, !albums.isEmpty else { return [] }
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
        let requestedIdentity = activeServerIdentity
        if isRefreshingStarred,
           refreshingStarredIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                starredRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingStarred = true
        refreshingStarredIdentity = requestedIdentity
        starredLoadGeneration &+= 1
        let generation = starredLoadGeneration
        defer {
            if starredLoadGeneration == generation {
                isRefreshingStarred = false
                refreshingStarredIdentity = nil
                isLoadingStarred = false
                let waiters = starredRefreshWaiters
                starredRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }

        let serverID = identity.id
        let cached: StarredResult? = await Task.detached(priority: .userInitiated) {
            guard let songs = Self.readFromDisk([Song].self, name: "starred_songs", serverID: serverID),
                  let albums = Self.readFromDisk([Album].self, name: "starred_albums", serverID: serverID),
                  let artists = Self.readFromDisk([Artist].self, name: "starred_artists", serverID: serverID) else { return nil }
            return StarredResult(artist: artists, album: albums, song: songs)
        }.value
        guard isCurrentStarredLoad(generation, identity: identity) else { return }
        if let cached {
            starredSongs = cached.song ?? []
            starredAlbums = cached.album ?? []
            starredArtists = cached.artist ?? []
        }

        guard !OfflineModeService.shared.isOffline else { return }

        isLoadingStarred = starredSongs.isEmpty && starredAlbums.isEmpty && starredArtists.isEmpty
        do {
            let result = try await api.getStarred()
            guard isCurrentStarredLoad(generation, identity: identity) else { return }
            let songs = result.song ?? []
            let albums = result.album ?? []
            let artists = result.artist ?? []
            starredSongs = songs
            starredAlbums = albums
            starredArtists = artists
            save(songs, name: "starred_songs", serverID: serverID)
            save(albums, name: "starred_albums", serverID: serverID)
            save(artists, name: "starred_artists", serverID: serverID)
            if let stable = identity.stableId {
                let starredIds = Set(songs.map(\.id))
                await DownloadDatabase.shared.syncFavorites(serverId: stable, starredSongIds: starredIds)
                guard isCurrentStarredLoad(generation, identity: identity) else { return }
                NotificationCenter.default.post(name: .downloadsLibraryChanged, object: nil)
            }
        } catch {
            if isCurrentStarredLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
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
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            }
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
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            }
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
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            }
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
        let requestedIdentity = activeServerIdentity
        if isRefreshingPlaylists,
           refreshingPlaylistIdentity == requestedIdentity {
            await withCheckedContinuation { continuation in
                playlistRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingPlaylists = true
        refreshingPlaylistIdentity = requestedIdentity
        playlistLoadGeneration &+= 1
        let generation = playlistLoadGeneration
        defer {
            if playlistLoadGeneration == generation {
                isRefreshingPlaylists = false
                refreshingPlaylistIdentity = nil
                isLoadingPlaylists = false
                let waiters = playlistRefreshWaiters
                playlistRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }

        let serverID = identity.id
        let cached: [Playlist]? = await Task.detached(priority: .userInitiated) {
            Self.readFromDisk([Playlist].self, name: "playlists", serverID: serverID)
        }.value
        guard isCurrentPlaylistLoad(generation, identity: identity) else { return }
        if let cached, !cached.isEmpty { playlists = cached }

        guard !OfflineModeService.shared.isOffline else { return }

        isLoadingPlaylists = playlists.isEmpty
        do {
            let result = try await api.getPlaylists()
            guard isCurrentPlaylistLoad(generation, identity: identity) else { return }
            playlists = result
            save(result, name: "playlists", serverID: serverID)
        } catch {
            if isCurrentPlaylistLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
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
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            }
        }
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
        try await api.deletePlaylist(id: playlist.id)
        playlists.removeAll { $0.id == playlist.id }
        if let entry = await PlayLogService.shared.registryEntry(playlistId: playlist.id) {
            CloudKitSyncService.debugLog("[LibraryDelete] playlistId=\(playlist.id) was recap, deleting marker=\(entry.ckRecordName ?? "nil")")
            if let ckName = entry.ckRecordName {
                await CloudKitSyncService.shared.queueRecapMarkerDeletion(ckRecordName: ckName)
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
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            }
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
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            }
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
            if !(error is CancellationError) {
                errorMessage = OfflineModeService.shared.inlineErrorMessage(for: error, userInitiated: true)
            }
        }
    }
}

extension SubsonicAPIService {
    func getAllAlbums(size: Int = 500, offset: Int = 0, sortBy: String = "alphabeticalByName") async throws -> [Album] {
        try await getAlbumList(type: sortBy, size: size, offset: offset)
    }
}
