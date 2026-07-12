#if os(iOS) || os(tvOS)
import Intents
import OSLog

/// Supplies the affinity signals Siri uses when choosing between Shelv and
/// Apple Music. Siri-triggered playback is deliberately excluded because the
/// system already records those interactions itself.
@MainActor
final class SiriMediaAppSelectionService {
    static let shared = SiriMediaAppSelectionService()

    private struct PendingDonation {
        let generation: Int
        let intent: INPlayMediaIntent
    }

    private let logger = Logger(
        subsystem: "ch.vkugler.Shelv",
        category: "SiriAppSelection"
    )
    private var systemIntentDepth = 0
    private var pendingDonation: PendingDonation?

    private init() {}

    var isHandlingSystemIntent: Bool { systemIntentDepth > 0 }

    func beginSystemIntent() {
        systemIntentDepth += 1
        pendingDonation = nil
    }

    func endSystemIntent() {
        systemIntentDepth = max(0, systemIntentDepth - 1)
    }

    func updateUserContext(numberOfLibraryItems: Int) {
        let context = INMediaUserContext()
        // Shelv doesn't sell a media subscription. The library-size signal is
        // accurate; claiming a subscription here would misuse Apple's API.
        context.subscriptionStatus = .unknown
        context.numberOfLibraryItems = max(0, numberOfLibraryItems)
        context.becomeCurrent()
    }

    func prepareMusicDonation(
        songs: [Song],
        startIndex: Int,
        shuffled: Bool,
        generation: Int
    ) {
        guard !isHandlingSystemIntent,
              songs.indices.contains(startIndex)
        else { return }

        let selected = songs[startIndex]
        let mediaItem = INMediaItem(
            identifier: selected.id,
            title: selected.title,
            type: .song,
            artwork: nil
        )
        let search = INMediaSearch(
            mediaType: .song,
            sortOrder: .unknown,
            mediaName: selected.title,
            artistName: selected.artist,
            albumName: selected.album,
            genreNames: selected.genre.map { [$0] },
            moodNames: selected.moods,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: selected.id
        )
        let intent = INPlayMediaIntent(
            mediaItems: [mediaItem],
            mediaContainer: inferredContainer(for: songs),
            playShuffled: shuffled,
            playbackRepeatMode: .none,
            resumePlayback: false,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: search
        )
        pendingDonation = PendingDonation(generation: generation, intent: intent)
    }

    func prepareRadioDonation(
        station: RadioStationDisplayItem,
        generation: Int
    ) {
        guard !isHandlingSystemIntent else { return }
        let mediaItem = INMediaItem(
            identifier: station.id,
            title: station.name,
            type: .radioStation,
            artwork: nil
        )
        let search = INMediaSearch(
            mediaType: .radioStation,
            sortOrder: .unknown,
            mediaName: station.name,
            artistName: nil,
            albumName: nil,
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: station.id
        )
        let intent = INPlayMediaIntent(
            mediaItems: [mediaItem],
            mediaContainer: nil,
            playShuffled: false,
            playbackRepeatMode: .none,
            resumePlayback: false,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: search
        )
        pendingDonation = PendingDonation(generation: generation, intent: intent)
    }

    func playbackDidStart(generation: Int) {
        guard !isHandlingSystemIntent,
              let pendingDonation,
              pendingDonation.generation == generation
        else { return }
        self.pendingDonation = nil

        Task {
            do {
                try await INInteraction(intent: pendingDonation.intent, response: nil).donate()
            } catch {
                logger.error(
                    "Media interaction donation failed error=\(String(describing: error), privacy: .private(mask: .hash))"
                )
            }
        }
    }

    func playbackDidFail(generation: Int) {
        guard pendingDonation?.generation == generation else { return }
        pendingDonation = nil
    }

    private func inferredContainer(for songs: [Song]) -> INMediaItem? {
        guard let first = songs.first else { return nil }

        if let albumID = first.albumId,
           !albumID.isEmpty,
           let album = first.album,
           !album.isEmpty,
           songs.allSatisfy({ $0.albumId == albumID }) {
            return INMediaItem(
                identifier: albumID,
                title: album,
                type: .album,
                artwork: nil
            )
        }

        if let artistID = first.artistId,
           !artistID.isEmpty,
           let artist = first.artist,
           !artist.isEmpty,
           songs.allSatisfy({ $0.artistId == artistID }) {
            return INMediaItem(
                identifier: artistID,
                title: artist,
                type: .artist,
                artwork: nil
            )
        }

        return nil
    }
}
#endif
