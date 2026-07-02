import Foundation

nonisolated enum PersonalizationPreferenceKey {
    static let migrationVersion = "ui.personalizationMigrationVersion"

    static let showPlaylistsTab = "ui.showPlaylistsTab"
    static let showPlaylistActions = "ui.showPlaylistActions"
    static let showFavoritesInLibrary = "ui.showFavoritesInLibrary"
    static let showFavoriteActions = "ui.showFavoriteActions"
    static let showInstantMixActions = "ui.showInstantMixActions"
    static let showRadio = "ui.showRadio"
    static let showGenreFilter = "ui.showGenreFilter"
    static let albumGenreFilter = "albumGenreFilter"
    static let miniPlayerStyle = "ui.miniPlayerStyle"

    static let swipeLeftPrimary = "ui.swipe.leftPrimary"
    static let swipeLeftSecondary = "ui.swipe.leftSecondary"
    static let swipeRightPrimary = "ui.swipe.rightPrimary"
    static let swipeRightSecondary = "ui.swipe.rightSecondary"
    static let swipeRightTertiary = "ui.swipe.rightTertiary"
    static let playlistSwipeLeftPrimary = "ui.swipe.playlists.leftPrimary"
    static let playlistSwipeLeftSecondary = "ui.swipe.playlists.leftSecondary"
    static let playlistSwipeLeftTertiary = "ui.swipe.playlists.leftTertiary"
    static let playlistSwipeRightPrimary = "ui.swipe.playlists.rightPrimary"
    static let playlistSwipeRightSecondary = "ui.swipe.playlists.rightSecondary"
    static let albumArtistSwipeLeftPrimary = "ui.swipe.albumArtists.leftPrimary"
    static let albumArtistSwipeLeftSecondary = "ui.swipe.albumArtists.leftSecondary"
    static let albumArtistSwipeLeftTertiary = "ui.swipe.albumArtists.leftTertiary"
    static let albumArtistSwipeRightPrimary = "ui.swipe.albumArtists.rightPrimary"
    static let albumArtistSwipeRightSecondary = "ui.swipe.albumArtists.rightSecondary"

    static let legacyEnablePlaylists = "enablePlaylists"
    static let legacyEnableFavorites = "enableFavorites"
    static let legacyEnableInstantMix = "enableInstantMix"
}

nonisolated enum PersonalizationSwipeGroup: String, CaseIterable, Identifiable, Hashable {
    case songs
    case playlists
    case albumArtists

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .songs: return "songs"
        case .playlists: return "playlists"
        case .albumArtists: return "albums_artists"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: return "music.note"
        case .playlists: return "music.note.list"
        case .albumArtists: return "square.stack"
        }
    }

    var slots: [PersonalizationSwipeSlot] {
        PersonalizationSwipeSlot.allCases.filter { $0.group == self }
    }

    var availableActions: [PersonalizationSwipeAction] {
        switch self {
        case .songs:
            return [.none, .favorite, .addToPlaylist, .instantMix, .playNext, .addToQueue]
        case .playlists:
            return [.none, .pin, .download, .delete, .playNext, .addToQueue]
        case .albumArtists:
            return [.none, .favorite, .addToPlaylist, .download, .playNext, .addToQueue]
        }
    }
}

nonisolated enum PersonalizationTab: Equatable {
    case discover
    case library
    case playlists
    case settings
    case search
}

