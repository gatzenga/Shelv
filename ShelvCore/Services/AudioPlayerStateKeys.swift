enum AudioPlayerStateKey {
    static let savePlayerState = "savePlayerState"

    #if os(macOS)
    static let queue          = "shelv_mac_queue"
    static let index          = "shelv_mac_currentIndex"
    static let playNextQueue  = "shelv_mac_playNextQueue"
    static let userQueue      = "shelv_mac_userQueue"
    static let resumeTime     = "shelv_mac_currentTime"
    static let isShuffled     = "shelv_mac_isShuffled"
    static let repeatMode     = "shelv_mac_repeatMode"
    static let truthAlbum     = "shelv_mac_truthAlbum"
    static let truthPlayNext  = "shelv_mac_truthPlayNext"
    static let truthUserQueue = "shelv_mac_truthUserQueue"
    static let volume         = "shelv_mac_volume"
    #else
    static let queue          = "shelv_player_queue"
    static let index          = "shelv_player_currentIndex"
    static let playNextQueue  = "shelv_player_playNextQueue"
    static let userQueue      = "shelv_player_userQueue"
    static let resumeTime     = "shelv_player_resumeTime"
    static let isShuffled     = "shelv_player_isShuffled"
    static let repeatMode     = "shelv_player_repeatMode"
    static let truthAlbum     = "shelv_player_truthAlbum"
    static let truthPlayNext  = "shelv_player_truthPlayNext"
    static let truthUserQueue = "shelv_player_truthUserQueue"
    #endif
}

#if os(tvOS)
/// tvOS-only: Queue-State wird in eine Datei persistiert statt in UserDefaults.
/// CFPreferences hat auf tvOS ein hartes Groessenlimit und bricht die App bei grossen
/// Shuffle-Queues per abort() ab. Caches genuegt; wird der Eintrag bei einer
/// System-Bereinigung geloescht, entfaellt nur die Wiederherstellung nach Neustart.
struct AudioPlayerPersistedQueueState: Codable {
    var queue: [Song]
    var playNextQueue: [Song]
    var userQueue: [Song]
    var truthAlbum: [Song]
    var truthPlayNext: [Song]
    var truthUserQueue: [Song]
}
#endif
