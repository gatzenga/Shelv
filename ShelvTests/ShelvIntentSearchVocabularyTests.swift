import XCTest

final class ShelvIntentSearchVocabularyTests: XCTestCase {
    func testRetainsOriginalQueryAndExtractsAlbumAndArtist() {
        let terms = ShelvIntentSearchVocabulary.searchTerms(
            for: "Play the album Mercury by Imagine Dragons"
        )

        XCTAssertEqual(terms.first, "Play the album Mercury by Imagine Dragons")
        XCTAssertTrue(terms.contains("Mercury Imagine Dragons"))
        XCTAssertTrue(terms.contains("Mercury"))
        XCTAssertTrue(terms.contains("Imagine Dragons"))
    }

    func testUnderstandsGermanCommandVocabulary() {
        let terms = ShelvIntentSearchVocabulary.searchTerms(
            for: "Spiele das Album Mercury von Imagine Dragons"
        )

        XCTAssertTrue(terms.contains("Mercury Imagine Dragons"))
        XCTAssertTrue(terms.contains("Mercury"))
        XCTAssertTrue(terms.contains("Imagine Dragons"))
    }

    func testUnderstandsFromArtistWordingAndAppName() {
        let terms = ShelvIntentSearchVocabulary.searchTerms(
            for: "Play Mercury from Imagine Dragons in Shelv"
        )

        XCTAssertTrue(terms.contains("Mercury Imagine Dragons"))
        XCTAssertTrue(terms.contains("Mercury"))
        XCTAssertTrue(terms.contains("Imagine Dragons"))
    }

    func testRemovesPlaybackWordsFromSupplementalTerm() {
        let terms = ShelvIntentSearchVocabulary.searchTerms(
            for: "Please play newest tracks in Shelv"
        )

        XCTAssertEqual(terms.first, "Please play newest tracks in Shelv")
        XCTAssertTrue(terms.contains("newest"))
        XCTAssertFalse(terms.dropFirst().contains { $0.localizedCaseInsensitiveContains("please") })
    }

    func testDeduplicatesFoldedTermsAndRespectsLimit() {
        let terms = ShelvIntentSearchVocabulary.searchTerms(
            for: "Play Ánima by Anima Anima Extra Words",
            maximumCount: 4
        )

        XCTAssertLessThanOrEqual(terms.count, 4)
        let normalized = terms.map(ShelvIntentSearchVocabulary.normalized)
        XCTAssertEqual(Set(normalized).count, normalized.count)
    }

    func testEmptyAndZeroLimitProduceNoTerms() {
        XCTAssertTrue(ShelvIntentSearchVocabulary.searchTerms(for: "   ").isEmpty)
        XCTAssertTrue(
            ShelvIntentSearchVocabulary.searchTerms(for: "Mercury", maximumCount: 0).isEmpty
        )
    }
}
