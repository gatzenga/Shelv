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
}
