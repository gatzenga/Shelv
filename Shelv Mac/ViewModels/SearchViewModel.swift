import Combine
import Foundation

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var artists: [Artist] = []
    @Published var albums: [Album] = []
    @Published var songs: [Song] = []
    @Published var isLoading: Bool = false

    private let api = SubsonicAPIService.shared
    private var searchTask: Task<Bool, Never>?

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }

    func search() async -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedServerID = AppState.shared.serverStore.activeServerID
        let requestedServerRevision = AppState.shared.serverStore.activeServerRevision
        guard !term.isEmpty else {
            clearResults()
            return false
        }
        searchTask?.cancel()
        searchTask = Task {
            isLoading = true
            defer {
                if !Task.isCancelled {
                    isLoading = false
                }
            }
            if OfflineModeService.shared.isOffline {
                return await searchOffline(query: term)
            } else {
                do {
                    let result = try await api.search(query: term)
                    guard !Task.isCancelled,
                          requestedServerID == AppState.shared.serverStore.activeServerID,
                          requestedServerRevision == AppState.shared.serverStore.activeServerRevision,
                          term == query.trimmingCharacters(in: .whitespacesAndNewlines)
                    else { return false }
                    artists = (result.artist ?? []).filter { ($0.albumCount ?? 0) > 0 }
                    albums = result.album ?? []
                    songs = result.song ?? []
                    return true
                } catch {
                    guard !Task.isCancelled,
                          requestedServerID == AppState.shared.serverStore.activeServerID,
                          requestedServerRevision == AppState.shared.serverStore.activeServerRevision,
                          term == query.trimmingCharacters(in: .whitespacesAndNewlines)
                    else { return false }
                    guard !OfflineModeService.shared.presentConnectivityErrorIfNeeded(error, userInitiated: true) else {
                        return false
                    }
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "search_failed"))
                    return false
                }
            }
        }
        return await searchTask?.value ?? false
    }

    private func searchOffline(query: String) async -> Bool {
        let requestedServerID = AppState.shared.serverStore.activeServerID
        let requestedServerRevision = AppState.shared.serverStore.activeServerRevision
        let stable = AppState.shared.serverStore.activeServer?.stableId ?? ""
        guard !stable.isEmpty else {
            artists = []
            albums = []
            songs = []
            return false
        }
        let records = await DownloadDatabase.shared.search(serverId: stable, query: query, limit: 100)
        guard !Task.isCancelled,
              requestedServerID == AppState.shared.serverStore.activeServerID,
              requestedServerRevision == AppState.shared.serverStore.activeServerRevision,
              query == self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        songs = records.map { $0.toDownloadedSong().asSong() }

        let q = query.lowercased()

        albums = DownloadStore.shared.albums
            .filter { $0.title.lowercased().contains(q) || $0.artistName.lowercased().contains(q) }
            .map { $0.asAlbum() }

        artists = DownloadStore.shared.artists
            .filter { $0.name.lowercased().contains(q) }
            .map { $0.asArtist() }
        return true
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        isLoading = false
    }

    func clearResults() {
        cancelSearch()
        artists = []
        albums = []
        songs = []
    }
}
