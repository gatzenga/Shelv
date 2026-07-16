import Foundation

nonisolated enum PersonalizationPreferenceKey {
    static let migrationVersion = "ui.personalizationMigrationVersion"

    static let showPlaylistsTab = "ui.showPlaylistsTab"
    static let showPlaylistActions = "ui.showPlaylistActions"
    static let showFavoritesInLibrary = "ui.showFavoritesInLibrary"
    static let showFavoriteActions = "ui.showFavoriteActions"
    static let showInstantMixActions = "ui.showInstantMixActions"
    static let showDiscoverInsights = "ui.discover.showInsights"
    static let showRadio = "ui.showRadio"
    static let showGenreFilter = "ui.showGenreFilter"
    static let showDiscoverAirPlay = "ui.discover.showAirPlay"
    static let albumGenreFilter = "albumGenreFilter"
    static let miniPlayerStyle = "ui.miniPlayerStyle"
    static let showSmartMixNewest = "ui.discover.smartMix.newest"
    static let showSmartMixFrequent = "ui.discover.smartMix.frequent"
    static let showSmartMixRecent = "ui.discover.smartMix.recent"
    static let showSmartMixRandom = "ui.discover.smartMix.random"
    static let discoverySectionOrder = "ui.discover.sectionOrder"

    static let swipeLeftPrimary = "ui.swipe.leftPrimary"
    static let swipeLeftSecondary = "ui.swipe.leftSecondary"
    // Kept only for migrating the short-lived three-action leading layout.
    static let swipeLeftTertiary = "ui.swipe.leftTertiary"
    static let swipeRightPrimary = "ui.swipe.rightPrimary"
    static let swipeRightSecondary = "ui.swipe.rightSecondary"
    static let swipeRightTertiary = "ui.swipe.rightTertiary"
    static let playlistSwipeLeftPrimary = "ui.swipe.playlists.leftPrimary"
    static let playlistSwipeLeftSecondary = "ui.swipe.playlists.leftSecondary"
    static let playlistSwipeLeftTertiary = "ui.swipe.playlists.leftTertiary"
    static let playlistSwipeRightPrimary = "ui.swipe.playlists.rightPrimary"
    static let playlistSwipeRightSecondary = "ui.swipe.playlists.rightSecondary"
    static let playlistSwipeRightTertiary = "ui.swipe.playlists.rightTertiary"
    static let albumArtistSwipeLeftPrimary = "ui.swipe.albumArtists.leftPrimary"
    static let albumArtistSwipeLeftSecondary = "ui.swipe.albumArtists.leftSecondary"
    static let albumArtistSwipeLeftTertiary = "ui.swipe.albumArtists.leftTertiary"
    static let albumArtistSwipeRightPrimary = "ui.swipe.albumArtists.rightPrimary"
    static let albumArtistSwipeRightSecondary = "ui.swipe.albumArtists.rightSecondary"
    static let albumArtistSwipeRightTertiary = "ui.swipe.albumArtists.rightTertiary"

    static let legacyEnablePlaylists = "enablePlaylists"
    static let legacyEnableFavorites = "enableFavorites"
    static let legacyEnableInstantMix = "enableInstantMix"
}

