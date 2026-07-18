import Combine
import XCTest

@MainActor
final class DownloadUIStateHubTests: XCTestCase {
    func testTargetedPublishersIgnoreUnrelatedSnapshotChanges() {
        let hub = DownloadUIStateHub()
        var cancellables = Set<AnyCancellable>()
        var songAvailability: [Bool] = []
        var albumAvailability: [Bool] = []
        var artistAvailability: [Bool] = []
        var downloadedSubset: [Set<String>] = []

        hub.songAvailabilityPublisher(songID: "target-song")
            .sink { songAvailability.append($0) }
            .store(in: &cancellables)
        hub.albumAvailabilityPublisher(albumID: "target-album")
            .sink { albumAvailability.append($0) }
            .store(in: &cancellables)
        hub.artistAvailabilityPublisher(name: "Target Artist")
            .sink { artistAvailability.append($0) }
            .store(in: &cancellables)
        hub.downloadedSongSubsetPublisher(songIDs: ["target-song", "second-target-song"])
            .sink { downloadedSubset.append($0) }
            .store(in: &cancellables)

        hub.commit(DownloadUIStateSnapshot(
            songIDs: ["unrelated-song"],
            albumDownloadedCounts: ["unrelated-album": 1],
            artistNames: ["Unrelated Artist"],
            artistBadgeNames: ["Unrelated Artist"],
            totalBytes: 100
        ))

        XCTAssertEqual(songAvailability, [false])
        XCTAssertEqual(albumAvailability, [false])
        XCTAssertEqual(artistAvailability, [false])
        XCTAssertEqual(downloadedSubset, [[]])

        hub.commit(DownloadUIStateSnapshot(
            songIDs: ["unrelated-song", "target-song"],
            albumDownloadedCounts: ["unrelated-album": 1, "target-album": 1],
            artistNames: ["Unrelated Artist", "Target Artist"],
            artistBadgeNames: ["Unrelated Artist", "Target Artist"],
            totalBytes: 200
        ))

        XCTAssertEqual(songAvailability, [false, true])
        XCTAssertEqual(albumAvailability, [false, true])
        XCTAssertEqual(artistAvailability, [false, true])
        XCTAssertEqual(downloadedSubset, [[], ["target-song"]])
    }

    func testCompletedRecordIsVisibleOptimisticallyAndDuplicateCompletionIsIdempotent() {
        let hub = DownloadUIStateHub()
        var cancellables = Set<AnyCancellable>()
        var snapshotCount = 0
        var songAvailability: [Bool] = []
        var albumCounts: [Int] = []

        hub.snapshots
            .sink { _ in snapshotCount += 1 }
            .store(in: &cancellables)
        hub.songAvailabilityPublisher(songID: "song-1")
            .sink { songAvailability.append($0) }
            .store(in: &cancellables)
        hub.albumDownloadedCountPublisher(albumID: "album-a")
            .sink { albumCounts.append($0) }
            .store(in: &cancellables)

        let first = record(
            songID: "song-1",
            albumID: "album-a",
            artistName: "Lead feat. Guest",
            albumArtistName: "Album Artist",
            bytes: 400
        )
        hub.applyCompletedRecord(first)

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(songAvailability, [false, true])
        XCTAssertEqual(albumCounts, [0, 1])
        XCTAssertEqual(hub.currentSnapshot.songIDs, ["song-1"])
        XCTAssertEqual(hub.currentSnapshot.albumDownloadedCounts["album-a"], 1)
        XCTAssertEqual(hub.currentSnapshot.artistNames, ["Album Artist"])
        XCTAssertTrue(hub.currentSnapshot.artistBadgeNames.isSuperset(
            of: ["Album Artist", "Lead", "Guest"]
        ))
        XCTAssertEqual(hub.currentSnapshot.totalBytes, 400)

        let optimisticSnapshot = hub.currentSnapshot
        hub.commit(.empty)

        XCTAssertEqual(hub.currentSnapshot, optimisticSnapshot)
        XCTAssertEqual(snapshotCount, 2)

        hub.commit(optimisticSnapshot)

        XCTAssertEqual(hub.currentSnapshot, optimisticSnapshot)
        XCTAssertEqual(snapshotCount, 2)

        hub.applyCompletedRecord(first)

        XCTAssertEqual(snapshotCount, 2)
        XCTAssertEqual(songAvailability, [false, true])
        XCTAssertEqual(albumCounts, [0, 1])
        XCTAssertEqual(hub.currentSnapshot.albumDownloadedCounts["album-a"], 1)
        XCTAssertEqual(hub.currentSnapshot.totalBytes, 400)

        hub.applyCompletedRecord(record(
            songID: "song-2",
            albumID: "album-a",
            artistName: "Second Artist",
            albumArtistName: "Album Artist",
            bytes: 600
        ))

        XCTAssertEqual(snapshotCount, 3)
        XCTAssertEqual(albumCounts, [0, 1, 2])
        XCTAssertEqual(hub.currentSnapshot.songIDs, ["song-1", "song-2"])
        XCTAssertEqual(hub.currentSnapshot.albumDownloadedCounts["album-a"], 2)
        XCTAssertEqual(hub.currentSnapshot.totalBytes, 1_000)
    }

