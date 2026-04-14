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
    @Published var isLoadingAlbums: Bool = false
    @Published var isLoadingArtists: Bool = false
    @Published var isLoadingDiscover: Bool = false
    @Published var errorMessage: String?

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
            let (a, p, f) = try await (added, played, frequent)
            recentlyAdded    = a
            recentlyPlayed   = p
            frequentlyPlayed = f
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingDiscover = false
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
        try? FileManager.default.removeItem(at: Self.libraryDir)
    }
}

extension SubsonicAPIService {
    func getAllAlbums(size: Int = 500, offset: Int = 0, sortBy: String = "alphabeticalByName") async throws -> [Album] {
        try await getAlbumList(type: sortBy, size: size, offset: offset)
    }
}
