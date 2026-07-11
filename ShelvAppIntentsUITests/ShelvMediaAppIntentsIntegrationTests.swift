#if compiler(>=6.4) && canImport(AppIntentsTesting) && canImport(MediaIntents)
import AppIntents
import AppIntentsTesting
import MediaIntents
import XCTest

@available(iOS 27.0, *)
final class ShelvMediaAppIntentsIntegrationTests: XCTestCase {
    private let definitions = IntentDefinitions(bundleIdentifier: "ch.vkugler.Shelv")

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Make the target application available to the App Intents test service.
        // This also keeps the test self-contained on fresh CI simulators.
        XCUIApplication().launch()
    }

    func testNativeAudioSchemaIsPublished() {
        let playAudio = definitions.intents["ShelvPlayAudioIntent"]
        let audioSearch = definitions.valueQueries["AudioIntentValueQuery"]
        let instantMixStation = definitions.entities["ShelvAudioAlgorithmicStationEntity"]

        XCTAssertEqual(playAudio.identifier, "ShelvPlayAudioIntent")
        XCTAssertEqual(audioSearch.queryIdentifier, "AudioIntentValueQuery")
        XCTAssertEqual(
            instantMixStation.typeIdentifier,
            "ShelvAudioAlgorithmicStationEntity"
        )
    }

    func testNativeAudioSearchResolvesSmartMixesOutOfProcess() async throws {
        let query = definitions.valueQueries["AudioIntentValueQuery"]
        let playlist = definitions.entities["ShelvAudioPlaylistEntity"]
        let fixtures = [
            ("Newest Tracks", "shelv-smart-mix:newest"),
            ("Frequently Played", "shelv-smart-mix:frequent"),
            ("Recently Played", "shelv-smart-mix:recent"),
            ("Shuffle All Tracks", "shelv-smart-mix:shuffleAll")
        ]

        for (phrase, expectedIdentifier) in fixtures {
            let result = try await query.values(
                for: AudioSearch(criteria: .searchQuery(phrase))
            )
            XCTAssertEqual(
                result.items.count,
                1,
                "The native audio query did not resolve the smart mix for \(phrase)."
            )
            let path: DynamicPropertyPath = result.items[0]
            let entity = try path.as(playlist)
            XCTAssertEqual(entity.identifier.instanceIdentifier, expectedIdentifier)
        }
    }

    func testSmartMixPlaylistQueryReturnsExactEntityOutOfProcess() async throws {
        let playlist = definitions.entities["ShelvAudioPlaylistEntity"]
        let entities = try await playlist.entities(matching: "Newest Tracks")

        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(
            entities.first?.identifier.instanceIdentifier,
            "shelv-smart-mix:newest"
        )
    }

    func testNativeAudioSearchResolvesDownloadQueuesOutOfProcess() async throws {
        let query = definitions.valueQueries["AudioIntentValueQuery"]
        let playlist = definitions.entities["ShelvAudioPlaylistEntity"]
        let fixtures = [
            ("Play downloads in Shelv", "shelv-downloads:shuffled"),
            ("Play all downloads in Shelv", "shelv-downloads:all"),
            ("Play newest downloads in Shelv", "shelv-downloads:newest"),
        ]

        for (phrase, expectedIdentifier) in fixtures {
            let result = try await query.values(
                for: AudioSearch(criteria: .searchQuery(phrase))
            )
            XCTAssertEqual(result.items.count, 1, phrase)
            let path: DynamicPropertyPath = result.items[0]
            let entity = try path.as(playlist)
            XCTAssertEqual(entity.identifier.instanceIdentifier, expectedIdentifier, phrase)
        }
    }
}
#endif
