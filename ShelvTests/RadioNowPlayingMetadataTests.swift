import XCTest

final class RadioNowPlayingMetadataTests: XCTestCase {
    func testArtworkRevisionChangesWhenTrackChangesButURLStaysTheSame() throws {
        let first = RadioNowPlayingMetadata(
            stationName: "Station",
            title: "First Song",
            artist: "Artist",
            artworkURL: "https://radio.example.com/api/station/main/art"
        )
        let second = RadioNowPlayingMetadata(
            stationName: "Station",
            title: "Second Song",
            artist: "Artist",
            artworkURL: "https://radio.example.com/api/station/main/art"
        )

        let firstURL = try XCTUnwrap(first.cacheBustedArtworkURL)
        let secondURL = try XCTUnwrap(second.cacheBustedArtworkURL)

        XCTAssertEqual(firstURL.scheme, "https")
        XCTAssertEqual(firstURL.host, "radio.example.com")
        XCTAssertEqual(firstURL.path, "/api/station/main/art")
        XCTAssertNotEqual(firstURL.absoluteString, secondURL.absoluteString)
        XCTAssertNotEqual(
            firstURL.queryParam(RadioNowPlayingMetadata.artworkRevisionQueryItemName),
            secondURL.queryParam(RadioNowPlayingMetadata.artworkRevisionQueryItemName)
        )
    }

    func testArtworkRevisionPreservesExistingQueryItems() throws {
        let metadata = RadioNowPlayingMetadata(
            title: "Song",
            artist: "Artist",
            artworkURL: "https://radio.example.com/art?id=current"
        )

        let url = try XCTUnwrap(metadata.cacheBustedArtworkURL)

        XCTAssertEqual(url.queryParam("id"), "current")
        XCTAssertNotNil(url.queryParam(RadioNowPlayingMetadata.artworkRevisionQueryItemName))
    }

    func testDisplayTitleHidesPlaceholderValues() {
        XCTAssertNil(RadioNowPlayingMetadata(title: "Unknown Title").displayTitle)
        XCTAssertNil(RadioNowPlayingMetadata(title: "Titel unbekannt").displayTitle)
        XCTAssertEqual(RadioNowPlayingMetadata(title: "Actual Song").displayTitle, "Actual Song")
    }

    func testDisplayArtistHidesPlaceholderValues() {
        XCTAssertNil(RadioNowPlayingMetadata(artist: "Unknown Artist").displayArtist)
        XCTAssertNil(RadioNowPlayingMetadata(artist: "Künstler unbekannt").displayArtist)
        XCTAssertEqual(RadioNowPlayingMetadata(artist: "Actual Artist").displayArtist, "Actual Artist")
    }
}
