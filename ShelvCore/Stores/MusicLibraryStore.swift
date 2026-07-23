import Combine
import Foundation

nonisolated struct MusicLibrarySelectionSnapshot: Equatable, Sendable {
    let serverID: UUID?
    let availableFolders: [SubsonicMusicFolder]
    let selectedFolderIDs: Set<Int>

    static let empty = MusicLibrarySelectionSnapshot(
        serverID: nil,
        availableFolders: [],
        selectedFolderIDs: []
    )

    var availableFolderIDs: Set<Int> {
        Set(availableFolders.map(\.id))
    }

    var showsSelector: Bool {
        availableFolders.count > 1
    }

    var appliesFilter: Bool {
        showsSelector && selectedFolderIDs != availableFolderIDs
    }

    /// The active request omits `musicFolderId` when every accessible library
    /// is selected, preserving compatibility with older Subsonic servers.
    var activeRequestFolderIDs: [Int]? {
        appliesFilter ? selectedFolderIDs.sorted() : nil
    }

    /// Cache reads always retain explicit folder membership, even when every
    /// available folder is selected.
    var visibleCacheFolderIDs: [Int]? {
        availableFolders.isEmpty ? nil : selectedFolderIDs.sorted()
    }

    var allCacheFolderIDs: [Int]? {
        availableFolders.isEmpty ? nil : availableFolders.map(\.id)
    }

    var selectionKey: String {
        guard let serverID else { return "none" }
        guard !availableFolders.isEmpty else {
            return "\(serverID.uuidString)|unfiltered"
        }
        if selectedFolderIDs == availableFolderIDs {
            return "\(serverID.uuidString)|all"
        }
        return "\(serverID.uuidString)|\(selectedFolderIDs.sorted().map(String.init).joined(separator: ","))"
    }

    var allSelectionKey: String {
        guard let serverID else { return "none" }
        return availableFolders.isEmpty
            ? "\(serverID.uuidString)|unfiltered"
            : "\(serverID.uuidString)|all"
    }
}

extension Notification.Name {
    static let musicLibrarySelectionChanged = Notification.Name(
        "musicLibrarySelectionChanged"
    )
}

@MainActor
final class MusicLibraryStore: ObservableObject {
    static let shared = MusicLibraryStore()

    @Published private(set) var snapshot: MusicLibrarySelectionSnapshot = .empty
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var isRefreshing = false

    private struct PersistedFolders: Codable {
        let folders: [SubsonicMusicFolder]
    }

    private let defaults: UserDefaults
    private var refreshTask: Task<[SubsonicMusicFolder]?, Never>?
    private var refreshTaskServerID: UUID?
    private var refreshToken: UUID?
    private var preparedServerIDs: Set<UUID> = []
    private var lastRefreshAttempt: [UUID: Date] = [:]
    private let failedRefreshRetryInterval: TimeInterval = 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var availableFolders: [SubsonicMusicFolder] {
        snapshot.availableFolders
    }

    var selectedFolderIDs: Set<Int> {
        snapshot.selectedFolderIDs
    }

    func prepareActiveServer(forceRefresh: Bool = false) async -> MusicLibrarySelectionSnapshot {
        await ServerStore.shared.waitUntilReady()
        guard let server = ServerStore.shared.activeServer else {
            applySnapshot(.empty)
            return snapshot
        }

        activateCachedState(for: server.id)
        guard !OfflineModeService.shared.isOffline else {
            return snapshot
        }

        if let refreshTask,
           refreshTaskServerID == server.id {
            let folders = await refreshTask.value
            guard ServerStore.shared.activeServer?.id == server.id else {
                return snapshot
            }
            if let folders {
                preparedServerIDs.insert(server.id)
                applyServerFolders(folders, serverID: server.id)
            }
            return snapshot
        }
        if !forceRefresh, preparedServerIDs.contains(server.id) {
            return snapshot
        }
        if !forceRefresh,
           let lastAttempt = lastRefreshAttempt[server.id],
           Date().timeIntervalSince(lastAttempt) < failedRefreshRetryInterval {
            return snapshot
        }

        let expectedServerID = server.id
        let token = UUID()
        lastRefreshAttempt[expectedServerID] = Date()
        isRefreshing = true
        let task = Task<[SubsonicMusicFolder]?, Never> {
            try? await SubsonicAPIService.shared.getMusicFolders()
        }
        refreshTask = task
        refreshTaskServerID = expectedServerID
        refreshToken = token
        let folders = await task.value
        if refreshToken == token {
            refreshTask = nil
            refreshTaskServerID = nil
            refreshToken = nil
            isRefreshing = false
        }

        guard ServerStore.shared.activeServer?.id == expectedServerID else {
            return snapshot
        }
        if let folders {
            preparedServerIDs.insert(expectedServerID)
            applyServerFolders(folders, serverID: expectedServerID)
        }
        return snapshot
    }

