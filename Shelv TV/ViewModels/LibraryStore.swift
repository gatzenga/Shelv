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

    /// Alle In-Memory-Daten leeren + Reload anstoßen (wie iOS). Beim Server-Wechsel aufgerufen,
    /// nachdem der Player gestoppt wurde — sonst bleiben Alben/Favoriten/Playlists des alten Servers.
    func resetInMemory() {
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

        guard !isLoadingAlbums else { return }
        isLoadingAlbums = true; defer { isLoadingAlbums = false }

        if albums.isEmpty, let keys = activeServerKeys {
            let cacheSort = LibraryRepository.albumCacheSort(for: sortBy)
            let cached = await libraryRepository.cachedAlbums(
                serverKey: keys.serverKey,
                sort: cacheSort.0,
                direction: cacheSort.1
            )
            if !cached.isEmpty { albums = cached }
        }

        guard !OfflineModeService.shared.isOffline else { return }

        do {
            guard let keys = activeServerKeys else { return }
            albums = try await libraryRepository.refreshAlbums(
                serverKey: keys.serverKey,
                stableId: keys.stableId,
                sortBy: sortBy
            )
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func loadArtists() async {
        #if DEBUG
        if let count = DemoContent.largeLibraryFixtureAlbumCount {
            await applyLargeLibraryFixtureArtists(albumCount: count)
            return
        }
        #endif

        isLoadingArtists = true; defer { isLoadingArtists = false }
        if artists.isEmpty, let keys = activeServerKeys {
            let cached = await libraryRepository.cachedArtists(serverKey: keys.serverKey)
            if !cached.isEmpty { artists = cached }
        }

        guard !OfflineModeService.shared.isOffline else { return }

        do {
            guard let keys = activeServerKeys else { return }
            artists = try await libraryRepository.refreshArtists(serverKey: keys.serverKey, stableId: keys.stableId)
        }
        catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
    }

    func loadStarred() async {
        do {
            let r = try await api.getStarred()
            favoriteSongs = r.song ?? []
            favoriteAlbums = r.album ?? []
            favoriteArtists = r.artist ?? []
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func loadPlaylists() async {
        isLoadingPlaylists = true; defer { isLoadingPlaylists = false }
        do { playlists = try await api.getPlaylists() }
        catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
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
        let albums = detail.album ?? []
        return await PlaybackContentResolver.artistSongs(from: albums) { [api] albumID in
            (try? await api.getAlbum(id: albumID).song) ?? []
        }
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
