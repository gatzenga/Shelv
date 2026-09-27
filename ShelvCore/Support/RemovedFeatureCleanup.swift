import Foundation

/// One-time cleanup after a feature was removed.
///
/// Deleting the code stops new data from being written, but every device still
/// carries what the old version left behind: preferences nobody reads any more,
/// a change token for a record type that no longer exists, and a queue of
/// deletions that will never be sent. This clears them once, so an upgraded
/// install looks like a fresh one.
///
/// Only keys that belonged to a removed feature are listed here; every other
/// setting stays untouched.
nonisolated enum RemovedFeatureCleanup {
    private static let didRunKey = "shelv_removed_feature_cleanup_v1"
    private static let didRunPlayHistoryKey = "shelv_removed_play_history_cleanup_v1"

    /// Preference this feature owned but scrobbling still needs: the share of
    /// a track that has to be heard before it counts. Moved to its own key so
    /// nothing carries the old name, keeping whatever the listener had chosen.
    private static let legacyPlayThresholdKey = "recapThreshold"
    static let playThresholdKey = "playCountThreshold"

    // MARK: - Identifiers of the removed feature
    //
    // These names have to stay verbatim: they are the only handle on the data an
    // older version left behind. Nothing writes to any of them any more, they
    // exist so the migrations can find what has to go. Keeping them together
    // means the rest of the codebase carries no trace of the feature at all.

    /// CloudKit zone the sync used to live in. Its remaining records are carried
    /// into the current zone, then the zone is deleted.
    static let legacyCloudZoneName = "ShelveRecapZone"
    /// Record types of the removed feature. They are not carried over.
    static let legacyCloudRecordTypes: Set<String> = ["RecapMarker", "RecapSettings"]
    /// Where the play log database used to sit, relative to its container.
    static let legacyDatabaseSubpath = "shelv_recap/recap.db"

    private static let obsoleteKeys = [
        "recapEnabled",
        "recapWeeklyEnabled",
        "recapMonthlyEnabled",
        "recapYearlyEnabled",
        "iCloudSyncRecapEnabled",
        "recap_last_gen_week",
        "recap_last_gen_month",
        "recap_last_gen_year",
        "recap_processed_weeks",
        "shelv_recap_playlist_ids",
        "shelv_ck_zone_token_recap",
        "shelv_ck_pending_marker_deletions",
    ]

    /// Preferences of the local play history database. The database file itself
    /// is removed by `ScrobbleOutbox` once its pending scrobbles are carried over,
    /// and the plays in iCloud by `CloudKitSyncService`.
    private static let obsoletePlayHistoryKeys = [
        "mixUseDatabase",
        "iCloudSyncPlayHistoryEnabled",
        "shelv_ck_zone_token_play_history",
        "shelv_ck_pending_play_event_deletions",
    ]

    /// Per-server keys, stored as `<base>.<serverId>`.
    private static let obsoletePrefixes = [
        "recapWeeklyRetention.",
        "recapMonthlyRetention.",
        "recapYearlyRetention.",
        "recap_retention_updated_at.",
        "recap_retention_synced_at.",
    ]

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        // The threshold moves even on a repeat run: a device that syncs the old
        // key from a backup should still end up on the new one.
        if defaults.object(forKey: playThresholdKey) == nil,
           let carried = defaults.object(forKey: legacyPlayThresholdKey) as? Int {
            defaults.set(carried, forKey: playThresholdKey)
        }
        defaults.removeObject(forKey: legacyPlayThresholdKey)

        if !defaults.bool(forKey: didRunPlayHistoryKey) {
            for key in obsoletePlayHistoryKeys {
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: didRunPlayHistoryKey)
        }

        guard !defaults.bool(forKey: didRunKey) else { return }
        for key in obsoleteKeys {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys
        where obsoletePrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: didRunKey)
    }
}
