import XCTest

final class PathSafeTests: XCTestCase {
    func testLeavesNormalServerIdsUnchanged() {
        XCTAssertEqual("album-123_ABC".pathSafeComponent, "album-123_ABC")
    }

    func testReplacesPathSeparatorsAndReservedCharacters() {
        XCTAssertEqual("artist/../album\\track:01\0flac".pathSafeComponent, "artist_.._album_track_01_flac")
    }

    func testRemovesLeadingDotsAndFallsBackForEmptyNames() {
        XCTAssertEqual("...hidden".pathSafeComponent, "hidden")
        XCTAssertEqual("..".pathSafeComponent, "_")
        XCTAssertEqual("".pathSafeComponent, "_")
    }

    func testFileNameCandidatesOnlyStripKnownFinalExtensions() {
        let knownExtensions: Set<String> = ["flac", "mp3"]

        XCTAssertEqual(
            "song.v1.flac".pathSafeComponentFileNameCandidates(knownFileExtensions: knownExtensions),
            ["song.v1.flac", "song.v1"]
        )
        XCTAssertEqual(
            "song.v1".pathSafeComponentFileNameCandidates(knownFileExtensions: knownExtensions),
            ["song.v1"]
        )
        XCTAssertEqual(
            "song.custom".pathSafeComponentFileNameCandidates(knownFileExtensions: knownExtensions),
            ["song.custom"]
        )
    }

    func testFileExtensionsAreSafePathComponents() {
        XCTAssertEqual("flac".pathSafeFileExtension(), "flac")
        XCTAssertEqual(".mp3".pathSafeFileExtension(), "mp3")
        XCTAssertEqual("audio/mpeg".pathSafeFileExtension(), "audio_mpeg")
        XCTAssertEqual("../aac".pathSafeFileExtension(), "_aac")
    }

    func testEmptyFileExtensionsFallBackToMP3() {
        XCTAssertEqual("".pathSafeFileExtension(), "mp3")
        XCTAssertEqual("...".pathSafeFileExtension(), "mp3")
    }

    func testDownloadFileNameCandidatesPreserveLegacyStoredName() {
        let candidates = "artist/song:01".pathSafeDownloadFileNameCandidates(
            fileExtension: "flac",
            storedFilePath: "/old/container/server/artist-song-01.flac"
        )

        XCTAssertEqual(candidates, [
            "artist_song_01.flac",
            "artist-song-01.flac"
        ])
    }

    func testDownloadFileNameCandidatesSkipDuplicateOrUnsafeStoredName() {
        XCTAssertEqual(
            "song-1".pathSafeDownloadFileNameCandidates(
                fileExtension: "mp3",
                storedFilePath: "/old/container/song-1.mp3"
            ),
            ["song-1.mp3"]
        )

        XCTAssertEqual(
            "song-1".pathSafeDownloadFileNameCandidates(
                fileExtension: "mp3",
                storedFilePath: "/old/container/.."
            ),
            ["song-1.mp3"]
        )
    }
}
