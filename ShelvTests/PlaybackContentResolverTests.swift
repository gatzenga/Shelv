import XCTest

final class PlaybackContentResolverTests: XCTestCase {
    private enum FixtureError: Error {
        case unavailable
    }

    @MainActor
    func testStoredArtistAlbumPreferenceIsAvailableWithoutAView() {
        let suiteName = "ArtistAlbumPlaybackOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("year", forKey: ArtistAlbumPlaybackOrder.sortDefaultsKey)
        defaults.set("ascending", forKey: ArtistAlbumPlaybackOrder.directionDefaultsKey)

        XCTAssertEqual(
            ArtistAlbumPlaybackOrder.storedPreference(defaults: defaults),
            ArtistAlbumSortPreference(sortRaw: "year", directionRaw: "ascending")
        )
    }

    func testArtistAlbumPreferenceAcceptsEveryPlatformRawValue() {
        XCTAssertEqual(
            ArtistAlbumSortPreference(sortRaw: "alphabeticalByName", directionRaw: "descending").kind,
            .alphabetical
        )
        XCTAssertEqual(
            ArtistAlbumSortPreference(sortRaw: "name", directionRaw: "descending").kind,
            .alphabetical
        )
        XCTAssertEqual(
            ArtistAlbumSortPreference(sortRaw: "frequent", directionRaw: "descending").kind,
            .frequent
        )
        XCTAssertEqual(
            ArtistAlbumSortPreference(sortRaw: "mostPlayed", directionRaw: "descending").kind,
            .frequent
        )
        XCTAssertEqual(
            ArtistAlbumSortPreference(sortRaw: "newest", directionRaw: "descending").kind,
            .newest
        )
        XCTAssertEqual(
            ArtistAlbumSortPreference(sortRaw: "recentlyAdded", directionRaw: "descending").kind,
            .newest
        )
    }

    func testArtistAlbumOrderAppliesNameYearPlayCountAndCreatedPreferences() {
        let albums = [
            Album(
                id: "middle",
                name: "Beta",
                year: 2005,
                playCount: 30,
                created: Date(timeIntervalSince1970: 200)
            ),
            Album(
                id: "newest",
                name: "Gamma",
                year: 2020,
                playCount: 10,
                created: Date(timeIntervalSince1970: 300)
            ),
            Album(
                id: "oldest",
                name: "Alpha",
                year: 1990,
                playCount: 20,
                created: Date(timeIntervalSince1970: 100)
            ),
        ]

        XCTAssertEqual(
            sortedAlbumIDs(albums, sort: "alphabeticalByName", direction: "descending"),
            ["oldest", "middle", "newest"]
        )
        XCTAssertEqual(
            sortedAlbumIDs(albums, sort: "year", direction: "ascending"),
            ["oldest", "middle", "newest"]
        )
        XCTAssertEqual(
            sortedAlbumIDs(albums, sort: "year", direction: "descending"),
            ["newest", "middle", "oldest"]
        )
        XCTAssertEqual(
            sortedAlbumIDs(albums, sort: "frequent", direction: "descending"),
            ["middle", "oldest", "newest"]
        )
        XCTAssertEqual(
            sortedAlbumIDs(albums, sort: "newest", direction: "descending"),
            ["newest", "middle", "oldest"]
        )
    }

    func testSongAlbumAndPlaylistUseTheirMatchingContentLoaders() async throws {
        let calls = CallRecorder()
        let provider = PlaybackContentProvider(
            song: { id in
                await calls.record("song:\(id)")
                return Self.song(id)
            },
            albumSongs: { id in
                await calls.record("album:\(id)")
                return [Self.song("\(id)-track")]
            },
            artistAlbums: { id in
                await calls.record("artist:\(id)")
                return []
            },
            playlistSongs: { id in
                await calls.record("playlist:\(id)")
                return [Self.song("\(id)-entry")]
            }
        )

        let songResult = try await PlaybackContentResolver.songs(
            for: .song,
            contentID: "song-id",
            provider: provider
        )
        let albumResult = try await PlaybackContentResolver.songs(
            for: .album,
            contentID: "album-id",
            provider: provider
        )
        let playlistResult = try await PlaybackContentResolver.songs(
            for: .playlist,
            contentID: "playlist-id",
            provider: provider
        )

        XCTAssertEqual(songResult.map(\.id), ["song-id"])
        XCTAssertEqual(albumResult.map(\.id), ["album-id-track"])
        XCTAssertEqual(playlistResult.map(\.id), ["playlist-id-entry"])
        let recordedCalls = await calls.values()
        XCTAssertEqual(
            recordedCalls,
            ["song:song-id", "album:album-id", "playlist:playlist-id"]
        )
    }

    func testArtistLoadsAllAlbumTracksInArtistAlbumOrder() async throws {
        let provider = PlaybackContentProvider(
            song: { Self.song($0) },
            albumSongs: { id in
                if id == "first" {
                    try await Task.sleep(for: .milliseconds(30))
                }
                return [Self.song("\(id)-1"), Self.song("\(id)-2")]
            },
            artistAlbums: { _ in
                [Self.album("first"), Self.album("second")]
            },
            playlistSongs: { _ in [] }
        )

        let songs = try await PlaybackContentResolver.songs(
            for: .artist,
            contentID: "artist-id",
            provider: provider
        )

        XCTAssertEqual(
            songs.map(\.id),
            ["first-1", "first-2", "second-1", "second-2"]
        )
    }

