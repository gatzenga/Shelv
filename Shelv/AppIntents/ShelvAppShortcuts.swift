import AppIntents
import Foundation
#if canImport(Intents)
import Intents
#endif

enum ShelvShortcutDestination: String, AppEnum {
    case discover
    case library
    case search
    case recap
    case nowPlaying

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Shelv Destination"
    }

    static var caseDisplayRepresentations: [ShelvShortcutDestination: DisplayRepresentation] {
        [
            .discover: "Discover",
            .library: "Library",
            .search: "Search",
            .recap: "Recap",
            .nowPlaying: "Now Playing",
        ]
    }
}

extension Notification.Name {
    static let shelvShortcutDestinationRequested = Notification.Name("shelvShortcutDestinationRequested")
}

enum ShelvShortcutHandoff {
    private static let pendingDestinationKey = "shelv.shortcut.pendingDestination"

    @MainActor
    static func request(_ destination: ShelvShortcutDestination) {
        UserDefaults.standard.set(destination.rawValue, forKey: pendingDestinationKey)
        NotificationCenter.default.post(
            name: .shelvShortcutDestinationRequested,
            object: destination.rawValue
        )
    }

    @MainActor
    static func consumePendingDestination() -> ShelvShortcutDestination? {
        guard let rawValue = UserDefaults.standard.string(forKey: pendingDestinationKey) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: pendingDestinationKey)
        return ShelvShortcutDestination(rawValue: rawValue)
    }
}

private enum ShelvPlaybackIntentResult {
    case noTrack
    case playing
    case paused
    case nextTrack
    case previousTrack
}

struct ShelvPlaylistEntity: AppEntity, Identifiable {
    let id: String
    let name: String
    let songCount: Int?

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = ShelvPlaylistQuery()

    var displayRepresentation: DisplayRepresentation {
        if let songCount {
            DisplayRepresentation(title: "\(name)", subtitle: "\(songCount) tracks")
        } else {
            DisplayRepresentation(title: "\(name)")
        }
    }
}

struct ShelvPlaylistQuery: EntityStringQuery {
    func entities(for identifiers: [ShelvPlaylistEntity.ID]) async throws -> [ShelvPlaylistEntity] {
        let playlists = await fetchPlaylists()
        let requested = Set(identifiers)
        return playlists.filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ShelvPlaylistEntity] {
        Array(await fetchPlaylists().prefix(25))
    }

    func entities(matching string: String) async throws -> [ShelvPlaylistEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return await fetchPlaylists().filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    @MainActor
    private func fetchPlaylists() async -> [ShelvPlaylistEntity] {
        if SubsonicAPIService.shared.activeServer == nil {
            _ = ServerStore()
        }
        let store = LibraryStore.shared
        if store.playlists.isEmpty {
            await store.loadPlaylists()
        }
        let playlists = store.playlists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map {
                ShelvPlaylistEntity(id: $0.id, name: $0.name, songCount: $0.songCount)
            }
        updatePlaylistVocabulary(playlists)
        print("[Shortcuts] Playlists available → \(playlists.count)")
        return playlists
    }
}

private func updatePlaylistVocabulary(_ playlists: [ShelvPlaylistEntity]) {
    #if os(iOS)
    let names = playlists
        .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !names.isEmpty else { return }
    INVocabulary.shared().setVocabularyStrings(NSOrderedSet(array: names), of: .mediaPlaylistTitle)
    print("[Shortcuts] Playlist vocabulary updated → \(names.count)")
    #endif
}

private enum ShelvPlaylistIntentResult {
    case noServer
    case notFound
    case empty(String)
    case playing(String)
    case shuffled(String)
}

struct ShelvPlayPauseIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause in Shelv"
    static let description = IntentDescription("Toggle playback in Shelv.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await MainActor.run { () -> ShelvPlaybackIntentResult in
            print("[Shortcuts] Request → Play/Pause")
            let player = AudioPlayerService.shared
            guard player.currentSong != nil else { return .noTrack }
            player.togglePlayPause()
            return player.isPlaying ? .playing : .paused
        }

