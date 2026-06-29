import Foundation

nonisolated enum PersonalizationPreferenceKey {
    static let migrationVersion = "ui.personalizationMigrationVersion"

    static let showPlaylistsTab = "ui.showPlaylistsTab"
    static let showPlaylistActions = "ui.showPlaylistActions"
    static let showFavoritesInLibrary = "ui.showFavoritesInLibrary"
    static let showFavoriteActions = "ui.showFavoriteActions"
    static let showInstantMixActions = "ui.showInstantMixActions"
    static let miniPlayerStyle = "ui.miniPlayerStyle"

    static let swipeLeftPrimary = "ui.swipe.leftPrimary"
    static let swipeLeftSecondary = "ui.swipe.leftSecondary"
    static let swipeRightPrimary = "ui.swipe.rightPrimary"
    static let swipeRightSecondary = "ui.swipe.rightSecondary"

    static let legacyEnablePlaylists = "enablePlaylists"
    static let legacyEnableFavorites = "enableFavorites"
    static let legacyEnableInstantMix = "enableInstantMix"
}

nonisolated enum PersonalizationTab: Equatable {
    case discover
    case library
    case playlists
    case settings
    case search
}

nonisolated enum PersonalizationSwipeSlot: String, CaseIterable {
    case leftPrimary
    case leftSecondary
    case rightPrimary
    case rightSecondary

    var storageKey: String {
        switch self {
        case .leftPrimary: return PersonalizationPreferenceKey.swipeLeftPrimary
        case .leftSecondary: return PersonalizationPreferenceKey.swipeLeftSecondary
        case .rightPrimary: return PersonalizationPreferenceKey.swipeRightPrimary
        case .rightSecondary: return PersonalizationPreferenceKey.swipeRightSecondary
        }
    }

    var titleKey: String {
        switch self {
        case .leftPrimary: return "swipe_left_1"
        case .leftSecondary: return "swipe_left_2"
        case .rightPrimary: return "swipe_right_1"
        case .rightSecondary: return "swipe_right_2"
        }
    }
}

nonisolated enum PersonalizationSwipeAction: String, CaseIterable {
    case none
    case favorite
    case addToPlaylist
    case playNext
    case addToQueue

    var titleKey: String {
        switch self {
        case .none: return "none"
        case .favorite: return "favorite"
        case .addToPlaylist: return "add_to_playlist_2"
        case .playNext: return "play_next"
        case .addToQueue: return "add_to_queue"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "minus.circle"
        case .favorite: return "heart"
        case .addToPlaylist: return "text.badge.plus"
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
    static let currentMigrationVersion = 1

    static let defaultValues: [String: Any] = [
        PersonalizationPreferenceKey.showPlaylistsTab: true,
        PersonalizationPreferenceKey.showPlaylistActions: true,
        PersonalizationPreferenceKey.showFavoritesInLibrary: true,
        PersonalizationPreferenceKey.showFavoriteActions: true,
        PersonalizationPreferenceKey.showInstantMixActions: true,
        PersonalizationPreferenceKey.miniPlayerStyle: PersonalizationMiniPlayerStyle.shelv.rawValue,
        PersonalizationPreferenceKey.swipeLeftPrimary: PersonalizationSwipeAction.favorite.rawValue,
        PersonalizationPreferenceKey.swipeLeftSecondary: PersonalizationSwipeAction.addToPlaylist.rawValue,
        PersonalizationPreferenceKey.swipeRightPrimary: PersonalizationSwipeAction.playNext.rawValue,
        PersonalizationPreferenceKey.swipeRightSecondary: PersonalizationSwipeAction.addToQueue.rawValue,
    ]

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        migrateLegacyKeysIfNeeded(in: defaults)
        defaults.register(defaults: defaultValues)
        normalizeSwipeActions(in: defaults)
    }

    static func migrateLegacyKeysIfNeeded(in defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: PersonalizationPreferenceKey.migrationVersion) < currentMigrationVersion else {
            return
        }

        if defaults.object(forKey: PersonalizationPreferenceKey.legacyEnablePlaylists) != nil {
            let enabled = defaults.bool(forKey: PersonalizationPreferenceKey.legacyEnablePlaylists)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showPlaylistsTab)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showPlaylistActions)
        }

        if defaults.object(forKey: PersonalizationPreferenceKey.legacyEnableFavorites) != nil {
            let enabled = defaults.bool(forKey: PersonalizationPreferenceKey.legacyEnableFavorites)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showFavoritesInLibrary)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showFavoriteActions)
        }

        if defaults.object(forKey: PersonalizationPreferenceKey.legacyEnableInstantMix) != nil {
            let enabled = defaults.bool(forKey: PersonalizationPreferenceKey.legacyEnableInstantMix)
            defaults.set(enabled, forKey: PersonalizationPreferenceKey.showInstantMixActions)
        }

        defaults.set(currentMigrationVersion, forKey: PersonalizationPreferenceKey.migrationVersion)
    }

    static func tabOrder(showPlaylists: Bool) -> [PersonalizationTab] {
        if showPlaylists {
            return [.discover, .library, .playlists, .settings, .search]
        }
        return [.discover, .library, .settings, .search]
    }

    static func swipeAction(for slot: PersonalizationSwipeSlot, in defaults: UserDefaults = .standard) -> PersonalizationSwipeAction {
        let rawValue = defaults.string(forKey: slot.storageKey)
        return rawValue.flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? defaultAction(for: slot)
    }

    static func visibleSwipeAction(for slot: PersonalizationSwipeSlot, in defaults: UserDefaults = .standard) -> PersonalizationSwipeAction {
        let action = swipeAction(for: slot, in: defaults)
        return isAvailable(action, in: defaults) ? action : .none
    }

    static func setSwipeAction(_ action: PersonalizationSwipeAction, for slot: PersonalizationSwipeSlot, in defaults: UserDefaults = .standard) {
        if action != .none {
            for otherSlot in PersonalizationSwipeSlot.allCases where otherSlot != slot && swipeAction(for: otherSlot, in: defaults) == action {
                defaults.set(PersonalizationSwipeAction.none.rawValue, forKey: otherSlot.storageKey)
            }
        }

        defaults.set(action.rawValue, forKey: slot.storageKey)
        normalizeSwipeActions(in: defaults)
    }

    static func resetSwipeActions(in defaults: UserDefaults = .standard) {
        defaults.set(PersonalizationSwipeAction.favorite.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftPrimary)
        defaults.set(PersonalizationSwipeAction.addToPlaylist.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftSecondary)
        defaults.set(PersonalizationSwipeAction.playNext.rawValue, forKey: PersonalizationPreferenceKey.swipeRightPrimary)
        defaults.set(PersonalizationSwipeAction.addToQueue.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)
        normalizeSwipeActions(in: defaults)
    }

    static func normalizeSwipeActions(in defaults: UserDefaults = .standard) {
        var used = Set<PersonalizationSwipeAction>()

        for slot in PersonalizationSwipeSlot.allCases {
            let rawValue = defaults.string(forKey: slot.storageKey)
            let current = rawValue.flatMap(PersonalizationSwipeAction.init(rawValue:)) ?? defaultAction(for: slot)

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
        case .favorite:
            return defaults.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions)
        case .addToPlaylist:
            return defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistActions)
        }
    }

    private static func defaultAction(for slot: PersonalizationSwipeSlot) -> PersonalizationSwipeAction {
        switch slot {
        case .leftPrimary: return .favorite
        case .leftSecondary: return .addToPlaylist
        case .rightPrimary: return .playNext
        case .rightSecondary: return .addToQueue
        }
    }

}
