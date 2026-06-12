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

    private let api = SubsonicAPIService.shared

    func loadAlbums(sortBy: String = "alphabeticalByName") async {
        guard albums.isEmpty || isLoadingAlbums == false else { return }
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

    func playlistSongs(_ playlist: Playlist) async -> [Song] {
        (try? await api.getPlaylist(id: playlist.id).songs) ?? []
    }
}
