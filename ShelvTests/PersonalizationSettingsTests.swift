import XCTest

final class PersonalizationSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PersonalizationSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsMatchCurrentVisibleBehavior() {
        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistsTab))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistActions))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showFavoritesInLibrary))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showRadio))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showGenreFilter))
        XCTAssertEqual(
            defaults.string(forKey: PersonalizationPreferenceKey.miniPlayerStyle),
            PersonalizationMiniPlayerStyle.shelv.rawValue
        )
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .favorite)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftSecondary, in: defaults), .addToPlaylist)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightPrimary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightSecondary, in: defaults), .addToQueue)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightTertiary, in: defaults), .instantMix)
    }

    func testClearAlbumGenreFilterResetsStoredSelection() {
        defaults.set("Jazz", forKey: PersonalizationPreferenceKey.albumGenreFilter)

        PersonalizationSettings.clearAlbumGenreFilter(in: defaults)

        XCTAssertEqual(defaults.string(forKey: PersonalizationPreferenceKey.albumGenreFilter), "")
    }

    func testLegacyDisabledKeysMigrateToSeparateVisibilityAndActionKeys() {
        defaults.set(false, forKey: PersonalizationPreferenceKey.legacyEnablePlaylists)
        defaults.set(false, forKey: PersonalizationPreferenceKey.legacyEnableFavorites)
        defaults.set(false, forKey: PersonalizationPreferenceKey.legacyEnableInstantMix)

        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistsTab))
        XCTAssertFalse(defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistActions))
        XCTAssertFalse(defaults.bool(forKey: PersonalizationPreferenceKey.showFavoritesInLibrary))
        XCTAssertFalse(defaults.bool(forKey: PersonalizationPreferenceKey.showFavoriteActions))
        XCTAssertFalse(defaults.bool(forKey: PersonalizationPreferenceKey.showInstantMixActions))
    }

    func testPlaylistVisibilityAndActionsStayIndependent() {
        PersonalizationSettings.registerDefaults(in: defaults)

        defaults.set(false, forKey: PersonalizationPreferenceKey.showPlaylistsTab)
        defaults.set(true, forKey: PersonalizationPreferenceKey.showPlaylistActions)

        XCTAssertEqual(
            PersonalizationSettings.tabOrder(showPlaylists: defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistsTab)),
            [.discover, .library, .settings, .search]
        )
        XCTAssertTrue(PersonalizationSettings.isAvailable(.addToPlaylist, in: defaults))

        defaults.set(true, forKey: PersonalizationPreferenceKey.showPlaylistsTab)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showPlaylistActions)
        defaults.set(PersonalizationSwipeAction.addToPlaylist.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftSecondary)

        PersonalizationSettings.normalizeSwipeActions(in: defaults)

        XCTAssertEqual(
            PersonalizationSettings.tabOrder(showPlaylists: defaults.bool(forKey: PersonalizationPreferenceKey.showPlaylistsTab)),
            [.discover, .library, .playlists, .settings, .search]
        )
        XCTAssertFalse(PersonalizationSettings.isAvailable(.addToPlaylist, in: defaults))
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftSecondary, in: defaults), .addToPlaylist)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .leftSecondary, in: defaults), .none)
    }

    func testDisabledFeatureActionsKeepConfiguredSwipeSlotsHidden() {
        PersonalizationSettings.registerDefaults(in: defaults)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showFavoriteActions)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showPlaylistActions)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showInstantMixActions)

        PersonalizationSettings.normalizeSwipeActions(in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .favorite)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftSecondary, in: defaults), .addToPlaylist)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightPrimary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightSecondary, in: defaults), .addToQueue)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightTertiary, in: defaults), .instantMix)

        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .leftPrimary, in: defaults), .none)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .leftSecondary, in: defaults), .none)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .rightPrimary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .rightSecondary, in: defaults), .addToQueue)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .rightTertiary, in: defaults), .none)
    }

    func testReenabledFeatureRestoresConfiguredSwipeAction() {
        PersonalizationSettings.registerDefaults(in: defaults)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showFavoriteActions)

        PersonalizationSettings.normalizeSwipeActions(in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .favorite)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .leftPrimary, in: defaults), .none)

        defaults.set(true, forKey: PersonalizationPreferenceKey.showFavoriteActions)
        PersonalizationSettings.normalizeSwipeActions(in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .favorite)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .leftPrimary, in: defaults), .favorite)
    }

    func testHiddenFeatureActionCanStillBeAssignedAndLaterShown() {
        PersonalizationSettings.registerDefaults(in: defaults)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showPlaylistActions)

        PersonalizationSettings.setSwipeAction(.addToPlaylist, for: .leftPrimary, in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .addToPlaylist)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftSecondary, in: defaults), .none)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .leftPrimary, in: defaults), .none)

        defaults.set(true, forKey: PersonalizationPreferenceKey.showPlaylistActions)
        PersonalizationSettings.normalizeSwipeActions(in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .addToPlaylist)
        XCTAssertEqual(PersonalizationSettings.visibleSwipeAction(for: .leftPrimary, in: defaults), .addToPlaylist)
    }

    func testDuplicateSwipeActionsMoveBetweenSlotsExceptNone() {
        PersonalizationSettings.registerDefaults(in: defaults)

        PersonalizationSettings.setSwipeAction(.none, for: .rightPrimary, in: defaults)
        PersonalizationSettings.setSwipeAction(.playNext, for: .leftPrimary, in: defaults)
        PersonalizationSettings.setSwipeAction(.playNext, for: .leftSecondary, in: defaults)
        PersonalizationSettings.setSwipeAction(.none, for: .rightSecondary, in: defaults)
        PersonalizationSettings.setSwipeAction(.none, for: .rightTertiary, in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .none)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftSecondary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightPrimary, in: defaults), .none)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightSecondary, in: defaults), .none)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightTertiary, in: defaults), .none)
    }

    func testSelectingUsedSwipeActionMovesItFromPreviousSlot() {
        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightPrimary, in: defaults), .playNext)

        PersonalizationSettings.setSwipeAction(.playNext, for: .leftPrimary, in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightPrimary, in: defaults), .none)
    }

    func testMigratesOldDefaultSongSwipeSlotsToSongInstantMix() {
        defaults.set(1, forKey: PersonalizationPreferenceKey.migrationVersion)
        defaults.set(PersonalizationSwipeAction.favorite.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftPrimary)
        defaults.set(PersonalizationSwipeAction.addToPlaylist.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftSecondary)
        defaults.set(PersonalizationSwipeAction.playNext.rawValue, forKey: PersonalizationPreferenceKey.swipeRightPrimary)
        defaults.set(PersonalizationSwipeAction.addToQueue.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)

        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: PersonalizationPreferenceKey.migrationVersion), PersonalizationSettings.currentMigrationVersion)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightPrimary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightSecondary, in: defaults), .addToQueue)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightTertiary, in: defaults), .instantMix)
    }

    func testMigrationDoesNotAddSongInstantMixToCustomizedSwipeSlots() {
        defaults.set(1, forKey: PersonalizationPreferenceKey.migrationVersion)
        defaults.set(PersonalizationSwipeAction.favorite.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftPrimary)
        defaults.set(PersonalizationSwipeAction.playNext.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftSecondary)
        defaults.set(PersonalizationSwipeAction.none.rawValue, forKey: PersonalizationPreferenceKey.swipeRightPrimary)
        defaults.set(PersonalizationSwipeAction.addToQueue.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)

        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftSecondary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightSecondary, in: defaults), .addToQueue)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightTertiary, in: defaults), .none)
    }

    func testMigratesPreviousSongInstantMixSwipeOrderToOuterSlot() {
        defaults.set(2, forKey: PersonalizationPreferenceKey.migrationVersion)
        defaults.set(PersonalizationSwipeAction.favorite.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftPrimary)
        defaults.set(PersonalizationSwipeAction.addToPlaylist.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftSecondary)
        defaults.set(PersonalizationSwipeAction.playNext.rawValue, forKey: PersonalizationPreferenceKey.swipeRightPrimary)
        defaults.set(PersonalizationSwipeAction.instantMix.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)
        defaults.set(PersonalizationSwipeAction.addToQueue.rawValue, forKey: PersonalizationPreferenceKey.swipeRightTertiary)

        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: PersonalizationPreferenceKey.migrationVersion), PersonalizationSettings.currentMigrationVersion)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightPrimary, in: defaults), .playNext)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightSecondary, in: defaults), .addToQueue)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightTertiary, in: defaults), .instantMix)
    }

    func testMigrationKeepsCustomizedSongInstantMixSwipeOrder() {
        defaults.set(2, forKey: PersonalizationPreferenceKey.migrationVersion)
        defaults.set(PersonalizationSwipeAction.favorite.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftPrimary)
        defaults.set(PersonalizationSwipeAction.addToPlaylist.rawValue, forKey: PersonalizationPreferenceKey.swipeLeftSecondary)
        defaults.set(PersonalizationSwipeAction.playNext.rawValue, forKey: PersonalizationPreferenceKey.swipeRightPrimary)
        defaults.set(PersonalizationSwipeAction.instantMix.rawValue, forKey: PersonalizationPreferenceKey.swipeRightSecondary)
        defaults.set(PersonalizationSwipeAction.none.rawValue, forKey: PersonalizationPreferenceKey.swipeRightTertiary)

        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightSecondary, in: defaults), .instantMix)
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .rightTertiary, in: defaults), .none)
    }

    func testIPhoneTabOrderKeepsSettingsImmediatelyBeforeSearch() {
        XCTAssertEqual(
            PersonalizationSettings.tabOrder(showPlaylists: true),
            [.discover, .library, .playlists, .settings, .search]
        )
        XCTAssertEqual(
            PersonalizationSettings.tabOrder(showPlaylists: false),
            [.discover, .library, .settings, .search]
        )
    }
}
