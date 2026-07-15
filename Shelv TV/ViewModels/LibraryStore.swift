import SwiftUI
import Combine

/// Schlanker Library-Store für tvOS: lädt Alben/Künstler/Favoriten/Playlists über die
/// geteilte API. Kein Disk-Cache (tvOS-Speicher nicht garantiert) — bei Bedarf neu laden.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    private init() {}

    @Published var albums: [Album] = []
    @Published var artists: [Artist] = []
    @Published var favoriteSongs: [Song] = []
    @Published var favoriteAlbums: [Album] = []
    @Published var favoriteArtists: [Artist] = []
    @Published var playlists: [Playlist] = []

    @Published var isLoadingAlbums = false
    @Published var isLoadingArtists = false
    @Published var isLoadingPlaylists = false
    @Published var errorMessage: String?

    /// Wechselt bei Server-Wechsel — Views hängen ihre `.task(id:)` daran und laden neu.
    @Published var reloadID = UUID()

    private let api = SubsonicAPIService.shared
    private let libraryRepository = LibraryRepository.shared
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

    private var activeServerIdentity: ServerIdentity? {
        guard let server = api.activeServer else { return nil }
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

    /// Alle In-Memory-Daten leeren + Reload anstoßen (wie iOS). Beim Server-Wechsel aufgerufen,
    /// nachdem der Player gestoppt wurde — sonst bleiben Alben/Favoriten/Playlists des alten Servers.
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
        isLoadingPlaylists = false
        albums = []
        artists = []
        favoriteSongs = []
        favoriteAlbums = []
        favoriteArtists = []
        playlists = []
        reloadID = UUID()
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
            if !cached.isEmpty { albums = cached }
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
        } catch {
            if isCurrentAlbumLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyAlbumSort(sortBy: String) async {
        let currentAlbums = albums
        #if DEBUG
        if DemoContent.isLargeLibraryFixtureEnabled {
            albums = LibraryRepository.locallySortedAlbums(currentAlbums, sortBy: sortBy)
            return
        }
        #endif

        guard let identity = activeServerIdentity else {
            albums = LibraryRepository.locallySortedAlbums(currentAlbums, sortBy: sortBy)
            return
        }
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
        } else {
            albums = LibraryRepository.locallySortedAlbums(currentAlbums, sortBy: sortBy)
        }
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
            if !cached.isEmpty { artists = cached }
        }

        guard !OfflineModeService.shared.isOffline else { return }

        do {
            let result = try await libraryRepository.refreshArtists(
                serverKey: identity.serverKey,
                stableId: identity.stableId
            )
            guard isCurrentArtistLoad(generation, identity: identity) else { return }
            artists = result
        }
        catch {
            if isCurrentArtistLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
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
                let waiters = starredRefreshWaiters
                starredRefreshWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        guard let identity = requestedIdentity,
              activeServerIdentity == identity
        else { return }

        do {
            let r = try await api.getStarred()
            guard isCurrentStarredLoad(generation, identity: identity) else { return }
            favoriteSongs = r.song ?? []
            favoriteAlbums = r.album ?? []
            favoriteArtists = r.artist ?? []
        } catch {
            if isCurrentStarredLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
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
        isLoadingPlaylists = true
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

        do {
            let result = try await api.getPlaylists()
            guard isCurrentPlaylistLoad(generation, identity: identity) else { return }
            playlists = result
        } catch {
            if isCurrentPlaylistLoad(generation, identity: identity),
               !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func albumSongs(_ album: Album) async -> [Song] {
        (try? await api.getAlbum(id: album.id).song) ?? []
    }

    func artistDetail(_ artist: Artist) async -> ArtistDetail? {
        try? await api.getArtist(id: artist.id)
    }

    /// Alle Songs eines Künstlers (über alle Alben, parallel geladen) — für Play/Shuffle.
    func artistSongs(_ artist: Artist) async -> [Song] {
        guard let detail = try? await api.getArtist(id: artist.id) else { return [] }
        let api = self.api
        let albums = detail.album ?? []
        var all: [Song] = []
        await withTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask { (try? await api.getAlbum(id: album.id).song) ?? [] }
            }
            for await songs in group { all.append(contentsOf: songs) }
        }
        return all
    }

    func playlistSongs(_ playlist: Playlist) async -> [Song] {
        (try? await api.getPlaylist(id: playlist.id).songs) ?? []
    }

    // MARK: - Favoriten (optimistisch + Rollback)

    func isSongStarred(_ song: Song) -> Bool { favoriteSongs.contains { $0.id == song.id } }
    func isAlbumStarred(_ album: Album) -> Bool { favoriteAlbums.contains { $0.id == album.id } }
    func isArtistStarred(_ artist: Artist) -> Bool { favoriteArtists.contains { $0.id == artist.id } }

    func toggleStarSong(_ song: Song) async {
        let wasStarred = isSongStarred(song)
        if wasStarred { favoriteSongs.removeAll { $0.id == song.id } }
        else { favoriteSongs.insert(song, at: 0) }
        do {
            if wasStarred { try await api.unstar(songId: song.id) }
            else { try await api.star(songId: song.id) }
        } catch {
            if wasStarred { favoriteSongs.insert(song, at: 0) }
            else { favoriteSongs.removeAll { $0.id == song.id } }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func toggleStarAlbum(_ album: Album) async {
        let wasStarred = isAlbumStarred(album)
        if wasStarred { favoriteAlbums.removeAll { $0.id == album.id } }
        else { favoriteAlbums.insert(album, at: 0) }
        do {
            if wasStarred { try await api.unstar(albumId: album.id) }
            else { try await api.star(albumId: album.id) }
        } catch {
            if wasStarred { favoriteAlbums.insert(album, at: 0) }
            else { favoriteAlbums.removeAll { $0.id == album.id } }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func toggleStarArtist(_ artist: Artist) async {
        let wasStarred = isArtistStarred(artist)
        if wasStarred { favoriteArtists.removeAll { $0.id == artist.id } }
        else { favoriteArtists.insert(artist, at: 0) }
        do {
            if wasStarred { try await api.unstar(artistId: artist.id) }
            else { try await api.star(artistId: artist.id) }
        } catch {
            if wasStarred { favoriteArtists.insert(artist, at: 0) }
            else { favoriteArtists.removeAll { $0.id == artist.id } }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Playlist-Verwaltung

    func createPlaylist(name: String, songIds: [String] = []) async {
        do {
            _ = try await api.createPlaylist(name: name, songIds: songIds)
            await loadPlaylists()
        } catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
    }

    func renamePlaylist(_ playlist: Playlist, name: String, comment: String?) async {
        do {
            try await api.updatePlaylist(id: playlist.id, name: name, comment: comment)
            await loadPlaylists()
        } catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        do {
            try await api.deletePlaylist(id: playlist.id)
            playlists.removeAll { $0.id == playlist.id }
            if PinnedPlaylistStore.shared.isPinned(playlist.id) {
                PinnedPlaylistStore.shared.togglePin(playlist.id)
            }
        } catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
    }

    func addSongs(_ songIds: [String], toPlaylist id: String) async {
        do { try await api.updatePlaylist(id: id, songIdsToAdd: songIds) }
        catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
    }
}
