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
        guard !isLoadingAlbums else { return }
        isLoadingAlbums = true; defer { isLoadingAlbums = false }
        var all: [Album] = []
        let pageSize = 500
        var offset = 0
        do {
            while true {
                let page = try await api.getAlbumList(type: sortBy, size: pageSize, offset: offset)
                all.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
            }
            albums = all
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func loadArtists() async {
        isLoadingArtists = true; defer { isLoadingArtists = false }
        do { artists = try await api.getAllArtists() }
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