    func testPartialCommitRetainsUncommittedOptimisticRecordAndReplaceClearsIt() {
        let hub = DownloadUIStateHub()
        var cancellables = Set<AnyCancellable>()
        var secondSongAvailability: [Bool] = []
        var albumCounts: [Int] = []
        var authoritativeStorage: [DownloadUIStorageState] = []

        hub.songAvailabilityPublisher(songID: "song-2")
            .sink { secondSongAvailability.append($0) }
            .store(in: &cancellables)
        hub.albumDownloadedCountPublisher(albumID: "album-a")
            .sink { albumCounts.append($0) }
            .store(in: &cancellables)
        hub.authoritativeStorageStatePublisher
            .sink { authoritativeStorage.append($0) }
            .store(in: &cancellables)

        let first = record(
            songID: "song-1",
            albumID: "album-a",
            artistName: "Artist",
            albumArtistName: "Album Artist",
            bytes: 400
        )
        let second = record(
            songID: "song-2",
            albumID: "album-a",
            artistName: "Artist",
            albumArtistName: "Album Artist",
            bytes: 600
        )
        hub.applyCompletedRecord(first)
        hub.applyCompletedRecord(second)

        XCTAssertEqual(
            authoritativeStorage,
            [DownloadUIStorageState(totalBytes: 0, songCount: 0)]
        )

        let firstAuthoritative = DownloadUIStateSnapshot(
            songIDs: ["song-1"],
            albumDownloadedCounts: ["album-a": 1],
            artistNames: ["Album Artist"],
            artistBadgeNames: ["Album Artist", "Artist"],
            totalBytes: 400
        )
        hub.commit(firstAuthoritative)

        XCTAssertEqual(hub.currentSnapshot.songIDs, ["song-1", "song-2"])
        XCTAssertEqual(hub.currentSnapshot.albumDownloadedCounts["album-a"], 2)
        XCTAssertEqual(hub.currentSnapshot.totalBytes, 1_000)
        XCTAssertEqual(secondSongAvailability, [false, true])
        XCTAssertEqual(albumCounts, [0, 1, 2])
        XCTAssertEqual(
            authoritativeStorage,
            [
                DownloadUIStorageState(totalBytes: 0, songCount: 0),
                DownloadUIStorageState(totalBytes: 400, songCount: 1),
            ]
        )

        hub.replace(with: firstAuthoritative)

        XCTAssertEqual(hub.currentSnapshot, firstAuthoritative)
        XCTAssertEqual(secondSongAvailability, [false, true, false])
        XCTAssertEqual(albumCounts, [0, 1, 2, 1])
    }

    private func record(
        songID: String,
        albumID: String,
        artistName: String,
        albumArtistName: String?,
        bytes: Int64
    ) -> DownloadRecord {
        DownloadRecord(
            songId: songID,
            serverId: "server-a",
            albumId: albumID,
            artistId: "artist-1",
            title: "Song",
            albumTitle: "Album",
            artistName: artistName,
            track: 1,
            disc: 1,
            duration: 180,
            year: 2026,
            genre: "Rock",
            playCount: 1,
            explicitStatus: nil,
            bytes: bytes,
            coverArtId: "cover-a",
            artistCoverArtId: "artist-cover-a",
            albumArtistName: albumArtistName,
            albumCoverArtId: "album-cover-a",
            isFavorite: false,
            filePath: "/tmp/\(songID).mp3",
            fileExtension: "mp3",
            contentType: "audio/mpeg",
            bitRate: 192,
            bitDepth: nil,
            samplingRate: 44_100,
            channelCount: 2,
            bpm: nil,
            replayGainTrackGain: nil,
            replayGainAlbumGain: nil,
            addedAt: 1_700_000_000
        )
    }
}