nonisolated enum PersonalizationSwipeSlot: String, CaseIterable, Hashable {
    case leftPrimary
    case leftSecondary
    case rightPrimary
    case rightSecondary
    case rightTertiary
    case playlistLeftPrimary
    case playlistLeftSecondary
    case playlistLeftTertiary
    case playlistRightPrimary
    case playlistRightSecondary
    case albumArtistLeftPrimary
    case albumArtistLeftSecondary
    case albumArtistLeftTertiary
    case albumArtistRightPrimary
    case albumArtistRightSecondary

    var storageKey: String {
        switch self {
        case .leftPrimary: return PersonalizationPreferenceKey.swipeLeftPrimary
        case .leftSecondary: return PersonalizationPreferenceKey.swipeLeftSecondary
        case .rightPrimary: return PersonalizationPreferenceKey.swipeRightPrimary
        case .rightSecondary: return PersonalizationPreferenceKey.swipeRightSecondary
        case .rightTertiary: return PersonalizationPreferenceKey.swipeRightTertiary
        case .playlistLeftPrimary: return PersonalizationPreferenceKey.playlistSwipeLeftPrimary
        case .playlistLeftSecondary: return PersonalizationPreferenceKey.playlistSwipeLeftSecondary
        case .playlistLeftTertiary: return PersonalizationPreferenceKey.playlistSwipeLeftTertiary
        case .playlistRightPrimary: return PersonalizationPreferenceKey.playlistSwipeRightPrimary
        case .playlistRightSecondary: return PersonalizationPreferenceKey.playlistSwipeRightSecondary
        case .albumArtistLeftPrimary: return PersonalizationPreferenceKey.albumArtistSwipeLeftPrimary
        case .albumArtistLeftSecondary: return PersonalizationPreferenceKey.albumArtistSwipeLeftSecondary
        case .albumArtistLeftTertiary: return PersonalizationPreferenceKey.albumArtistSwipeLeftTertiary
        case .albumArtistRightPrimary: return PersonalizationPreferenceKey.albumArtistSwipeRightPrimary
        case .albumArtistRightSecondary: return PersonalizationPreferenceKey.albumArtistSwipeRightSecondary
        }
    }

    var titleKey: String {
        switch self {
        case .leftPrimary, .playlistLeftPrimary, .albumArtistLeftPrimary:
            return "swipe_left_1"
        case .leftSecondary, .playlistLeftSecondary, .albumArtistLeftSecondary:
            return "swipe_left_2"
        case .playlistLeftTertiary, .albumArtistLeftTertiary:
            return "swipe_left_3"
        case .rightPrimary, .playlistRightPrimary, .albumArtistRightPrimary:
            return "swipe_right_1"
        case .rightSecondary, .playlistRightSecondary, .albumArtistRightSecondary:
            return "swipe_right_2"
        case .rightTertiary:
            return "swipe_right_3"
        }
    }

    var group: PersonalizationSwipeGroup {
        switch self {
        case .leftPrimary, .leftSecondary, .rightPrimary, .rightSecondary, .rightTertiary:
            return .songs
        case .playlistLeftPrimary, .playlistLeftSecondary, .playlistLeftTertiary, .playlistRightPrimary, .playlistRightSecondary:
            return .playlists
        case .albumArtistLeftPrimary, .albumArtistLeftSecondary, .albumArtistLeftTertiary, .albumArtistRightPrimary, .albumArtistRightSecondary:
            return .albumArtists
        }
    }

    var isLeading: Bool {
        switch self {
        case .leftPrimary, .leftSecondary,
             .playlistLeftPrimary, .playlistLeftSecondary, .playlistLeftTertiary,
             .albumArtistLeftPrimary, .albumArtistLeftSecondary, .albumArtistLeftTertiary:
            return true
        case .rightPrimary, .rightSecondary,
             .rightTertiary,
             .playlistRightPrimary, .playlistRightSecondary,
             .albumArtistRightPrimary, .albumArtistRightSecondary:
            return false
        }
    }

    var defaultAction: PersonalizationSwipeAction {
        switch self {
        case .leftPrimary:
            return .favorite
        case .leftSecondary:
            return .addToPlaylist
        case .rightPrimary:
            return .playNext
        case .rightSecondary:
            return .addToQueue
        case .rightTertiary:
            return .instantMix
        case .playlistLeftPrimary:
            return .pin
        case .playlistLeftSecondary:
            return .download
        case .playlistLeftTertiary:
            return .delete
        case .playlistRightPrimary:
            return .playNext
        case .playlistRightSecondary:
            return .addToQueue
        case .albumArtistLeftPrimary:
            return .favorite
        case .albumArtistLeftSecondary:
            return .addToPlaylist
        case .albumArtistLeftTertiary:
            return .download
        case .albumArtistRightPrimary:
            return .playNext
        case .albumArtistRightSecondary:
            return .addToQueue
        }
    }
}

nonisolated enum PersonalizationSwipeAction: String, CaseIterable, Hashable {
    case none
    case favorite
    case addToPlaylist
    case download
    case pin
    case delete
    case instantMix
    case playNext
    case addToQueue

    var titleKey: String {
        switch self {
        case .none: return "none"
        case .favorite: return "favorite"
        case .addToPlaylist: return "add_to_playlist_2"
        case .download: return "download"
        case .pin: return "pin"
        case .delete: return "delete"
        case .instantMix: return "instant_mix"
        case .playNext: return "play_next"
        case .addToQueue: return "add_to_queue"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "minus.circle"
        case .favorite: return "heart"
        case .addToPlaylist: return "text.badge.plus"
        case .download: return "arrow.down.circle"
        case .pin: return "pin"
        case .delete: return "trash"
        case .instantMix: return "sparkles"
        case .playNext: return "text.line.first.and.arrowtriangle.forward"
        case .addToQueue: return "text.line.last.and.arrowtriangle.forward"
        }
    }
}