    func requestFolderIDs(
        for filter: MusicLibraryRequestFilter
    ) async -> [Int]? {
        switch filter {
        case .all:
            return nil
        case .folders(let folderIDs):
            let unique = Set(folderIDs)
            return unique.isEmpty ? nil : unique.sorted()
        case .active:
            return await prepareActiveServer().activeRequestFolderIDs
        }
    }

    func toggle(folderID: Int) {
        guard let serverID = snapshot.serverID else { return }
        let availableIDs = snapshot.availableFolderIDs
        let selectedIDs = MusicLibrarySelectionPolicy.toggledIDs(
            folderID,
            selectedIDs: snapshot.selectedFolderIDs,
            availableIDs: availableIDs
        )
        guard selectedIDs != snapshot.selectedFolderIDs else { return }

        let updated = MusicLibrarySelectionSnapshot(
            serverID: serverID,
            availableFolders: snapshot.availableFolders,
            selectedFolderIDs: selectedIDs
        )
        persist(
            mode: MusicLibrarySelectionPolicy.persistedMode(
                selectedIDs: selectedIDs,
                availableIDs: availableIDs
            ),
            serverID: serverID
        )
        applySnapshot(updated)
        NotificationCenter.default.post(
            name: .musicLibrarySelectionChanged,
            object: serverID
        )
    }

    func clearPersistedState(serverID: UUID) {
        defaults.removeObject(forKey: foldersKey(serverID))
        defaults.removeObject(forKey: selectionKey(serverID))
        preparedServerIDs.remove(serverID)
        lastRefreshAttempt.removeValue(forKey: serverID)
        if snapshot.serverID == serverID {
            refreshTask?.cancel()
            refreshTask = nil
            refreshTaskServerID = nil
            refreshToken = nil
            isRefreshing = false
            applySnapshot(.empty)
        }
    }

    private func activateCachedState(for serverID: UUID) {
        guard snapshot.serverID != serverID else { return }
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskServerID = nil
        refreshToken = nil
        isRefreshing = false

        let folders = loadFolders(serverID: serverID)
        let availableIDs = Set(folders.map(\.id))
        let selectedIDs = MusicLibrarySelectionPolicy.resolvedIDs(
            availableIDs: availableIDs,
            mode: loadSelectionMode(serverID: serverID)
        )
        applySnapshot(
            MusicLibrarySelectionSnapshot(
                serverID: serverID,
                availableFolders: folders,
                selectedFolderIDs: selectedIDs
            )
        )
    }

    private func applyServerFolders(
        _ folders: [SubsonicMusicFolder],
        serverID: UUID
    ) {
        var seen: Set<Int> = []
        let uniqueFolders = folders.filter { seen.insert($0.id).inserted }
        let availableIDs = Set(uniqueFolders.map(\.id))
        let mode = loadSelectionMode(serverID: serverID)
        let selectedIDs = MusicLibrarySelectionPolicy.resolvedIDs(
            availableIDs: availableIDs,
            mode: mode
        )
        persist(folders: uniqueFolders, serverID: serverID)
        persist(
            mode: MusicLibrarySelectionPolicy.persistedMode(
                selectedIDs: selectedIDs,
                availableIDs: availableIDs
            ),
            serverID: serverID
        )
        applySnapshot(
            MusicLibrarySelectionSnapshot(
                serverID: serverID,
                availableFolders: uniqueFolders,
                selectedFolderIDs: selectedIDs
            )
        )
    }

    private func applySnapshot(_ updated: MusicLibrarySelectionSnapshot) {
        guard snapshot != updated else { return }
        snapshot = updated
        revision &+= 1
    }

    private func loadFolders(serverID: UUID) -> [SubsonicMusicFolder] {
        guard let data = defaults.data(forKey: foldersKey(serverID)),
              let persisted = try? JSONDecoder().decode(PersistedFolders.self, from: data)
        else {
            return []
        }
        return persisted.folders
    }

    private func loadSelectionMode(serverID: UUID) -> MusicLibrarySelectionMode? {
        guard let data = defaults.data(forKey: selectionKey(serverID)) else {
            return nil
        }
        return try? JSONDecoder().decode(MusicLibrarySelectionMode.self, from: data)
    }

    private func persist(folders: [SubsonicMusicFolder], serverID: UUID) {
        guard let data = try? JSONEncoder().encode(PersistedFolders(folders: folders)) else {
            return
        }
        defaults.set(data, forKey: foldersKey(serverID))
    }

    private func persist(mode: MusicLibrarySelectionMode, serverID: UUID) {
        guard let data = try? JSONEncoder().encode(mode) else { return }
        defaults.set(data, forKey: selectionKey(serverID))
    }

    private func foldersKey(_ serverID: UUID) -> String {
        "shelv_music_folders_\(serverID.uuidString)"
    }

    private func selectionKey(_ serverID: UUID) -> String {
        "shelv_music_folder_selection_\(serverID.uuidString)"
    }
}
