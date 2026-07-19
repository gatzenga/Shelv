import Foundation
import XCTest

final class SubsonicResponseCompatibilityTests: XCTestCase {
    func testDecodesStandardAlbumAndArtistXMLWithoutChangingStringIDs() throws {
        let xml = Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <subsonic-response xmlns="http://subsonic.org/restapi" status="ok" version="1.16.1">
          <albumList2>
            <album id="000123" name="One &amp; Two" artist="Artist One" artistId="artist-1"
                   songCount="2" duration="421" playCount="12" year="2024"
                   created="2024-01-02T03:04:05.678Z"/>
            <album id="album-2" name="Second" songCount="1" duration="180"
                   created="2024-02-03T04:05:06Z"/>
          </albumList2>
          <artists>
            <index name="A">
              <artist id="000007" name="Artist One" albumCount="2"/>
              <artist id="artist-2" name="Artist Two" albumCount="1"/>
            </index>
          </artists>
        </subsonic-response>
        """#.utf8)

        let response = try SubsonicXMLDecoder().decode(
            TestEnvelope<LibraryBody>.self,
            from: xml
        ).response

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.albumList2?.album?.map(\.id), ["000123", "album-2"])
        XCTAssertEqual(response.albumList2?.album?.first?.name, "One & Two")
        XCTAssertEqual(response.albumList2?.album?.first?.songCount, 2)
        XCTAssertEqual(response.albumList2?.album?.first?.playCount, 12)
        XCTAssertNotNil(response.albumList2?.album?.first?.created)
        XCTAssertEqual(
            response.artists?.index?.flatMap { $0.artist ?? [] }.map(\.id),
            ["000007", "artist-2"]
        )
    }

    func testDecodesStandardSongXMLIncludingOpenSubsonicFields() throws {
        let xml = Data(#"""
        <subsonic-response status="ok" version="1.16.1" type="navidrome" openSubsonic="true">
          <song id="000042" title="Example Song" artist="Legacy Artist" artistId="artist-1"
                album="Example Album" albumId="album-1" track="3" discNumber="1"
                duration="245" size="123456789" bitRate="1000" bitDepth="24"
                samplingRate="48000" channelCount="2" bpm="122"
                starred="2024-03-04T05:06:07Z" displayArtist="Artist One feat. Artist Two"
                displayAlbumArtist="Album Artist" displayComposer="Composer One"
                explicitStatus="clean">
            <isrc>USSM18300073</isrc>
            <genres name="Electronic"/>
            <artists id="artist-1" name="Artist One"/>
            <artists id="artist-2" name="Artist Two"/>
            <albumArtists id="artist-3" name="Album Artist"/>
            <contributors role="composer">
              <artist id="artist-4" name="Composer One"/>
            </contributors>
            <moods>focused</moods>
            <works name="Example Work" musicBrainzId="work-1"/>
            <movements name="Opening" number="1" count="3"/>
            <groupings>Live</groupings>
            <replayGain trackGain="-7.5" albumGain="-6.25" trackPeak="0.98"/>
          </song>
        </subsonic-response>
        """#.utf8)

        let song = try XCTUnwrap(
            SubsonicXMLDecoder().decode(
                TestEnvelope<SongBody>.self,
                from: xml
            ).response.song
        )

        XCTAssertEqual(song.id, "000042")
        XCTAssertEqual(song.fileSize, 123_456_789)
        XCTAssertEqual(song.artists?.map(\.name), ["Artist One", "Artist Two"])
        XCTAssertEqual(song.albumArtists?.map(\.name), ["Album Artist"])
        XCTAssertEqual(song.contributors?.first?.artist.name, "Composer One")
        XCTAssertEqual(song.genres?.map(\.name), ["Electronic"])
        XCTAssertEqual(song.isrc, ["USSM18300073"])
        XCTAssertEqual(song.moods, ["focused"])
        XCTAssertEqual(song.works?.first?.musicBrainzId, "work-1")
        XCTAssertEqual(song.movements?.first?.number, 1)
        XCTAssertEqual(song.groupings, ["Live"])
        XCTAssertEqual(song.replayGain?.trackGain, -7.5)
        XCTAssertNotNil(song.starred)
    }

    func testDecodesPlaylistRadioQueueLyricsAndOptionalScanCountXML() throws {
        let xml = Data(#"""
        <subsonic-response status="ok" version="1.16.1">
          <playlists>
            <playlist id="playlist-1" name="Favorites" songCount="1" duration="245"
                      created="2024-01-01T00:00:00Z" changed="2024-01-02T00:00:00Z"/>
          </playlists>
          <playQueue current="song-1" position="1200" changed="2024-01-02T00:00:00Z">
            <entry id="song-1" title="Queued Song" duration="200"/>
          </playQueue>
          <internetRadioStations>
            <internetRadioStation id="radio-1" name="Radio One"
                                  streamUrl="https://example.com/live" homePageUrl="https://example.com"/>
          </internetRadioStations>
          <lyricsList>
            <structuredLyrics synced="true" lang="en">
              <line start="1200">Hello &amp; goodbye</line>
              <line start="2400"><![CDATA[Second <line>]]></line>
            </structuredLyrics>
          </lyricsList>
          <scanStatus scanning="false"/>
        </subsonic-response>
        """#.utf8)

        let body = try SubsonicXMLDecoder().decode(
            TestEnvelope<MixedBody>.self,
            from: xml
        ).response

        XCTAssertEqual(body.playlists?.playlist?.first?.id, "playlist-1")
        XCTAssertEqual(body.playQueue?.entry?.first?.title, "Queued Song")
        XCTAssertEqual(body.internetRadioStations?.internetRadioStation?.first?.streamURL, "https://example.com/live")
        XCTAssertEqual(body.lyricsList?.structuredLyrics?.first?.line?.map(\.value), ["Hello & goodbye", "Second <line>"])
        XCTAssertEqual(body.lyricsList?.structuredLyrics?.first?.line?.first?.start, 1_200)
        XCTAssertEqual(body.scanStatus?.scanning, false)
        XCTAssertNil(body.scanStatus?.count)
    }

    func testXMLAPIErrorParticipatesInVersionCompatibilityFallback() throws {
        let response = Data(#"""
        <subsonic-response status="failed" version="1.15.0">
          <error code="30" message="Client version is too new"/>
        </subsonic-response>
        """#.utf8)

        let retry = try XCTUnwrap(
            SubsonicRequestCompatibility.current.retrying(
                afterHTTPStatus: 200,
                responseData: response,
                responseFormat: .xml
            )
        )

        XCTAssertEqual(retry.apiVersion, "1.15.0")
        XCTAssertEqual(retry.endpointPath(for: "getAlbum"), "getAlbum")
    }

    func testNegotiatorFallsBackOnlyAfterDecodingFailure() async throws {
        let recorder = FormatRecorder()
        let result: SubsonicResponseNegotiationResult<String> = try await SubsonicResponseNegotiator.load(
            primaryFormat: .json,
            fallbackFormat: .xml,
            fetch: { format in
                await recorder.append(format)
                return Data(format.rawValue.utf8)
            },
            decode: { data, format in
                if format == .json { throw TestFailure.invalidRepresentation }
                return String(decoding: data, as: UTF8.self)
            }
        )

        XCTAssertEqual(result.value, "xml")
        XCTAssertEqual(result.format, .xml)
        XCTAssertTrue(result.usedFallback)
        let recordedFormats = await recorder.values
        XCTAssertEqual(recordedFormats, [.json, .xml])
    }

    func testNegotiatorNeverFallsBackAfterTransportFailure() async {
        let recorder = FormatRecorder()
        do {
            let _: SubsonicResponseNegotiationResult<String> = try await SubsonicResponseNegotiator.load(
                primaryFormat: .json,
                fallbackFormat: .xml,
                fetch: { format in
                    await recorder.append(format)
                    throw TestFailure.transport
                },
                decode: { _, _ in "unused" }
            )
            XCTFail("Expected transport failure")
        } catch TestFailure.transport {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recordedFormats = await recorder.values
        XCTAssertEqual(recordedFormats, [.json])
    }

    func testIdenticalFallbackRequestsAreCoalesced() async throws {
        let gate = SubsonicResponseRequestGate()
        let counter = AsyncCounter()

        async let first = gate.data(for: "server|getAlbumList2|xml") {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return Data("xml".utf8)
        }
        async let second = gate.data(for: "server|getAlbumList2|xml") {
            await counter.increment()
            return Data("other".utf8)
        }

        let values = try await [first, second]
        XCTAssertEqual(values, [Data("xml".utf8), Data("xml".utf8)])
        let requestCount = await counter.value
        XCTAssertEqual(requestCount, 1)
    }

    func testFormatPreferenceIsPersistentAndEndpointScoped() throws {
        try withPreferenceStore { defaults, key in
            let now = Date(timeIntervalSince1970: 10_000)
            var store = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|100",
                jsonReprobeInterval: 100
            )
            store.recordXMLSuccess(
                serverKey: "server-a",
                endpoint: "getAlbumList2",
                now: now
            )

            XCTAssertEqual(
                store.selection(serverKey: "server-a", endpoint: "getAlbumList2", now: now),
                .xml(shouldReprobeJSON: false)
            )
            XCTAssertEqual(
                store.selection(serverKey: "server-a", endpoint: "getArtists", now: now),
                .json(allowsXMLFallback: true)
            )

            store = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|100",
                jsonReprobeInterval: 100
            )
            XCTAssertEqual(
                store.selection(serverKey: "server-a", endpoint: "getAlbumList2", now: now),
                .xml(shouldReprobeJSON: false)
            )
        }
    }

    func testFailedXMLFallbackIsNotRepeatedForThatEndpoint() throws {
        try withPreferenceStore { defaults, key in
            var store = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|100"
            )
            store.recordXMLFailure(serverKey: "server-a", endpoint: "getAlbumList2")

            store = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|100"
            )

            XCTAssertEqual(
                store.selection(serverKey: "server-a", endpoint: "getAlbumList2"),
                .json(allowsXMLFallback: false)
            )
            XCTAssertEqual(
                store.selection(serverKey: "server-a", endpoint: "getAlbum"),
                .json(allowsXMLFallback: true)
            )
        }
    }

    func testPeriodicJSONReprobeRunsOnceAndRestoresJSON() throws {
        try withPreferenceStore { defaults, key in
            let start = Date(timeIntervalSince1970: 20_000)
            let store = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|100",
                jsonReprobeInterval: 100
            )
            store.recordXMLSuccess(
                serverKey: "server-a",
                endpoint: "getAlbumList2",
                now: start
            )

            XCTAssertFalse(
                store.claimJSONReprobe(
                    serverKey: "server-a",
                    endpoint: "getAlbumList2",
                    now: start.addingTimeInterval(99)
                )
            )
            XCTAssertTrue(
                store.claimJSONReprobe(
                    serverKey: "server-a",
                    endpoint: "getAlbumList2",
                    now: start.addingTimeInterval(100)
                )
            )
            XCTAssertFalse(
                store.claimJSONReprobe(
                    serverKey: "server-a",
                    endpoint: "getAlbumList2",
                    now: start.addingTimeInterval(100)
                )
            )

            store.finishJSONReprobe(
                serverKey: "server-a",
                endpoint: "getAlbumList2",
                decodedSuccessfully: true,
                receivedResponse: true,
                now: start.addingTimeInterval(100)
            )
            XCTAssertEqual(
                store.selection(
                    serverKey: "server-a",
                    endpoint: "getAlbumList2",
                    now: start.addingTimeInterval(100)
                ),
                .json(allowsXMLFallback: true)
            )
        }
    }

    func testFailedPeriodicJSONReprobeKeepsXMLAndDefersAnotherAttempt() throws {
        try withPreferenceStore { defaults, key in
            let start = Date(timeIntervalSince1970: 30_000)
            let store = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|100",
                jsonReprobeInterval: 100
            )
            store.recordXMLSuccess(
                serverKey: "server-a",
                endpoint: "getAlbumList2",
                now: start
            )

            let firstCheck = start.addingTimeInterval(100)
            XCTAssertTrue(
                store.claimJSONReprobe(
                    serverKey: "server-a",
                    endpoint: "getAlbumList2",
                    now: firstCheck
                )
            )
            store.finishJSONReprobe(
                serverKey: "server-a",
                endpoint: "getAlbumList2",
                decodedSuccessfully: false,
                receivedResponse: true,
                now: firstCheck
            )

            XCTAssertEqual(
                store.selection(
                    serverKey: "server-a",
                    endpoint: "getAlbumList2",
                    now: firstCheck.addingTimeInterval(99)
                ),
                .xml(shouldReprobeJSON: false)
            )
            XCTAssertEqual(
                store.selection(
                    serverKey: "server-a",
                    endpoint: "getAlbumList2",
                    now: firstCheck.addingTimeInterval(100)
                ),
                .xml(shouldReprobeJSON: true)
            )
        }
    }

    func testAppOrAdvertisedServerVersionChangeInvalidatesPreference() throws {
        try withPreferenceStore { defaults, key in
            let first = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|100"
            )
            first.noteServerFingerprint("1.16.1|bandcamp|beta-1", serverKey: "server-a")
            first.recordXMLSuccess(serverKey: "server-a", endpoint: "getAlbumList2")
            first.noteServerFingerprint("1.16.1|bandcamp|beta-2", serverKey: "server-a")
            XCTAssertEqual(
                first.selection(serverKey: "server-a", endpoint: "getAlbumList2"),
                .json(allowsXMLFallback: true)
            )

            first.recordXMLSuccess(serverKey: "server-a", endpoint: "getAlbumList2")
            let updatedApp = SubsonicResponseFormatPreferences(
                defaults: defaults,
                storageKey: key,
                clientVersion: "1|101"
            )
            XCTAssertEqual(
                updatedApp.selection(serverKey: "server-a", endpoint: "getAlbumList2"),
                .json(allowsXMLFallback: true)
            )
        }
    }

    private func withPreferenceStore(
        _ body: (UserDefaults, String) throws -> Void
    ) throws {
        let suite = "SubsonicResponseCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, "preferences")
    }
}

private struct TestEnvelope<Body: Decodable>: Decodable {
    let response: Body

    enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

private struct LibraryBody: Decodable {
    let status: String
    let albumList2: TestAlbumListContainer?
    let artists: TestArtistsContainer?
}

private struct TestAlbumListContainer: Decodable {
    let album: [Album]?
}

private struct TestArtistsContainer: Decodable {
    let index: [TestArtistIndex]?
}

private struct TestArtistIndex: Decodable {
    let name: String
    let artist: [Artist]?
}

private struct SongBody: Decodable {
    let song: Song?
}

private struct MixedBody: Decodable {
    let playlists: PlaylistContainer?
    let playQueue: QueueContainer?
    let internetRadioStations: RadioContainer?
    let lyricsList: TestLyricsList?
    let scanStatus: TestScanStatus?
}

private struct PlaylistContainer: Decodable {
    let playlist: [TestPlaylist]?
}

private struct TestPlaylist: Decodable {
    let id: String
}

private struct QueueContainer: Decodable {
    let entry: [Song]?
    let current: String?
    let position: Int?
    let changed: String?
}

private struct RadioContainer: Decodable {
    let internetRadioStation: [RadioStation]?
}

private struct TestLyricsList: Decodable {
    let structuredLyrics: [TestStructuredLyrics]?
}

private struct TestStructuredLyrics: Decodable {
    let synced: Bool
    let lang: String?
    let line: [Line]?

    struct Line: Decodable {
        let start: Int?
        let value: String
    }
}

private struct TestScanStatus: Decodable {
    let scanning: Bool
    let count: Int?
}

private enum TestFailure: Error {
    case invalidRepresentation
    case transport
}

private actor FormatRecorder {
    private(set) var values: [SubsonicResponseFormat] = []

    func append(_ value: SubsonicResponseFormat) {
        values.append(value)
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