nonisolated enum PersonalizationMiniPlayerStyle: String, CaseIterable {
    case shelv
    case native

    var titleKey: String {
        switch self {
        case .shelv: return "mini_player_shelv"
        case .native: return "mini_player_native"
        }
    }

    var systemImage: String {
        switch self {
        case .shelv: return "play.rectangle"
        case .native: return "apple.logo"
        }
    }
}

nonisolated enum PersonalizationSettings {
    static let currentMigrationVersion = 3

    static let defaultValues: [String: Any] = {
        var values: [String: Any] = [
            PersonalizationPreferenceKey.showPlaylistsTab: true,
            PersonalizationPreferenceKey.showPlaylistActions: true,
            PersonalizationPreferenceKey.showFavoritesInLibrary: true,
            PersonalizationPreferenceKey.showFavoriteActions: true,
            PersonalizationPreferenceKey.showInstantMixActions: true,
            PersonalizationPreferenceKey.showRadio: true,
            PersonalizationPreferenceKey.showGenreFilter: true,
            PersonalizationPreferenceKey.miniPlayerStyle: PersonalizationMiniPlayerStyle.shelv.rawValue,
        ]
        for slot in PersonalizationSwipeSlot.allCases {
            values[slot.storageKey] = slot.defaultAction.rawValue
        }
        return values
    }()

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        migrateLegacyKeysIfNeeded(in: defaults)
        defaults.register(defaults: defaultValues)
        normalizeSwipeActions(in: defaults)
    }

    static func migrateLegacyKeysIfNeeded(in defaults: UserDefaults = .standard) {
        let previousVersion = defaults.integer(forKey: PersonalizationPreferenceKey.migrationVersion)
        guard previousVersion < currentMigrationVersion else {
            return
        }

        if previousVersion < 1,
           defaults.object(forKey: PersonalizationPreferenceKey.legacyEnablePlaylists) != nil {
            let enabled = defaults.bool(forKey: PersonalizationPreferenceKey.legacyEnablePlaylists)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showPlaylistsTab)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showPlaylistActions)
        }

        if previousVersion < 1,
           defaults.object(forKey: PersonalizationPreferenceKey.legacyEnableFavorites) != nil {
            let enabled = defaults.bool(forKey: PersonalizationPreferenceKey.legacyEnableFavorites)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showFavoritesInLibrary)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showFavoriteActions)
        }

        if previousVersion < 1,
           defaults.object(forKey: PersonalizationPreferenceKey.legacyEnableInstantMix) != nil {
            let enabled = defaults.bool(forKey: PersonalizationPreferenceKey.legacyEnableInstantMix)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showInstantMixActions)
        }

        if previousVersion < 2 {
            migrateSongInstantMixSwipeDefault(previousVersion: previousVersion, in: defaults)
        }

        if previousVersion == 2 {
            migrateSongInstantMixSwipeOrderDefault(in: defaults)
        }

        defaults.set(currentMigrationVersion, forKey: PersonalizationPreferenceKey.migrationVersion)
    }

    private static func migrateSongInstantMixSwipeDefault(previousVersion: Int, in defaults: UserDefaults) {
        let oldDefaults: [(PersonalizationSwipeSlot, PersonalizationSwipeAction)] = [
            (.leftPrimary, .favorite),
            (.leftSecondary, .addToPlaylist),
            (.rightPrimary, .playNext),
            (.rightSecondary, .addToQueue),
        ]

        let rightSecondary = defaults.string(forKey: PersonalizationPreferenceKey.swipeRightSecondary)
            .flatMap(PersonalizationSwipeAction.init(rawValue:))
        guard previousVersion > 0 || rightSecondary == .addToQueue else { return }

        let hasStoredSongSwipes = oldDefaults.contains { slot, _ in
            defaults.object(forKey: slot.storageKey) != nil
        }
        guard hasStoredSongSwipes else { return }

        let usesOldSongDefaults = oldDefaults.allSatisfy { slot, expected in
            guard let rawValue = defaults.string(forKey: slot.storageKey) else { return true }
            return PersonalizationSwipeAction(rawValue: rawValue) == expected
        }

        if usesOldSongDefaults {
            defaults.set(PersonalizationSwipeAction.addToQueue.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)
            defaults.set(PersonalizationSwipeAction.instantMix.rawValue, forKey: PersonalizationPreferenceKey.swipeRightTertiary)
        } else {
            defaults.set(PersonalizationSwipeAction.none.rawValue, forKey: PersonalizationPreferenceKey.swipeRightTertiary)
        }
    }

    private static func migrateSongInstantMixSwipeOrderDefault(in defaults: UserDefaults) {
        let previousDefaults: [(PersonalizationSwipeSlot, PersonalizationSwipeAction)] = [
            (.leftPrimary, .favorite),
            (.leftSecondary, .addToPlaylist),
            (.rightPrimary, .playNext),
            (.rightSecondary, .instantMix),
            (.rightTertiary, .addToQueue),
        ]

        let hasStoredSongSwipes = previousDefaults.contains { slot, _ in
            defaults.object(forKey: slot.storageKey) != nil
        }
        guard hasStoredSongSwipes else { return }

        let usesPreviousDefaults = previousDefaults.allSatisfy { slot, expected in
            guard let rawValue = defaults.string(forKey: slot.storageKey) else { return true }
            return PersonalizationSwipeAction(rawValue: rawValue) == expected
        }
        guard usesPreviousDefaults else { return }

        defaults.set(PersonalizationSwipeAction.addToQueue.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)
        defaults.set(PersonalizationSwipeAction.instantMix.rawValue, forKey: PersonalizationPreferenceKey.swipeRightTertiary)
    }

    static func tabOrder(showPlaylists: Bool) -> [PersonalizationTab] {
        if showPlaylists {
            return [.discover, .library, .playlists, .settings, .search]
        }
        return [.discover, .library, .settings, .search]
    }

    static func swipeAction(for slot: PersonalizationSwipeSlot, in defaults: UserDefaults = .standard) -> PersonalizationSwipeAction {
        let rawValue = defaults.string(forKey: slot.storageKey)
        return rawValue.flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? slot.defaultAction
    }

    static func visibleSwipeAction(for slot: PersonalizationSwipeSlot, in defaults: UserDefaults = .standard) -> PersonalizationSwipeAction {
        let action = swipeAction(for: slot, in: defaults)
        guard slot.group.availableActions.contains(action) else { return .none }
        return isAvailable(action, in: defaults) ? action : .none
    }

    static func setSwipeAction(_ action: PersonalizationSwipeAction, for slot: PersonalizationSwipeSlot, in defaults: UserDefaults = .standard) {
        let selectedAction = slot.group.availableActions.contains(action) ? action : .none

        if selectedAction != .none {
            for otherSlot in slot.group.slots where otherSlot != slot && swipeAction(for: otherSlot, in: defaults) == selectedAction {
                defaults.set(PersonalizationSwipeAction.none.rawValue, forKey: otherSlot.storageKey)
            }
        }

        defaults.set(selectedAction.rawValue, forKey: slot.storageKey)
        normalizeSwipeActions(for: slot.group, in: defaults)
    }

    static func resetSwipeActions(in defaults: UserDefaults = .standard) {
        for group in PersonalizationSwipeGroup.allCases {
            resetSwipeActions(for: group, in: defaults)
        }
    }

    static func resetSwipeActions(for group: PersonalizationSwipeGroup, in defaults: UserDefaults = .standard) {
        for slot in group.slots {
            defaults.set(slot.defaultAction.rawValue, forKey: slot.storageKey)
        }
        normalizeSwipeActions(for: group, in: defaults)
    }

    static func clearAlbumGenreFilter(in defaults: UserDefaults = .standard) {
        defaults.set("", forKey: PersonalizationPreferenceKey.albumGenreFilter)
    }

    static func normalizeSwipeActions(in defaults: UserDefaults = .standard) {
        for group in PersonalizationSwipeGroup.allCases {
            normalizeSwipeActions(for: group, in: defaults)
        }
    }

    static func normalizeSwipeActions(for group: PersonalizationSwipeGroup, in defaults: UserDefaults = .standard) {
        var used = Set<PersonalizationSwipeAction>()

        for slot in group.slots {
            let rawValue = defaults.string(forKey: slot.storageKey)
            let parsed = rawValue.flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? slot.defaultAction
            let current = group.availableActions.contains(parsed) ? parsed : .none

            if current == .none {
                defaults.set(PersonalizationSwipeAction.none.rawValue, forKey: slot.storageKey)
                continue
            }

            if used.contains(current) {
                defaults.set(PersonalizationSwipeAction.none.rawValue, forKey: slot.storageKey)
            } else {
                used.insert(current)
                defaults.set(current.rawValue, forKey: slot.storageKey)
            }
        }
    }

    static func isAvailable(_ action: PersonalizationSwipeAction, in defaults: UserDefaults = .standard) -> Bool {
        switch action {
        case .none, .playNext, .addToQueue:
            return true
        case .instantMix:
            return defaults.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions)
        case .favorite:
            return defaults.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
        case .addToPlaylist:
            return defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistActions)
        case .download, .pin, .delete:
            return true
        }
    }

}
