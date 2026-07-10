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

    func testRecognizesRadioBeforeAndAfterStationName() {
        XCTAssertEqual(ShelvIntentSearchVocabulary.explicitKind(in: "Pop Radio"), .radio)
        XCTAssertEqual(ShelvIntentSearchVocabulary.explicitKind(in: "Radio Pop"), .radio)
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Play Pop Radio in Shelv"),
            .radio
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Play radio Pop in Shelv"),
            .radio
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Spiele Radio Pop in Shelv"),
            .radio
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "在 Shelv 中播放流行电台"),
            .radio
        )
    }

    func testKindWordsEmbeddedInMediaNamesAreNotExplicitKinds() {
        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: "Radiohead"))
        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: "Play Radiohead"))
        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: "Songbird"))
        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: "Play Songbird"))
        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: "Albumin"))
        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: "Play Albumin"))
    }

    func testStationToStationDoesNotForceRadioKind() {
        let query = "Play Station to Station"

        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: query))
        XCTAssertFalse(
            ShelvIntentSearchVocabulary.allows(
                .radio,
                for: query,
                requiresExplicitRadio: true
            )
        )
    }

    func testEmbeddedKindWordsDoNotReceiveRankingBonus() {
        let fixtures: [(ShortcutPlayableKind, String)] = [
            (.radio, "Radiohead"),
            (.song, "Songbird"),
            (.album, "Albumin"),
        ]

        for (kind, query) in fixtures {
            let detectedKindScore = ShelvIntentSearchRanking.score(
                kind: kind,
                title: query,
                artistName: nil,
                albumTitle: nil,
                query: query
            )
            let neutralKindScore = ShelvIntentSearchRanking.score(
                kind: .artist,
                title: query,
                artistName: nil,
                albumTitle: nil,
                query: query
            )

            XCTAssertEqual(detectedKindScore, neutralKindScore, query)
        }
    }

    func testRecognizesExplicitMediaKinds() {
        XCTAssertEqual(ShelvIntentSearchVocabulary.explicitKind(in: "Play the album Mercury"), .album)
        XCTAssertEqual(ShelvIntentSearchVocabulary.explicitKind(in: "Play artist Imagine Dragons"), .artist)
        XCTAssertEqual(ShelvIntentSearchVocabulary.explicitKind(in: "Play playlist Road Trip"), .playlist)
        XCTAssertEqual(ShelvIntentSearchVocabulary.explicitKind(in: "Play the song Time"), .song)
    }

    func testFirstExplicitMediaKindDefinesTheRequestedObject() {
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Play song Time from album Running on Empty"),
            .song
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Play album Mercury by artist Imagine Dragons"),
            .album
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Spiele Lied Zeit aus Album Unendlich"),
            .song
        )
    }

    func testArtistRequestGrammarOverridesGenericSongKindWords() {
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Play songs by Radiohead"),
            .artist
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Play music by Imagine Dragons"),
            .artist
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Spiele Lieder von Silbermond"),
            .artist
        )
    }

    func testDoesNotInferRadioFromAmbiguousName() {
        XCTAssertNil(ShelvIntentSearchVocabulary.explicitKind(in: "Play Pop in Shelv"))
        XCTAssertFalse(
            ShelvIntentSearchVocabulary.allows(
                .radio,
                for: "Play Pop in Shelv",
                requiresExplicitRadio: true
            )
        )
        XCTAssertTrue(
            ShelvIntentSearchVocabulary.allows(
                .album,
                for: "Play Mercury in Shelv",
                requiresExplicitRadio: true
            )
        )
    }

    func testExplicitKindExcludesOtherCatalogKinds() {
        let query = "Play radio Pop in Shelv"
        XCTAssertTrue(
            ShelvIntentSearchVocabulary.allows(.radio, for: query, requiresExplicitRadio: true)
        )
        XCTAssertFalse(
            ShelvIntentSearchVocabulary.allows(.album, for: query, requiresExplicitRadio: true)
        )
        XCTAssertFalse(
            ShelvIntentSearchVocabulary.allows(.artist, for: query, requiresExplicitRadio: true)
        )
    }

    func testInstantMixWordsAreRemovedFromCatalogTerms() {
        let terms = ShelvIntentSearchVocabulary.searchTerms(
            for: "Play an instant mix for Imagine Dragons in Shelv"
        )

        XCTAssertTrue(terms.contains("Imagine Dragons"))
        XCTAssertFalse(terms.dropFirst().contains { term in
            term.localizedCaseInsensitiveContains("instant")
                || term.localizedCaseInsensitiveContains("mix")
        })
    }


    func testSongQualifiedByArtistRanksAheadOfTheArtistAlone() {
        let query = "Play song Time by Jackson Browne"
        let songScore = ShelvIntentSearchRanking.score(
            kind: .song,
            title: "Time",
            artistName: "Jackson Browne",
            albumTitle: "Running on Empty",
            query: query
        )
        let artistScore = ShelvIntentSearchRanking.score(
            kind: .artist,
            title: "Jackson Browne",
            artistName: "Jackson Browne",
            albumTitle: nil,
            query: query
        )

        XCTAssertGreaterThan(songScore, artistScore)
    }

    func testUnqualifiedSongAndArtistQueryRanksTheSongAheadOfTheArtist() {
        let query = "Play Time by Jackson Browne"
        let songScore = ShelvIntentSearchRanking.score(
            kind: .song,
            title: "Time",
            artistName: "Jackson Browne",
            albumTitle: "Running on Empty",
            query: query
        )
        let artistScore = ShelvIntentSearchRanking.score(
            kind: .artist,
            title: "Jackson Browne",
            artistName: "Jackson Browne",
            albumTitle: nil,
            query: query
        )

        XCTAssertGreaterThan(songScore, artistScore)
    }

    func testUnqualifiedGermanSongAndArtistQueryRanksTheSongAheadOfTheArtist() {
        let query = "Spiele Zeit von Silbermond"
        let songScore = ShelvIntentSearchRanking.score(
            kind: .song,
            title: "Zeit",
            artistName: "Silbermond",
            albumTitle: "Auf Auf",
            query: query
        )
        let artistScore = ShelvIntentSearchRanking.score(
            kind: .artist,
            title: "Silbermond",
            artistName: "Silbermond",
            albumTitle: nil,
            query: query
        )

        XCTAssertGreaterThan(songScore, artistScore)
    }

    func testGermanSongQualifiedByArtistRanksAheadOfTheArtistAlone() {
        let query = "Spiele Lied Zeit von Jackson Browne"
        let songScore = ShelvIntentSearchRanking.score(
            kind: .song,
            title: "Zeit",
            artistName: "Jackson Browne",
            albumTitle: nil,
            query: query
        )
        let artistScore = ShelvIntentSearchRanking.score(
            kind: .artist,
            title: "Jackson Browne",
            artistName: "Jackson Browne",
            albumTitle: nil,
            query: query
        )

        XCTAssertGreaterThan(songScore, artistScore)
    }
}