    func testArtistSkipsOneUnavailableAlbumInsteadOfChangingToTopSongs() async throws {
        let calls = CallRecorder()
        let provider = PlaybackContentProvider(
            song: { Self.song($0) },
            albumSongs: { id in
                await calls.record("album:\(id)")
                if id == "unavailable" { throw FixtureError.unavailable }
                return [Self.song("\(id)-track")]
            },
            artistAlbums: { id in
                await calls.record("artist:\(id)")
                return [
                    Self.album("available-a"),
                    Self.album("unavailable"),
                    Self.album("available-b"),
                ]
            },
            playlistSongs: { _ in [] }
        )

        let songs = try await PlaybackContentResolver.songs(
            for: .artist,
            contentID: "artist-id",
            provider: provider
        )

        XCTAssertEqual(songs.map(\.id), ["available-a-track", "available-b-track"])
        let recordedCalls = await calls.values()
        XCTAssertEqual(
            Set(recordedCalls),
            Set([
                "artist:artist-id",
                "album:available-a",
                "album:unavailable",
                "album:available-b",
            ])
        )
    }

    func testRadioIsNotResolvedAsACollection() async {
        let provider = PlaybackContentProvider(
            song: { Self.song($0) },
            albumSongs: { _ in [] },
            artistAlbums: { _ in [] },
            playlistSongs: { _ in [] }
        )

        do {
            _ = try await PlaybackContentResolver.songs(
                for: .radio,
                contentID: "radio-id",
                provider: provider
            )
            XCTFail("Expected radio to use the dedicated radio playback path")
        } catch {
            XCTAssertEqual(
                error as? PlaybackContentResolver.ResolutionError,
                .unsupportedKind(.radio)
            )
        }
    }

    func testDownloadedModesMatchOfflineButtons() {
        let alpha = downloadedSong(
            id: "alpha",
            artist: "A Alpha",
            album: "Second",
            track: 2,
            addedAt: 10
        )
        let beta = downloadedSong(
            id: "beta",
            artist: "The Beta",
            album: "First",
            track: 1,
            addedAt: 30
        )
        let alphaFirst = downloadedSong(
            id: "alpha-first",
            artist: "A Alpha",
            album: "First",
            track: 1,
            addedAt: 20
        )
        let downloads = [beta, alpha, alphaFirst]

        let all = DownloadedPlaybackQueueBuilder.selection(from: downloads, mode: .all)
        let shuffled = DownloadedPlaybackQueueBuilder.selection(
            from: downloads,
            mode: .shuffled,
            shuffle: { Array($0.reversed()) }
        )
        let newest = DownloadedPlaybackQueueBuilder.selection(from: downloads, mode: .newest)

        XCTAssertEqual(all.order, .inOrder)
        XCTAssertEqual(all.songs.map(\.id), ["alpha-first", "alpha", "beta"])
        XCTAssertEqual(shuffled.order, .shuffled)
        XCTAssertEqual(shuffled.songs.map(\.id), ["alpha-first", "alpha", "beta"])
        XCTAssertEqual(newest.order, .shuffled)
        XCTAssertEqual(newest.songs.map(\.id), ["beta", "alpha-first", "alpha"])
    }

    nonisolated private static func song(_ id: String) -> Song {
        Song(id: id, title: id)
    }

    nonisolated private static func album(_ id: String) -> Album {
        Album(id: id, name: id)
    }

    private func sortedAlbumIDs(
        _ albums: [Album],
        sort: String,
        direction: String
    ) -> [String] {
        ArtistAlbumPlaybackOrder.sorted(
            albums,
            preference: ArtistAlbumSortPreference(
                sortRaw: sort,
                directionRaw: direction
            )
        ).map(\.id)
    }

    private func downloadedSong(
        id: String,
        artist: String,
        album: String,
        track: Int,
        addedAt: TimeInterval
    ) -> DownloadedSong {
        DownloadedSong(
            songId: id,
            serverId: "server",
            albumId: album,
            artistId: artist,
            title: id,
            albumTitle: album,
            artistName: artist,
            albumArtistName: nil,
            albumCoverArtId: nil,
            track: track,
            disc: 1,
            duration: 180,
            year: nil,
            genre: nil,
            playCount: nil,
            explicitStatus: nil,
            bytes: 1,
            coverArtId: nil,
            artistCoverArtId: nil,
            isFavorite: false,
            filePath: "/tmp/\(id)",
            fileExtension: "mp3",
            contentType: "audio/mpeg",
            bitRate: 320,
            bitDepth: nil,
            samplingRate: nil,
            channelCount: nil,
            bpm: nil,
            replayGainTrackGain: nil,
            replayGainAlbumGain: nil,
            addedAt: Date(timeIntervalSince1970: addedAt)
        )
    }
}

private actor CallRecorder {
    private var recorded: [String] = []

    func record(_ value: String) {
        recorded.append(value)
    }

    func values() -> [String] {
        recorded
    }
}
