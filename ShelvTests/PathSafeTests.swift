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
}