nonisolated struct PersonalizationCloudValue: Codable, Equatable, Sendable {
    let boolValue: Bool?
    let stringValue: String?

    static func bool(_ value: Bool) -> PersonalizationCloudValue {
        PersonalizationCloudValue(boolValue: value, stringValue: nil)
    }

    static func string(_ value: String) -> PersonalizationCloudValue {
        PersonalizationCloudValue(boolValue: nil, stringValue: value)
    }
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

nonisolated enum PersonalizationSmartMix: String, CaseIterable, Identifiable, Hashable {
    case newest
    case frequent
    case recent
    case random

    var id: String { rawValue }

    var storageKey: String {
        switch self {
        case .newest: return PersonalizationPreferenceKey.showSmartMixNewest
        case .frequent: return PersonalizationPreferenceKey.showSmartMixFrequent
        case .recent: return PersonalizationPreferenceKey.showSmartMixRecent
        case .random: return PersonalizationPreferenceKey.showSmartMixRandom
        }
    }

    var titleKey: String {
        switch self {
        case .newest: return "mix_newest_tracks"
        case .frequent: return "mix_most_played"
        case .recent: return "mix_recently_played"
        case .random: return "mix_shuffle_all"
        }
    }

    var systemImage: String {
        switch self {
        case .newest: return "sparkles"
        case .frequent: return "chart.bar.fill"
        case .recent: return "clock.fill"
        case .random: return "shuffle"
        }
    }

    var playbackKey: String { rawValue }
}

nonisolated enum PersonalizationDiscoverySection: String, CaseIterable, Identifiable, Hashable {
    case smartMixes
    case recentlyAdded
    case recentlyPlayed
    case frequentlyPlayed
    case randomAlbums

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .smartMixes: return "smart_mixes"
        case .recentlyAdded: return "recently_added"
        case .recentlyPlayed: return "recently_played"
        case .frequentlyPlayed: return "frequently_played"
        case .randomAlbums: return "random_albums"
        }
    }

    var systemImage: String {
        switch self {
        case .smartMixes: return "sparkles"
        case .recentlyAdded: return "plus.circle"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .frequentlyPlayed: return "chart.bar.fill"
        case .randomAlbums: return "shuffle"
        }
    }
}

