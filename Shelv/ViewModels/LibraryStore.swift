import Foundation
import SwiftUI
import Combine

@MainActor
class LibraryStore: ObservableObject {
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

    // Favoriten
    @Published var starredSongs: [Song] = []
    @Published var starredAlbums: [Album] = []
    @Published var starredArtists: [Artist] = []
    @Published var isLoadingStarred: Bool = false

    // Playlists
    @Published var playlists: [Playlist] = []
    @Published var isLoadingPlaylists: Bool = false

    var isLoading: Bool { isLoadingAlbums || isLoadingArtists || isLoadingDiscover }

    private let api = SubsonicAPIService.shared

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
    }

    private func save<T: Encodable>(_ value: T, name: String, serverID: UUID) {
        let url = Self.diskURL(name: name, serverID: serverID)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
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

    func loadDiscover() async {
        isLoadingDiscover = true
        do {
            async let added    = api.getRecentlyAdded(size: 20)
            async let played   = api.getRecentlyPlayed(size: 20)
            async let frequent = api.getFrequentlyPlayed(size: 20)
            async let random   = api.getAlbumList(type: "random", size: 20)
            let (a, p, f, r) = try await (added, played, frequent, random)
            recentlyAdded    = a
            recentlyPlayed   = p
            frequentlyPlayed = f
            randomAlbums     = r
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingDiscover = false
    }

    func refreshRandomAlbums() async {
        do {
            randomAlbums = try await api.getAlbumList(type: "random", size: 20)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadAlbums(sortBy: String = "alphabeticalByName") async {
        if albums.isEmpty, let id = activeServerID {
            let serverID = id
            let cached: [Album]? = await Task.detached(priority: .utility) {
                Self.readFromDisk([Album].self, name: "albums", serverID: serverID)
            }.value
            if let cached, !cached.isEmpty { albums = cached }
        }

        isLoadingAlbums = albums.isEmpty

        do {
            var result: [Album] = []
            var offset = 0
            let pageSize = 500
            while true {
                let page = try await api.getAllAlbums(size: pageSize, offset: offset, sortBy: sortBy)
                result.append(contentsOf: page)
                if page.count < pageSize { break }
                offset += pageSize
            }
            albums = result
            if let id = activeServerID {
                save(result, name: "albums", serverID: id)
                UserDefaults.standard.set(result.count, forKey: "shelv_albumCount_\(id)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingAlbums = false
    }

    func loadArtists() async {
        if artists.isEmpty, let id = activeServerID {
            let serverID = id
            let cached: [Artist]? = await Task.detached(priority: .utility) {
                Self.readFromDisk([Artist].self, name: "artists", serverID: serverID)
            }.value
            if let cached, !cached.isEmpty { artists = cached }
        }

        isLoadingArtists = artists.isEmpty

        do {
            let result = try await api.getAllArtists()
            artists = result
            if let id = activeServerID {
                save(result, name: "artists", serverID: id)
                UserDefaults.standard.set(result.count, forKey: "shelv_artistCount_\(id)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingArtists = false
    }

    func clearCache() {
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
        try? FileManager.default.removeItem(at: Self.libraryDir)
    }

    // MARK: - Favoriten

    func loadStarred() async {
        if let id = activeServerID {
            let serverID = id
            let cached: StarredResult? = await Task.detached(priority: .utility) {
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
        } catch {
            errorMessage = error.localizedDescription
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
            // Rollback
            if isStarred {
                starredSongs.insert(song, at: 0)
            } else {
                starredSongs.removeAll { $0.id == song.id }
            }
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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

    // MARK: - Playlists

    func loadPlaylists() async {
        if let id = activeServerID {
            let serverID = id
            let cached: [Playlist]? = await Task.detached(priority: .utility) {
                Self.readFromDisk([Playlist].self, name: "playlists", serverID: serverID)
            }.value
            if let cached, !cached.isEmpty { playlists = cached }
        }

        isLoadingPlaylists = playlists.isEmpty
        do {
            let result = try await api.getPlaylists()
            playlists = result
            if let id = activeServerID { save(result, name: "playlists", serverID: id) }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingPlaylists = false
    }

    func loadPlaylistDetail(id: String) async -> Playlist? {
        do {
            return try await api.getPlaylist(id: id)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func createPlaylist(name: String, songIds: [String] = []) async {
        do {
            let created = try await api.createPlaylist(name: name, songIds: songIds)
            playlists.append(created)
            if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deletePlaylist(_ playlist: Playlist) async {
        playlists.removeAll { $0.id == playlist.id }
        do {
            try await api.deletePlaylist(id: playlist.id)
            if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
        } catch {
            playlists.append(playlist)
            errorMessage = error.localizedDescription
        }
    }

    func renamePlaylist(_ playlist: Playlist, newName: String) async {
        do {
            try await api.updatePlaylist(id: playlist.id, name: newName)
            if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
                let updated = Playlist(
                    id: playlist.id, name: newName, comment: playlist.comment,
                    songCount: playlist.songCount, duration: playlist.duration, coverArt: playlist.coverArt
                )
                playlists[idx] = updated
            }
            if let id = activeServerID { save(playlists, name: "playlists", serverID: id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addSongsToPlaylist(_ playlist: Playlist, songIds: [String]) async {
        do {
            try await api.updatePlaylist(id: playlist.id, songIdsToAdd: songIds)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeSongsFromPlaylist(_ playlist: Playlist, indices: [Int]) async {
        do {
            try await api.updatePlaylist(id: playlist.id, songIndicesToRemove: indices)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension SubsonicAPIService {
    func getAllAlbums(size: Int = 500, offset: Int = 0, sortBy: String = "alphabeticalByName") async throws -> [Album] {
        try await getAlbumList(type: sortBy, size: size, offset: offset)
    }
}
