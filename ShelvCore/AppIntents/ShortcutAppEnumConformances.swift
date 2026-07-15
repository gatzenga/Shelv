import AppIntents

nonisolated extension ShortcutPlaybackOrder: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "shortcut_order_type"
    }

    static var caseDisplayRepresentations: [ShortcutPlaybackOrder: DisplayRepresentation] {
        [
            .inOrder: DisplayRepresentation(
                title: "shortcut_order_in_order",
                synonyms: ["In Order", "Album Order", "Track Order"]
            ),
            .shuffled: DisplayRepresentation(
                title: "shortcut_order_shuffled",
                synonyms: ["Shuffle", "Shuffled Order", "Random Order"]
            ),
        ]
    }
}

#if os(iOS) || os(macOS)
/// Human-readable choices for the runtime text-playback prompt. The visible
/// strings intentionally double as safe fallbacks if Shortcuts does not load
/// the app's localization table while presenting a dynamic disambiguation.
nonisolated enum ShelvTextPlaybackChoice: String, CaseIterable, AppEnum, Sendable {
    case play
    case shuffle

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Playback" }

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .play: "Play",
            .shuffle: "Shuffle",
        ]
    }

    var playbackOrder: ShortcutPlaybackOrder {
        switch self {
        case .play: .inOrder
        case .shuffle: .shuffled
        }
    }
}
#endif

nonisolated extension ShortcutSmartMix: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "shortcut_mix_type"
    }

    static var caseDisplayRepresentations: [ShortcutSmartMix: DisplayRepresentation] {
        [
            .newest: DisplayRepresentation(
                title: "shortcut_mix_newest",
                synonyms: [
                    "Newest Tracks", "Latest Tracks", "Latest Music", "New Music",
                    "Recently Added Tracks", "Recently Added Songs", "Recently Added Music",
                ]
            ),
            .frequent: DisplayRepresentation(
                title: "shortcut_mix_frequent",
                synonyms: ["Frequently Played Tracks", "Most Played", "Top Tracks"]
            ),
            .recent: DisplayRepresentation(
                title: "shortcut_mix_recent",
                synonyms: ["Recently Played Tracks", "Recent Tracks", "Recent Music"]
            ),
            .shuffleAll: DisplayRepresentation(
                title: "shortcut_shuffle_all",
                synonyms: ["Shuffle All Tracks", "Shuffle All Songs", "Shuffle My Library"]
            ),
        ]
    }
}

nonisolated extension ShortcutDownloadsMode: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "shortcut_downloads_type"
    }

    static var caseDisplayRepresentations: [ShortcutDownloadsMode: DisplayRepresentation] {
        [
            .all: DisplayRepresentation(
                title: "shortcut_downloads_all",
                synonyms: ["All Downloads", "Downloaded Music", "Downloaded Tracks"]
            ),
            .shuffled: DisplayRepresentation(
                title: "shortcut_downloads_shuffled",
                synonyms: ["Shuffled Downloads", "Shuffle Downloads"]
            ),
            .newest: DisplayRepresentation(
                title: "shortcut_downloads_newest",
                synonyms: ["Newest Downloads", "Latest Downloads"]
            ),
        ]
    }
}