nonisolated enum PersonalizationSwipeSlot: String, CaseIterable, Hashable {
    case leftPrimary
    case leftSecondary
    case rightPrimary
    case rightSecondary
    case rightTertiary
    case playlistLeftPrimary
    case playlistLeftSecondary
    case playlistRightPrimary
    case playlistRightSecondary
    case playlistRightTertiary
    case albumArtistLeftPrimary
    case albumArtistLeftSecondary
    case albumArtistRightPrimary
    case albumArtistRightSecondary
    case albumArtistRightTertiary

    var storageKey: String {
        switch self {
        case .leftPrimary: return PersonalizationPreferenceKey.swipeLeftPrimary
        case .leftSecondary: return PersonalizationPreferenceKey.swipeLeftSecondary
        case .rightPrimary: return PersonalizationPreferenceKey.swipeRightPrimary
        case .rightSecondary: return PersonalizationPreferenceKey.swipeRightSecondary
        case .rightTertiary: return PersonalizationPreferenceKey.swipeRightTertiary
        case .playlistLeftPrimary: return PersonalizationPreferenceKey.playlistSwipeLeftPrimary
        case .playlistLeftSecondary: return PersonalizationPreferenceKey.playlistSwipeLeftSecondary
        case .playlistRightPrimary: return PersonalizationPreferenceKey.playlistSwipeRightPrimary
        case .playlistRightSecondary: return PersonalizationPreferenceKey.playlistSwipeRightSecondary
        case .playlistRightTertiary: return PersonalizationPreferenceKey.playlistSwipeRightTertiary
        case .albumArtistLeftPrimary: return PersonalizationPreferenceKey.albumArtistSwipeLeftPrimary
        case .albumArtistLeftSecondary: return PersonalizationPreferenceKey.albumArtistSwipeLeftSecondary
        case .albumArtistRightPrimary: return PersonalizationPreferenceKey.albumArtistSwipeRightPrimary
        case .albumArtistRightSecondary: return PersonalizationPreferenceKey.albumArtistSwipeRightSecondary
        case .albumArtistRightTertiary: return PersonalizationPreferenceKey.albumArtistSwipeRightTertiary
        }
    }

    var titleKey: String {
        switch self {
        case .leftPrimary, .playlistLeftPrimary, .albumArtistLeftPrimary:
            return "swipe_right_1"
        case .leftSecondary, .playlistLeftSecondary, .albumArtistLeftSecondary:
            return "swipe_right_2"
        case .rightPrimary, .playlistRightPrimary, .albumArtistRightPrimary:
            return "swipe_left_1"
        case .rightSecondary, .playlistRightSecondary, .albumArtistRightSecondary:
            return "swipe_left_2"
        case .rightTertiary, .playlistRightTertiary, .albumArtistRightTertiary:
            return "swipe_left_3"
        }
    }

    var group: PersonalizationSwipeGroup {
        switch self {
        case .leftPrimary, .leftSecondary, .rightPrimary, .rightSecondary, .rightTertiary:
            return .songs
        case .playlistLeftPrimary, .playlistLeftSecondary, .playlistRightPrimary, .playlistRightSecondary, .playlistRightTertiary:
            return .playlists
        case .albumArtistLeftPrimary, .albumArtistLeftSecondary, .albumArtistRightPrimary, .albumArtistRightSecondary, .albumArtistRightTertiary:
            return .albumArtists
        }
    }

    var isLeading: Bool {
        switch self {
        case .leftPrimary, .leftSecondary,
             .playlistLeftPrimary, .playlistLeftSecondary,
             .albumArtistLeftPrimary, .albumArtistLeftSecondary:
            return true
        case .rightPrimary, .rightSecondary, .rightTertiary,
             .playlistRightPrimary, .playlistRightSecondary, .playlistRightTertiary,
             .albumArtistRightPrimary, .albumArtistRightSecondary, .albumArtistRightTertiary:
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
            return .delete
        case .playlistRightPrimary:
            return .playNext
        case .playlistRightSecondary:
            return .addToQueue
        case .playlistRightTertiary:
            return .download
        case .albumArtistLeftPrimary:
            return .favorite
        case .albumArtistLeftSecondary:
            return .addToPlaylist
        case .albumArtistRightPrimary:
            return .playNext
        case .albumArtistRightSecondary:
            return .addToQueue
        case .albumArtistRightTertiary:
            return .download
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

nonisolated enum ShelvDefaultSettings {
    static let values: [String: Any] = [
        "recapEnabled": false,
        "recapWeeklyEnabled": true,
        "recapMonthlyEnabled": true,
        "recapYearlyEnabled": true,
        "recapThreshold": 30,
        "enableDownloads": true,
        "offlineModeEnabled": false,
        "preventSleepDuringDownloads": false,
        "maxBulkDownloadStorageGB": 10,
        "transcodingEnabled": false,
        "transcodingWifiCodec": "raw",
        "transcodingWifiBitrate": 256,
        "transcodingCellularCodec": "raw",
        "transcodingCellularBitrate": 128,
        "transcodingDownloadCodec": "raw",
        "transcodingDownloadBitrate": 192,
        "gaplessEnabled": false,
        "replayGainEnabled": false,
        "replayGainMode": "track",
        "queueSyncMode": "off",
        "autoFetchLyrics": true,
        "includeNavidromeLyrics": true,
        "useCustomLrcLibServer": false,
        "lrcLibOnlineFallbackEnabled": true,
        "streamPreCacheAheadCount": 1,
        "streamPreCacheEnabled": false,
        "infinityMixAheadCount": 1,
        "iCloudSyncEnabled": false,
        "iCloudSyncPlayHistoryEnabled": true,
        "iCloudSyncRecapEnabled": true,
        "iCloudSyncLyricsServerEnabled": true,
        "iCloudSyncRadioStationsEnabled": true,
        "iCloudSyncUICustomizationsEnabled": true,
        "mixUseDatabase": false,
    ]

    static var registeredValues: [String: Any] {
        var registeredValues = values
        #if os(tvOS)
        registeredValues["enableDownloads"] = false
        #endif
        return registeredValues
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: registeredValues)
    }
}

nonisolated enum PersonalizationSettings {
    static let currentMigrationVersion = 7
    static let defaultDiscoverySectionOrderRaw = PersonalizationDiscoverySection.allCases
        .map(\.rawValue)
        .joined(separator: ",")

    static let defaultValues: [String: Any] = {
        var values: [String: Any] = [
            PersonalizationPreferenceKey.showPlaylistsTab: true,
            PersonalizationPreferenceKey.showPlaylistActions: true,
            PersonalizationPreferenceKey.showFavoritesInLibrary: true,
            PersonalizationPreferenceKey.showFavoriteActions: true,
            PersonalizationPreferenceKey.showInstantMixActions: true,
            PersonalizationPreferenceKey.showDiscoverInsights: true,
            PersonalizationPreferenceKey.showRadio: true,
            PersonalizationPreferenceKey.showGenreFilter: true,
            PersonalizationPreferenceKey.showDiscoverAirPlay: false,
            PersonalizationPreferenceKey.miniPlayerStyle: PersonalizationMiniPlayerStyle.shelv.rawValue,
            PersonalizationPreferenceKey.discoverySectionOrder: defaultDiscoverySectionOrderRaw,
        ]
        for mix in PersonalizationSmartMix.allCases {
            values[mix.storageKey] = true
        }
        for slot in PersonalizationSwipeSlot.allCases {
            values[slot.storageKey] = slot.defaultAction.rawValue
        }
        return values
    }()

    static let cloudSyncedBoolKeys: Set<String> = {
        var keys: Set<String> = [
            PersonalizationPreferenceKey.showPlaylistsTab,
            PersonalizationPreferenceKey.showPlaylistActions,
            PersonalizationPreferenceKey.showFavoritesInLibrary,
            PersonalizationPreferenceKey.showFavoriteActions,
            PersonalizationPreferenceKey.showInstantMixActions,
            PersonalizationPreferenceKey.showDiscoverInsights,
            PersonalizationPreferenceKey.showRadio,
            PersonalizationPreferenceKey.showGenreFilter,
            PersonalizationPreferenceKey.showDiscoverAirPlay,
        ]
        for mix in PersonalizationSmartMix.allCases {
            keys.insert(mix.storageKey)
        }
        return keys
    }()

    static let cloudSyncedStringKeys: Set<String> = {
        var keys: Set<String> = [
            PersonalizationPreferenceKey.albumGenreFilter,
            PersonalizationPreferenceKey.miniPlayerStyle,
            PersonalizationPreferenceKey.discoverySectionOrder,
        ]
        for slot in PersonalizationSwipeSlot.allCases {
            keys.insert(slot.storageKey)
        }
        return keys
    }()

    static var cloudSyncedUICustomizationKeys: Set<String> {
        cloudSyncedBoolKeys.union(cloudSyncedStringKeys)
    }

    static var defaultCloudUICustomizationSnapshot: [String: PersonalizationCloudValue] {
        var snapshot: [String: PersonalizationCloudValue] = [:]
        for key in cloudSyncedBoolKeys {
            snapshot[key] = .bool((defaultValues[key] as? Bool) ?? false)
        }
        for key in cloudSyncedStringKeys {
            snapshot[key] = .string((defaultValues[key] as? String) ?? "")
        }
        return snapshot
    }

    static func cloudUICustomizationSnapshot(in defaults: UserDefaults = .standard) -> [String: PersonalizationCloudValue] {
        var snapshot: [String: PersonalizationCloudValue] = [:]
        for key in cloudSyncedBoolKeys {
            snapshot[key] = .bool(defaults.bool(forKey: key))
        }
        for key in cloudSyncedStringKeys {
            snapshot[key] = .string(normalizedCloudStringValue(forKey: key, in: defaults))
        }
        return snapshot
    }

    static func hasCustomizedCloudUICustomizationValues(in defaults: UserDefaults = .standard) -> Bool {
        cloudUICustomizationSnapshot(in: defaults) != defaultCloudUICustomizationSnapshot
    }

    static func applyCloudUICustomizationSnapshot(
        _ snapshot: [String: PersonalizationCloudValue],
        in defaults: UserDefaults = .standard
    ) {
        for key in cloudSyncedBoolKeys.sorted() {
            guard let value = snapshot[key]?.boolValue else { continue }
            defaults.set(value, forKey: key)
        }

        for key in cloudSyncedStringKeys.sorted() {
            guard let rawValue = snapshot[key]?.stringValue else { continue }
            switch key {
            case PersonalizationPreferenceKey.discoverySectionOrder:
                setDiscoverySectionOrder(discoverySectionOrder(from: rawValue), in: defaults)
            case PersonalizationPreferenceKey.miniPlayerStyle:
                let style = PersonalizationMiniPlayerStyle(rawValue: rawValue) ?? .shelv
                defaults.set(style.rawValue, forKey: key)
            case PersonalizationPreferenceKey.albumGenreFilter:
                defaults.set(rawValue, forKey: key)
            default:
                guard cloudSyncedStringKeys.contains(key) else { continue }
                guard PersonalizationSwipeAction(rawValue: rawValue) != nil else { continue }
                defaults.set(rawValue, forKey: key)
            }
        }

        normalizeSwipeActions(in: defaults)
    }

    private static func normalizedCloudStringValue(forKey key: String, in defaults: UserDefaults) -> String {
        switch key {
        case PersonalizationPreferenceKey.discoverySectionOrder:
            return rawDiscoverySectionOrder(
                discoverySectionOrder(from: defaults.string(forKey: PersonalizationPreferenceKey.discoverySectionOrder))
            )
        case PersonalizationPreferenceKey.miniPlayerStyle:
            let rawValue = defaults.string(forKey: PersonalizationPreferenceKey.miniPlayerStyle) ?? ""
            return PersonalizationMiniPlayerStyle(rawValue: rawValue)?.rawValue
                ?? PersonalizationMiniPlayerStyle.shelv.rawValue
        case PersonalizationPreferenceKey.albumGenreFilter:
            return defaults.string(forKey: PersonalizationPreferenceKey.albumGenreFilter) ?? ""
        default:
            if let slot = PersonalizationSwipeSlot.allCases.first(where: { $0.storageKey == key }) {
                return swipeAction(for: slot, in: defaults).rawValue
            }
            return defaults.string(forKey: key) ?? ""
        }
    }

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

        if previousVersion < 4 {
            migrateReleasedSwipeLayouts(in: defaults)
        } else if previousVersion == 4 {
            migrateInterimSwipeLayouts(in: defaults)
        } else if previousVersion == 5 {
            migrateVersionFiveSongSwipeLayout(in: defaults)
        }

        if previousVersion >= 4 {
            migrateMisorderedDownloadDefaults(in: defaults)
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
        let previousDefaults: [(key: String, action: PersonalizationSwipeAction)] = [
            (PersonalizationPreferenceKey.swipeLeftPrimary, .favorite),
            (PersonalizationPreferenceKey.swipeLeftSecondary, .addToPlaylist),
            (PersonalizationPreferenceKey.swipeRightPrimary, .playNext),
            (PersonalizationPreferenceKey.swipeRightSecondary, .instantMix),
            (PersonalizationPreferenceKey.swipeRightTertiary, .addToQueue),
        ]

        let hasStoredSongSwipes = previousDefaults.contains { entry in
            defaults.object(forKey: entry.key) != nil
        }
        guard hasStoredSongSwipes else { return }

        let usesPreviousDefaults = previousDefaults.allSatisfy { entry in
            guard let rawValue = defaults.string(forKey: entry.key) else { return true }
            return PersonalizationSwipeAction(rawValue: rawValue) == entry.action
        }
        guard usesPreviousDefaults else { return }

        defaults.set(PersonalizationSwipeAction.addToQueue.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)
        defaults.set(PersonalizationSwipeAction.instantMix.rawValue, forKey: PersonalizationPreferenceKey.swipeRightTertiary)
    }

    private static func migrateReleasedSwipeLayouts(in defaults: UserDefaults) {
        replaceOldDefaultSwipeLayout(
            [
                (PersonalizationPreferenceKey.swipeLeftPrimary, .favorite),
                (PersonalizationPreferenceKey.swipeLeftSecondary, .addToPlaylist),
                (PersonalizationPreferenceKey.swipeRightPrimary, .playNext),
                (PersonalizationPreferenceKey.swipeRightSecondary, .addToQueue),
                (PersonalizationPreferenceKey.swipeRightTertiary, .instantMix),
            ],
            with: [
                (.leftPrimary, .favorite),
                (.leftSecondary, .addToPlaylist),
                (.rightPrimary, .playNext),
                (.rightSecondary, .addToQueue),
                (.rightTertiary, .instantMix),
            ],
            in: defaults
        )

        let replacedPlaylistDefaults = replaceOldDefaultSwipeLayout(
            [
                (PersonalizationPreferenceKey.playlistSwipeLeftPrimary, .pin),
                (PersonalizationPreferenceKey.playlistSwipeLeftSecondary, .download),
                (PersonalizationPreferenceKey.playlistSwipeLeftTertiary, .delete),
                (PersonalizationPreferenceKey.playlistSwipeRightPrimary, .playNext),
                (PersonalizationPreferenceKey.playlistSwipeRightSecondary, .addToQueue),
            ],
            with: [
                (.playlistLeftPrimary, .pin),
                (.playlistLeftSecondary, .delete),
                (.playlistRightPrimary, .playNext),
                (.playlistRightSecondary, .addToQueue),
                (.playlistRightTertiary, .download),
            ],
            in: defaults
        )
        if !replacedPlaylistDefaults {
            moveLegacyTertiaryAction(
                from: PersonalizationPreferenceKey.playlistSwipeLeftTertiary,
                to: PersonalizationPreferenceKey.playlistSwipeRightTertiary,
                fallback: .delete,
                in: defaults
            )
        }
        defaults.removeObject(forKey: PersonalizationPreferenceKey.playlistSwipeLeftTertiary)

        let replacedAlbumArtistDefaults = replaceOldDefaultSwipeLayout(
            [
                (PersonalizationPreferenceKey.albumArtistSwipeLeftPrimary, .favorite),
                (PersonalizationPreferenceKey.albumArtistSwipeLeftSecondary, .addToPlaylist),
                (PersonalizationPreferenceKey.albumArtistSwipeLeftTertiary, .download),
                (PersonalizationPreferenceKey.albumArtistSwipeRightPrimary, .playNext),
                (PersonalizationPreferenceKey.albumArtistSwipeRightSecondary, .addToQueue),
            ],
            with: [
                (.albumArtistLeftPrimary, .favorite),
                (.albumArtistLeftSecondary, .addToPlaylist),
                (.albumArtistRightPrimary, .playNext),
                (.albumArtistRightSecondary, .addToQueue),
                (.albumArtistRightTertiary, .download),
            ],
            in: defaults
        )
        if !replacedAlbumArtistDefaults {
            moveLegacyTertiaryAction(
                from: PersonalizationPreferenceKey.albumArtistSwipeLeftTertiary,
                to: PersonalizationPreferenceKey.albumArtistSwipeRightTertiary,
                fallback: .download,
                in: defaults
            )
        }
        defaults.removeObject(forKey: PersonalizationPreferenceKey.albumArtistSwipeLeftTertiary)
        defaults.removeObject(forKey: PersonalizationPreferenceKey.swipeLeftTertiary)
    }

    private static func migrateInterimSwipeLayouts(in defaults: UserDefaults) {
        moveLegacyTertiaryAction(
            from: PersonalizationPreferenceKey.swipeLeftTertiary,
            to: PersonalizationPreferenceKey.swipeRightTertiary,
            fallback: .instantMix,
            in: defaults
        )
        defaults.removeObject(forKey: PersonalizationPreferenceKey.swipeLeftTertiary)
        swapInterimSwipeSides(
            leadingKeys: [
                PersonalizationPreferenceKey.playlistSwipeLeftPrimary,
                PersonalizationPreferenceKey.playlistSwipeLeftSecondary,
                PersonalizationPreferenceKey.playlistSwipeLeftTertiary,
            ],
            leadingDefaults: [.download, .playNext, .addToQueue],
            trailingKeys: [
                PersonalizationPreferenceKey.playlistSwipeRightPrimary,
                PersonalizationPreferenceKey.playlistSwipeRightSecondary,
                PersonalizationPreferenceKey.playlistSwipeRightTertiary,
            ],
            trailingDefaults: [.pin, .delete, .addToQueue],
            in: defaults
        )
        swapInterimSwipeSides(
            leadingKeys: [
                PersonalizationPreferenceKey.albumArtistSwipeLeftPrimary,
                PersonalizationPreferenceKey.albumArtistSwipeLeftSecondary,
                PersonalizationPreferenceKey.albumArtistSwipeLeftTertiary,
            ],
            leadingDefaults: [.download, .playNext, .addToQueue],
            trailingKeys: [
                PersonalizationPreferenceKey.albumArtistSwipeRightPrimary,
                PersonalizationPreferenceKey.albumArtistSwipeRightSecondary,
                PersonalizationPreferenceKey.albumArtistSwipeRightTertiary,
            ],
            trailingDefaults: [.favorite, .addToPlaylist, .addToQueue],
            in: defaults
        )
    }

    private static func migrateVersionFiveSongSwipeLayout(in defaults: UserDefaults) {
        let left = [
            defaults.string(forKey: PersonalizationPreferenceKey.swipeLeftPrimary)
                .flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? .playNext,
            defaults.string(forKey: PersonalizationPreferenceKey.swipeLeftSecondary)
                .flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? .addToQueue,
        ]
        let right = [
            defaults.string(forKey: PersonalizationPreferenceKey.swipeRightPrimary)
                .flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? .favorite,
            defaults.string(forKey: PersonalizationPreferenceKey.swipeRightSecondary)
                .flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? .addToPlaylist,
        ]

        let alreadyUsesCorrectSides = left == [.favorite, .addToPlaylist]
            && right == [.playNext, .addToQueue]
        guard !alreadyUsesCorrectSides else { return }

        defaults.set(right[0].rawValue, forKey: PersonalizationPreferenceKey.swipeLeftPrimary)
        defaults.set(right[1].rawValue, forKey: PersonalizationPreferenceKey.swipeLeftSecondary)
        defaults.set(left[0].rawValue, forKey: PersonalizationPreferenceKey.swipeRightPrimary)
        defaults.set(left[1].rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)
    }

    private static func migrateMisorderedDownloadDefaults(in defaults: UserDefaults) {
        replaceOldDefaultSwipeLayout(
            [
                (PersonalizationPreferenceKey.playlistSwipeLeftPrimary, .pin),
                (PersonalizationPreferenceKey.playlistSwipeLeftSecondary, .delete),
                (PersonalizationPreferenceKey.playlistSwipeRightPrimary, .download),
                (PersonalizationPreferenceKey.playlistSwipeRightSecondary, .playNext),
                (PersonalizationPreferenceKey.playlistSwipeRightTertiary, .addToQueue),
            ],
            with: [
                (.playlistLeftPrimary, .pin),
                (.playlistLeftSecondary, .delete),
                (.playlistRightPrimary, .playNext),
                (.playlistRightSecondary, .addToQueue),
                (.playlistRightTertiary, .download),
            ],
            in: defaults
        )

        replaceOldDefaultSwipeLayout(
            [
                (PersonalizationPreferenceKey.albumArtistSwipeLeftPrimary, .favorite),
                (PersonalizationPreferenceKey.albumArtistSwipeLeftSecondary, .addToPlaylist),
                (PersonalizationPreferenceKey.albumArtistSwipeRightPrimary, .download),
                (PersonalizationPreferenceKey.albumArtistSwipeRightSecondary, .playNext),
                (PersonalizationPreferenceKey.albumArtistSwipeRightTertiary, .addToQueue),
            ],
            with: [
                (.albumArtistLeftPrimary, .favorite),
                (.albumArtistLeftSecondary, .addToPlaylist),
                (.albumArtistRightPrimary, .playNext),
                (.albumArtistRightSecondary, .addToQueue),
                (.albumArtistRightTertiary, .download),
            ],
            in: defaults
        )
    }

    private static func swapInterimSwipeSides(
        leadingKeys: [String],
        leadingDefaults: [PersonalizationSwipeAction],
        trailingKeys: [String],
        trailingDefaults: [PersonalizationSwipeAction],
        in defaults: UserDefaults
    ) {
        let leading = zip(leadingKeys, leadingDefaults).map { key, fallback in
            defaults.string(forKey: key).flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? fallback
        }
        let trailing = zip(trailingKeys.prefix(2), trailingDefaults.prefix(2)).map { key, fallback in
            defaults.string(forKey: key).flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? fallback
        }

        defaults.set(trailing[0].rawValue, forKey: leadingKeys[0])
        defaults.set(trailing[1].rawValue, forKey: leadingKeys[1])
        defaults.set(leading[0].rawValue, forKey: trailingKeys[0])
        defaults.set(leading[1].rawValue, forKey: trailingKeys[1])
        defaults.set(leading[2].rawValue, forKey: trailingKeys[2])
        defaults.removeObject(forKey: leadingKeys[2])
    }

    private static func moveLegacyTertiaryAction(
        from oldKey: String,
        to newKey: String,
        fallback: PersonalizationSwipeAction,
        in defaults: UserDefaults
    ) {
        let action = defaults.string(forKey: oldKey)
            .flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? fallback
        defaults.set(action.rawValue, forKey: newKey)
    }

    @discardableResult
    private static func replaceOldDefaultSwipeLayout(
        _ oldLayout: [(key: String, action: PersonalizationSwipeAction)],
        with newLayout: [(slot: PersonalizationSwipeSlot, action: PersonalizationSwipeAction)],
        in defaults: UserDefaults
    ) -> Bool {
        let alreadyUsesNewDefaults = newLayout.allSatisfy { entry in
            guard let rawValue = defaults.string(forKey: entry.slot.storageKey) else { return true }
            return PersonalizationSwipeAction(rawValue: rawValue) == entry.action
        }
        if alreadyUsesNewDefaults {
            return true
        }

        let usesOldDefaults = oldLayout.allSatisfy { entry in
            guard let rawValue = defaults.string(forKey: entry.key) else { return true }
            return PersonalizationSwipeAction(rawValue: rawValue) == entry.action
        }
        guard usesOldDefaults else { return false }

        for entry in newLayout {
            defaults.set(entry.action.rawValue, forKey: entry.slot.storageKey)
        }
        return true
    }

    static func tabOrder(showPlaylists: Bool) -> [PersonalizationTab] {
        if showPlaylists {
            return [.discover, .library, .playlists, .settings, .search]
        }
        return [.discover, .library, .settings, .search]
    }

    static func isSmartMixEnabled(_ mix: PersonalizationSmartMix, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: mix.storageKey) == nil ? true : defaults.bool(forKey: mix.storageKey)
    }

    static func discoverySectionOrder(from rawValue: String?) -> [PersonalizationDiscoverySection] {
        let rawSections = rawValue?
            .split(separator: ",")
            .compactMap { PersonalizationDiscoverySection(rawValue: String($0)) } ?? []
        return normalizedDiscoverySectionOrder(rawSections)
    }

    static func rawDiscoverySectionOrder(_ sections: [PersonalizationDiscoverySection]) -> String {
        normalizedDiscoverySectionOrder(sections)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func setDiscoverySectionOrder(_ sections: [PersonalizationDiscoverySection], in defaults: UserDefaults = .standard) {
        defaults.set(rawDiscoverySectionOrder(sections), forKey: PersonalizationPreferenceKey.discoverySectionOrder)
    }

    private static func normalizedDiscoverySectionOrder(_ sections: [PersonalizationDiscoverySection]) -> [PersonalizationDiscoverySection] {
        var result: [PersonalizationDiscoverySection] = []
        var seen = Set<PersonalizationDiscoverySection>()

        for section in sections where !seen.contains(section) {
            result.append(section)
            seen.insert(section)
        }

        for section in PersonalizationDiscoverySection.allCases where !seen.contains(section) {
            result.append(section)
            seen.insert(section)
        }

        return result
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

    @discardableResult
    static func resetSwipeActions(in defaults: UserDefaults = .standard) -> Bool {
        var didReset = false
        for group in PersonalizationSwipeGroup.allCases {
            didReset = resetSwipeActions(for: group, in: defaults) || didReset
        }
        return didReset
    }

    @discardableResult
    static func resetSwipeActions(for group: PersonalizationSwipeGroup, in defaults: UserDefaults = .standard) -> Bool {
        let didReset = group.slots.contains { slot in
            swipeAction(for: slot, in: defaults) != slot.defaultAction
        }

        guard didReset else { return false }

        for slot in group.slots {
            defaults.set(slot.defaultAction.rawValue, forKey: slot.storageKey)
        }
        normalizeSwipeActions(for: group, in: defaults)
        return true
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
