import XCTest

final class SubsonicServerTests: XCTestCase {
    func testSecondaryURLIsNormalizedAndCodable() throws {
        var server = SubsonicServer(
            name: "Home",
            baseURL: " music.example.com ",
            username: "vasco",
            secondaryBaseURL: " music-lan.example.com ",
            activeURLSlot: .secondary
        )

        XCTAssertEqual(server.baseURL, "https://music.example.com")
        XCTAssertEqual(server.secondaryURL, "https://music-lan.example.com")
        XCTAssertTrue(server.isUsingSecondaryURL)
        XCTAssertEqual(server.activeBaseURL, "https://music-lan.example.com")

        let data = try JSONEncoder().encode(server)
        server = try JSONDecoder().decode(SubsonicServer.self, from: data)

        XCTAssertEqual(server.baseURL, "https://music.example.com")
        XCTAssertEqual(server.secondaryURL, "https://music-lan.example.com")
        XCTAssertTrue(server.isUsingSecondaryURL)
    }

    func testRemovingSecondaryURLFallsBackToPrimarySlot() {
        var server = SubsonicServer(
            name: "Home",
            baseURL: "https://music.example.com",
            username: "vasco",
            secondaryBaseURL: "https://music-lan.example.com",
            activeURLSlot: .secondary
        )

        server.secondaryBaseURL = ""
        server.sanitizeURLSlots()

        XCTAssertNil(server.secondaryURL)
        XCTAssertFalse(server.isUsingSecondaryURL)
        XCTAssertEqual(server.activeBaseURL, "https://music.example.com")
    }

    func testDerivedStableIdNormalizesEquivalentServerURLs() {
        let first = SubsonicServer(
            baseURL: "HTTPS://Music.Example.com:443/api/subsonic/",
            username: "vasco"
        )
        let second = SubsonicServer(
            baseURL: "https://music.example.com/api/subsonic",
            username: "vasco"
        )

        XCTAssertEqual(first.derivedStableId, second.derivedStableId)
        XCTAssertTrue(first.derivedStableId.hasPrefix("subsonic-"))
    }

    func testDerivedStableIdIsIndependentOfSecondaryURLAndActiveSlot() {
        let primary = SubsonicServer(
            baseURL: "https://music.example.com",
            username: "vasco"
        )
        let secondary = SubsonicServer(
            baseURL: "https://music.example.com",
            username: "vasco",
            secondaryBaseURL: "https://music.internal",
            activeURLSlot: .secondary
        )

        XCTAssertEqual(primary.derivedStableId, secondary.derivedStableId)
    }

    func testDerivedStableIdSeparatesAccountsAndServerPaths() {
        let base = SubsonicServer(
            baseURL: "https://music.example.com/api/subsonic",
            username: "vasco"
        )
        let otherUser = SubsonicServer(
            baseURL: "https://music.example.com/api/subsonic",
            username: "other"
        )
        let otherServer = SubsonicServer(
            baseURL: "https://music.example.com/other/subsonic",
            username: "vasco"
        )

        XCTAssertNotEqual(base.derivedStableId, otherUser.derivedStableId)
        XCTAssertNotEqual(base.derivedStableId, otherServer.derivedStableId)
    }
}
