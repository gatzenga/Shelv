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

    func testEmptyRefreshPreservesLastValidTrackAndArtwork() {
        let current = RadioNowPlayingMetadata(
            stationName: "Station",
            title: "Current Song",
            artist: "Current Artist",
            artworkURL: "https://radio.example.com/current.jpg"
        )
        let emptyRefresh = RadioNowPlayingMetadata(
            stationName: "Renamed Station",
            artworkURL: "https://radio.example.com/station.jpg",
            isLive: true
        )

        let resolved = RadioNowPlayingMetadata.resolving(current: current, incoming: emptyRefresh)

        XCTAssertEqual(resolved.stationName, "Renamed Station")
        XCTAssertEqual(resolved.title, "Current Song")
        XCTAssertEqual(resolved.artist, "Current Artist")
        XCTAssertEqual(resolved.artworkURL, "https://radio.example.com/current.jpg")
        XCTAssertTrue(resolved.isLive)
    }

    func testValidRefreshReplacesPreviousTrackAsOnePackage() {
        let current = RadioNowPlayingMetadata(
            title: "Old Song",
            artist: "Old Artist",
            artworkURL: "https://radio.example.com/old.jpg"
        )
        let incoming = RadioNowPlayingMetadata(
            title: "New Song",
            artist: "New Artist",
            artworkURL: "https://radio.example.com/new.jpg"
        )

        XCTAssertEqual(
            RadioNowPlayingMetadata.resolving(current: current, incoming: incoming),
            incoming
        )
    }

    func testEmptyRefreshIsUsedWhenNoValidTrackExistsYet() {
        let current = RadioNowPlayingMetadata(
            stationName: "Station",
            artworkURL: "https://radio.example.com/old-station.jpg"
        )
        let incoming = RadioNowPlayingMetadata(
            stationName: "Station",
            artworkURL: "https://radio.example.com/current-station.jpg"
        )

        XCTAssertEqual(
            RadioNowPlayingMetadata.resolving(current: current, incoming: incoming),
            incoming
        )
    }

    func testAzuraCastUsesFixedThreeSecondPollingInterval() {
        XCTAssertEqual(RadioMetadataPollingPolicy.azuraCastInterval, .seconds(3))
    }
}
