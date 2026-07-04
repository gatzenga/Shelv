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
}
