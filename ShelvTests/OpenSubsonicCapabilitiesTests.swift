import XCTest

final class OpenSubsonicCapabilitiesTests: XCTestCase {
    func testAServerThatWasNeverAskedSupportsNothing() {
        XCTAssertFalse(OpenSubsonicCapabilities.none.supports(OpenSubsonicExtension.songLyrics))
        XCTAssertTrue(OpenSubsonicCapabilities.none.isEmpty)
    }

    func testAdvertisedExtensionsAreMatchedByNameAndVersion() {
        let caps = OpenSubsonicCapabilities(advertised: [
            (name: OpenSubsonicExtension.songLyrics, versions: [1, 2]),
            (name: OpenSubsonicExtension.transcodeOffset, versions: [1])
        ])

        XCTAssertTrue(caps.supports(OpenSubsonicExtension.songLyrics))
        XCTAssertTrue(caps.supports(OpenSubsonicExtension.songLyrics, version: 2))
        XCTAssertTrue(caps.supports(OpenSubsonicExtension.transcodeOffset))
        XCTAssertFalse(caps.supports(OpenSubsonicExtension.transcodeOffset, version: 2))
        XCTAssertFalse(caps.supports(OpenSubsonicExtension.sonicSimilarity))
    }

    func testALaterVersionSatisfiesAnEarlierRequirement() {
        // The spec requires later versions to stay backwards compatible, so a
        // server advertising only v2 still answers a v1 request.
        let caps = OpenSubsonicCapabilities(advertised: [
            (name: OpenSubsonicExtension.songLyrics, versions: [2])
        ])

        XCTAssertTrue(caps.supports(OpenSubsonicExtension.songLyrics, version: 1))
        XCTAssertTrue(caps.supports(OpenSubsonicExtension.songLyrics, version: 2))
        XCTAssertFalse(caps.supports(OpenSubsonicExtension.songLyrics, version: 3))
    }

    func testARepeatedNameMergesItsVersionsInsteadOfOverwriting() {
        let caps = OpenSubsonicCapabilities(advertised: [
            (name: OpenSubsonicExtension.songLyrics, versions: [1]),
            (name: OpenSubsonicExtension.songLyrics, versions: [2])
        ])

        XCTAssertTrue(caps.supports(OpenSubsonicExtension.songLyrics, version: 2))
    }
}