        switch result {
        case .noTrack:
            return .result(dialog: "No track is loaded in Shelv.")
        case .playing:
            return .result(dialog: "Playing in Shelv.")
        case .paused:
            return .result(dialog: "Paused Shelv.")
        case .nextTrack, .previousTrack:
            return .result(dialog: "Updated playback in Shelv.")
        }
    }
}

struct ShelvNextTrackIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track in Shelv"
    static let description = IntentDescription("Skip to the next track in Shelv.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await MainActor.run { () -> ShelvPlaybackIntentResult in
            print("[Shortcuts] Request → Next Track")
            let player = AudioPlayerService.shared
            guard player.currentSong != nil else { return .noTrack }
            player.next(triggeredByUser: true)
            return .nextTrack
        }

        switch result {
        case .noTrack:
            return .result(dialog: "No track is loaded in Shelv.")
        case .nextTrack:
            return .result(dialog: "Skipped to the next track in Shelv.")
        case .playing, .paused, .previousTrack:
            return .result(dialog: "Updated playback in Shelv.")
        }
    }
}

struct ShelvPreviousTrackIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track in Shelv"
    static let description = IntentDescription("Go back to the previous track in Shelv.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await MainActor.run { () -> ShelvPlaybackIntentResult in
            print("[Shortcuts] Request → Previous Track")
            let player = AudioPlayerService.shared
            guard player.currentSong != nil else { return .noTrack }
            player.previous()
            return .previousTrack
        }

        switch result {
        case .noTrack:
            return .result(dialog: "No track is loaded in Shelv.")
        case .previousTrack:
            return .result(dialog: "Went to the previous track in Shelv.")
        case .playing, .paused, .nextTrack:
            return .result(dialog: "Updated playback in Shelv.")
        }
    }
}

struct ShelvPlayPlaylistIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist in Shelv"
    static let description = IntentDescription("Start playing a selected playlist in Shelv.")
    static let openAppWhenRun = false

    @Parameter(title: "Playlist")
    var playlist: ShelvPlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        print("[Shortcuts] Request → Play Playlist: \(playlist.name)")
        let result = await playPlaylist(playlist, shuffled: false)
        switch result {
        case .noServer:
            return .result(dialog: "No active server is configured in Shelv.")
        case .notFound:
            return .result(dialog: "Could not find that playlist in Shelv.")
        case .empty(let name):
            return .result(dialog: "\(name) has no playable songs.")
        case .playing(let name):
            return .result(dialog: "Playing \(name) in Shelv.")
        case .shuffled(let name):
            return .result(dialog: "Shuffling \(name) in Shelv.")
        }
    }
}

struct ShelvShufflePlaylistIntent: AppIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Playlist in Shelv"
    static let description = IntentDescription("Shuffle a selected playlist in Shelv.")
    static let openAppWhenRun = false

    @Parameter(title: "Playlist")
    var playlist: ShelvPlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle \(\.$playlist)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        print("[Shortcuts] Request → Shuffle Playlist: \(playlist.name)")
        let result = await playPlaylist(playlist, shuffled: true)
        switch result {
        case .noServer:
            return .result(dialog: "No active server is configured in Shelv.")
        case .notFound:
            return .result(dialog: "Could not find that playlist in Shelv.")
        case .empty(let name):
            return .result(dialog: "\(name) has no playable songs.")
        case .playing(let name):
            return .result(dialog: "Playing \(name) in Shelv.")
        case .shuffled(let name):
            return .result(dialog: "Shuffling \(name) in Shelv.")
        }
    }
}

@MainActor
private func playPlaylist(_ entity: ShelvPlaylistEntity, shuffled: Bool) async -> ShelvPlaylistIntentResult {
    if SubsonicAPIService.shared.activeServer == nil {
        _ = ServerStore()
    }
    guard SubsonicAPIService.shared.activeServer != nil else { return .noServer }

    guard let loaded = await LibraryStore.shared.loadPlaylistDetail(id: entity.id) else {
        return .notFound
    }
    let name = loaded.name.isEmpty ? entity.name : loaded.name
    guard let songs = loaded.songs, !songs.isEmpty else {
        return .empty(name)
    }

    if shuffled {
        AudioPlayerService.shared.playShuffled(songs: songs)
        return .shuffled(name)
    } else {
        AudioPlayerService.shared.play(songs: songs)
        return .playing(name)
    }
}

