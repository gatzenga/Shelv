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
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showDiscoverInsights))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showRadio))
        XCTAssertTrue(defaults.bool(forKey: PersonalizationPreferenceKey.showGenreFilter))
        XCTAssertEqual(defaults.object(forKey: PersonalizationPreferenceKey.showDiscoverAirPlay) as? Bool, false)
        XCTAssertTrue(PersonalizationSettings.isSmartMixEnabled(.newest, in: defaults))
        XCTAssertTrue(PersonalizationSettings.isSmartMixEnabled(.frequent, in: defaults))
        XCTAssertTrue(PersonalizationSettings.isSmartMixEnabled(.recent, in: defaults))
        XCTAssertTrue(PersonalizationSettings.isSmartMixEnabled(.random, in: defaults))
        XCTAssertEqual(
            PersonalizationSettings.discoverySectionOrder(
                from: defaults.string(forKey: PersonalizationPreferenceKey.discoverySectionOrder)
            ),
            [.smartMixes, .recentlyAdded, .recentlyPlayed, .frequentlyPlayed, .randomAlbums]
        )
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

    func testSharedAppDefaultsMatchFreshInstallPolicy() {
        let expectedKeys: Set<String> = [
            "recapEnabled",
            "recapWeeklyEnabled",
            "recapMonthlyEnabled",
            "recapYearlyEnabled",
            "recapThreshold",
            "enableDownloads",
            "offlineModeEnabled",
            "preventSleepDuringDownloads",
            "maxBulkDownloadStorageGB",
            "transcodingEnabled",
            "transcodingWifiCodec",
            "transcodingWifiBitrate",
            "transcodingCellularCodec",
            "transcodingCellularBitrate",
            "transcodingDownloadCodec",
            "transcodingDownloadBitrate",
            "gaplessEnabled",
            "replayGainEnabled",
            "replayGainMode",
            "queueSyncMode",
            "autoFetchLyrics",
            "includeNavidromeLyrics",
            "useCustomLrcLibServer",
            "lrcLibOnlineFallbackEnabled",
            "streamPreCacheAheadCount",
            "streamPreCacheEnabled",
            "infinityMixAheadCount",
            "iCloudSyncEnabled",
            "iCloudSyncPlayHistoryEnabled",
            "iCloudSyncRecapEnabled",
            "iCloudSyncLyricsServerEnabled",
            "iCloudSyncRadioStationsEnabled",
            "iCloudSyncUICustomizationsEnabled",
            "mixUseDatabase",
        ]

        XCTAssertEqual(Set(ShelvDefaultSettings.registeredValues.keys), expectedKeys)

        ShelvDefaultSettings.registerDefaults(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: "recapEnabled"))
        #if os(tvOS)
        XCTAssertFalse(defaults.bool(forKey: "enableDownloads"))
        #else
        XCTAssertTrue(defaults.bool(forKey: "enableDownloads"))
        #endif
        XCTAssertTrue(defaults.bool(forKey: "autoFetchLyrics"))
        XCTAssertTrue(defaults.bool(forKey: "includeNavidromeLyrics"))
        XCTAssertTrue(defaults.bool(forKey: "lrcLibOnlineFallbackEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "iCloudSyncPlayHistoryEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "iCloudSyncRecapEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "iCloudSyncLyricsServerEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "iCloudSyncRadioStationsEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "iCloudSyncUICustomizationsEnabled"))

        XCTAssertFalse(defaults.bool(forKey: "offlineModeEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "preventSleepDuringDownloads"))
        XCTAssertFalse(defaults.bool(forKey: "transcodingEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "gaplessEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "replayGainEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "useCustomLrcLibServer"))
        XCTAssertFalse(defaults.bool(forKey: "streamPreCacheEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "iCloudSyncEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "mixUseDatabase"))

        XCTAssertEqual(defaults.integer(forKey: "recapThreshold"), 30)
        XCTAssertEqual(defaults.integer(forKey: "maxBulkDownloadStorageGB"), 10)
        XCTAssertEqual(defaults.integer(forKey: "transcodingWifiBitrate"), 256)
        XCTAssertEqual(defaults.integer(forKey: "transcodingCellularBitrate"), 128)
        XCTAssertEqual(defaults.integer(forKey: "transcodingDownloadBitrate"), 192)
        XCTAssertEqual(defaults.integer(forKey: "streamPreCacheAheadCount"), 1)
        XCTAssertEqual(defaults.integer(forKey: "infinityMixAheadCount"), 1)

        XCTAssertEqual(defaults.string(forKey: "transcodingWifiCodec"), "raw")
        XCTAssertEqual(defaults.string(forKey: "transcodingCellularCodec"), "raw")
        XCTAssertEqual(defaults.string(forKey: "transcodingDownloadCodec"), "raw")
        XCTAssertEqual(defaults.string(forKey: "replayGainMode"), "track")
        XCTAssertEqual(defaults.string(forKey: "queueSyncMode"), "off")

        defaults.set(false, forKey: "enableDownloads")
        ShelvDefaultSettings.registerDefaults(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: "enableDownloads"))
    }

    func testCloudUICustomizationKeysCoverVisibleCustomizationSettings() {
        var expected: Set<String> = [
            PersonalizationPreferenceKey.showPlaylistsTab,
            PersonalizationPreferenceKey.showPlaylistActions,
            PersonalizationPreferenceKey.showFavoritesInLibrary,
            PersonalizationPreferenceKey.showFavoriteActions,
            PersonalizationPreferenceKey.showInstantMixActions,
            PersonalizationPreferenceKey.showDiscoverInsights,
            PersonalizationPreferenceKey.showRadio,
            PersonalizationPreferenceKey.showGenreFilter,
            PersonalizationPreferenceKey.showDiscoverAirPlay,
            PersonalizationPreferenceKey.albumGenreFilter,
            PersonalizationPreferenceKey.miniPlayerStyle,
            PersonalizationPreferenceKey.discoverySectionOrder,
        ]
        for mix in PersonalizationSmartMix.allCases {
            expected.insert(mix.storageKey)
        }
        for slot in PersonalizationSwipeSlot.allCases {
            expected.insert(slot.storageKey)
        }

        XCTAssertEqual(PersonalizationSettings.cloudSyncedUICustomizationKeys, expected)
    }

    func testCloudUICustomizationSnapshotAppliesPlatformSpecificValues() {
        PersonalizationSettings.registerDefaults(in: defaults)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showRadio)
        defaults.set(false, forKey: PersonalizationPreferenceKey.showDiscoverInsights)
        defaults.set(true, forKey: PersonalizationPreferenceKey.showDiscoverAirPlay)
        defaults.set(PersonalizationMiniPlayerStyle.native.rawValue, forKey: PersonalizationPreferenceKey.miniPlayerStyle)
        defaults.set("Jazz", forKey: PersonalizationPreferenceKey.albumGenreFilter)
        PersonalizationSettings.setDiscoverySectionOrder([.randomAlbums, .smartMixes], in: defaults)
        PersonalizationSettings.setSwipeAction(.playNext, for: .leftPrimary, in: defaults)

        let snapshot = PersonalizationSettings.cloudUICustomizationSnapshot(in: defaults)

        let targetSuiteName = "PersonalizationSettingsTests.target.\(UUID().uuidString)"
        let targetDefaults = UserDefaults(suiteName: targetSuiteName)!
        defer { targetDefaults.removePersistentDomain(forName: targetSuiteName) }
        PersonalizationSettings.registerDefaults(in: targetDefaults)

        PersonalizationSettings.applyCloudUICustomizationSnapshot(snapshot, in: targetDefaults)

        XCTAssertFalse(targetDefaults.bool(forKey: PersonalizationPreferenceKey.showRadio))
        XCTAssertFalse(targetDefaults.bool(forKey: PersonalizationPreferenceKey.showDiscoverInsights))
        XCTAssertTrue(targetDefaults.bool(forKey: PersonalizationPreferenceKey.showDiscoverAirPlay))
        XCTAssertEqual(targetDefaults.string(forKey: PersonalizationPreferenceKey.miniPlayerStyle), PersonalizationMiniPlayerStyle.native.rawValue)
        XCTAssertEqual(targetDefaults.string(forKey: PersonalizationPreferenceKey.albumGenreFilter), "Jazz")
        XCTAssertEqual(
            PersonalizationSettings.discoverySectionOrder(
                from: targetDefaults.string(forKey: PersonalizationPreferenceKey.discoverySectionOrder)
            ),
            [.randomAlbums, .smartMixes, .recentlyAdded, .recentlyPlayed, .frequentlyPlayed]
        )
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: targetDefaults), .playNext)
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

    func testSmartMixVisibilityUsesRegisteredDefaultsAndStoredValues() {
        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertTrue(PersonalizationSettings.isSmartMixEnabled(.newest, in: defaults))

        defaults.set(false, forKey: PersonalizationSmartMix.newest.storageKey)

        XCTAssertFalse(PersonalizationSettings.isSmartMixEnabled(.newest, in: defaults))
        XCTAssertTrue(PersonalizationSettings.isSmartMixEnabled(.frequent, in: defaults))
    }

    func testDiscoverySectionOrderNormalizesInvalidStoredValues() {
        let stored = [
            PersonalizationDiscoverySection.randomAlbums.rawValue,
            "legacy",
            PersonalizationDiscoverySection.recentlyAdded.rawValue,
            PersonalizationDiscoverySection.randomAlbums.rawValue,
        ].joined(separator: ",")

        XCTAssertEqual(
            PersonalizationSettings.discoverySectionOrder(from: stored),
            [.randomAlbums, .recentlyAdded, .smartMixes, .recentlyPlayed, .frequentlyPlayed]
        )
    }

    func testSetDiscoverySectionOrderPersistsNormalizedRawValue() {
        PersonalizationSettings.setDiscoverySectionOrder(
            [.frequentlyPlayed, .smartMixes, .recentlyPlayed, .frequentlyPlayed],
            in: defaults
        )

        XCTAssertEqual(
            defaults.string(forKey: PersonalizationPreferenceKey.discoverySectionOrder),
            [
                PersonalizationDiscoverySection.frequentlyPlayed.rawValue,
                PersonalizationDiscoverySection.smartMixes.rawValue,
                PersonalizationDiscoverySection.recentlyPlayed.rawValue,
                PersonalizationDiscoverySection.recentlyAdded.rawValue,
                PersonalizationDiscoverySection.randomAlbums.rawValue,
            ].joined(separator: ",")
        )
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

    func testResetSwipeActionsReportsNoChangeWhenAlreadyDefaults() {
        PersonalizationSettings.registerDefaults(in: defaults)

        XCTAssertFalse(PersonalizationSettings.resetSwipeActions(in: defaults))
        XCTAssertFalse(PersonalizationSettings.resetSwipeActions(for: .songs, in: defaults))
    }

    func testResetSwipeActionsReportsChangeWhenValuesReset() {
        PersonalizationSettings.registerDefaults(in: defaults)
        PersonalizationSettings.setSwipeAction(.none, for: .leftPrimary, in: defaults)

        XCTAssertTrue(PersonalizationSettings.resetSwipeActions(for: .songs, in: defaults))
        XCTAssertEqual(PersonalizationSettings.swipeAction(for: .leftPrimary, in: defaults), .favorite)
        XCTAssertFalse(PersonalizationSettings.resetSwipeActions(for: .songs, in: defaults))
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
