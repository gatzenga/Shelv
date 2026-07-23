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
    private var searchTask: Task<Void, Never>?

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }

    func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedServerID = AppState.shared.serverStore.activeServerID
        let requestedServerRevision = AppState.shared.serverStore.activeServerRevision
        guard !term.isEmpty else {
            clearResults()
            return
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
                await searchOffline(query: term)
            } else {
                do {
                    let result = try await api.search(query: term)
                    guard !Task.isCancelled,
                          requestedServerID == AppState.shared.serverStore.activeServerID,
                          requestedServerRevision == AppState.shared.serverStore.activeServerRevision,
                          term == query.trimmingCharacters(in: .whitespacesAndNewlines)
                    else { return }
                    artists = (result.artist ?? []).filter { ($0.albumCount ?? 0) > 0 }
                    albums = result.album ?? []
                    songs = result.song ?? []
                } catch {
                    guard !Task.isCancelled,
                          requestedServerID == AppState.shared.serverStore.activeServerID,
                          requestedServerRevision == AppState.shared.serverStore.activeServerRevision,
                          term == query.trimmingCharacters(in: .whitespacesAndNewlines)
                    else { return }
                    guard !OfflineModeService.shared.presentConnectivityErrorIfNeeded(error, userInitiated: true) else { return }
                    NotificationCenter.default.post(name: .showToast, object: String(localized: "search_failed"))
                }
            }
        }
        await searchTask?.value
    }

    private func searchOffline(query: String) async {
        let requestedServerID = AppState.shared.serverStore.activeServerID
        let requestedServerRevision = AppState.shared.serverStore.activeServerRevision
        let stable = AppState.shared.serverStore.activeServer?.stableId ?? ""
        guard !stable.isEmpty else { artists = []; albums = []; songs = []; return }
        let records = await DownloadDatabase.shared.search(serverId: stable, query: query, limit: 100)
        guard !Task.isCancelled,
              requestedServerID == AppState.shared.serverStore.activeServerID,
              requestedServerRevision == AppState.shared.serverStore.activeServerRevision
        else { return }
        songs = records.map { $0.toDownloadedSong().asSong() }

        let q = query.lowercased()

        albums = DownloadStore.shared.albums
            .filter { $0.title.lowercased().contains(q) || $0.artistName.lowercased().contains(q) }
            .map { $0.asAlbum() }

        artists = DownloadStore.shared.artists
            .filter { $0.name.lowercased().contains(q) }
            .map { $0.asArtist() }
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