@MainActor
private func requestShortcutDestination(_ destination: ShelvShortcutDestination) {
    print("[Shortcuts] Request → \(destination.rawValue)")
    ShelvShortcutHandoff.request(destination)
}

struct ShelvOpenPlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shelv Player"
    static let description = IntentDescription("Open Shelv to the current player.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.nowPlaying)
        return .result()
    }
}

struct ShelvOpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shelv Search"
    static let description = IntentDescription("Open Shelv and focus search.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.search)
        return .result()
    }
}

struct ShelvOpenLibraryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shelv Library"
    static let description = IntentDescription("Open Shelv to the library.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.library)
        return .result()
    }
}

struct ShelvOpenRecapIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Shelv Recap"
    static let description = IntentDescription("Open Shelv and show Recap.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await requestShortcutDestination(.recap)
        return .result()
    }
}

struct ShelvAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .purple }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShelvPlayPauseIntent(),
            phrases: [
                "Play or pause in \(.applicationName)",
                "Toggle playback in \(.applicationName)",
                "Wiedergabe in \(.applicationName) starten oder pausieren",
            ],
            shortTitle: "Play/Pause",
            systemImageName: "playpause.fill"
        )

        AppShortcut(
            intent: ShelvNextTrackIntent(),
            phrases: [
                "Next track in \(.applicationName)",
                "Skip in \(.applicationName)",
                "Nächster Titel in \(.applicationName)",
            ],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )

        AppShortcut(
            intent: ShelvPreviousTrackIntent(),
            phrases: [
                "Previous track in \(.applicationName)",
                "Go back in \(.applicationName)",
                "Vorheriger Titel in \(.applicationName)",
            ],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )

        AppShortcut(
            intent: ShelvPlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play the \(\.$playlist) playlist in \(.applicationName)",
                "Play playlist \(\.$playlist) in \(.applicationName)",
                "Play playlist in \(.applicationName)",
                "Spiele \(\.$playlist) in \(.applicationName)",
                "Spiele Playlist \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )

        AppShortcut(
            intent: ShelvShufflePlaylistIntent(),
            phrases: [
                "Shuffle \(\.$playlist) in \(.applicationName)",
                "Shuffle the \(\.$playlist) playlist in \(.applicationName)",
                "Shuffle playlist \(\.$playlist) in \(.applicationName)",
                "Shuffle playlist in \(.applicationName)",
                "Mische \(\.$playlist) in \(.applicationName)",
                "Mische Playlist \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Shuffle Playlist",
            systemImageName: "shuffle"
        )

        AppShortcut(
            intent: ShelvOpenPlayerIntent(),
            phrases: [
                "Open player in \(.applicationName)",
                "Open \(.applicationName) player",
                "Show player in \(.applicationName)",
                "Open now playing in \(.applicationName)",
                "Aktuelle Wiedergabe in \(.applicationName) anzeigen",
            ],
            shortTitle: "Now Playing",
            systemImageName: "music.note"
        )

        AppShortcut(
            intent: ShelvOpenSearchIntent(),
            phrases: [
                "Open search in \(.applicationName)",
                "Open \(.applicationName) search",
                "Search in \(.applicationName)",
                "Search with \(.applicationName)",
                "Suche in \(.applicationName) öffnen",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: ShelvOpenLibraryIntent(),
            phrases: [
                "Open library in \(.applicationName)",
                "Show library in \(.applicationName)",
                "Mediathek in \(.applicationName) öffnen",
            ],
            shortTitle: "Library",
            systemImageName: "books.vertical.fill"
        )

        AppShortcut(
            intent: ShelvOpenRecapIntent(),
            phrases: [
                "Open Recap in \(.applicationName)",
                "Show Recap in \(.applicationName)",
                "Recap in \(.applicationName) öffnen",
            ],
            shortTitle: "Recap",
            systemImageName: "calendar.badge.clock"
        )
    }
}
