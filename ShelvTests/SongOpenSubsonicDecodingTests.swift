import XCTest

final class SongOpenSubsonicDecodingTests: XCTestCase {
    func testDecodesOpenSubsonicCreditsAndDetails() throws {
        let json = """
        {
          "id": "song-1",
          "title": "Example Song",
          "artist": "Legacy Artist",
          "displayArtist": "Artist One feat. Artist Two",
          "artists": [
            { "id": "artist-1", "name": "Artist One" },
            { "id": "artist-2", "name": "Artist Two" }
          ],
          "albumArtists": [
            { "id": "artist-3", "name": "Album Artist" }
          ],
          "displayAlbumArtist": "Album Artist",
          "contributors": [
            {
              "role": "composer",
              "artist": { "id": "artist-4", "name": "Composer One" }
            },
            {
              "role": "performer",
              "subRole": "Bass",
              "artist": { "id": "artist-5", "name": "Performer One" }
            }
          ],
          "displayComposer": "Composer One",
          "isrc": ["USSM18300073"],
          "genres": [{ "name": "Electronic" }],
          "moods": ["focused"],
          "explicitStatus": "clean",
          "size": 12345678,
          "bitDepth": 24,
          "samplingRate": 48000,
          "channelCount": 2,
          "bpm": 122,
          "musicBrainzId": "189002e7-3285-4e2e-92a3-7f6c30d407a2",
          "works": [{ "name": "Example Work", "musicBrainzId": "work-1" }],
          "movements": [{ "name": "Opening", "number": 1, "count": 3 }],
          "groupings": ["Live"]
        }
        """

        let song = try JSONDecoder().decode(Song.self, from: try XCTUnwrap(json.data(using: .utf8)))

        XCTAssertEqual(song.displayArtist, "Artist One feat. Artist Two")
        XCTAssertEqual(song.artists?.map(\.name), ["Artist One", "Artist Two"])
        XCTAssertEqual(song.albumArtists?.map(\.name), ["Album Artist"])
        XCTAssertEqual(song.contributors?.map(\.role), ["composer", "performer"])
        XCTAssertEqual(song.contributors?.last?.subRole, "Bass")
        XCTAssertEqual(song.isrc, ["USSM18300073"])
        XCTAssertEqual(song.genres?.map(\.name), ["Electronic"])
        XCTAssertEqual(song.explicitStatus, "clean")
        XCTAssertEqual(song.fileSize, 12_345_678)
        XCTAssertEqual(song.bitDepth, 24)
        XCTAssertEqual(song.samplingRate, 48000)
        XCTAssertEqual(song.channelCount, 2)
        XCTAssertEqual(song.works?.first?.name, "Example Work")
        XCTAssertEqual(song.movements?.first?.number, 1)
        XCTAssertEqual(song.groupings, ["Live"])
    }
}
