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

    func testResolvesSmartMixPhrasesFromNativeAudioSearch() {
        let fixtures: [(String, ShortcutSmartMix)] = [
            ("Newest", .newest),
            ("Play newest tracks in Shelf", .newest),
            ("Play the mixed newest tracks in Shelf", .newest),
            ("Ask Shelv to play the Latest Music mix", .newest),
            ("Play recently added in Shelf", .newest),
            ("Play recently added mix in Shelf", .newest),
            ("Play frequently played in Shelf", .frequent),
            ("Play frequently played mix in Shelf", .frequent),
            ("Play most played in Shelf", .frequent),
            ("Play most played mix in Shelf", .frequent),
            ("Play popular music in Shelv", .frequent),
            ("Play the popular mix in Shelv", .frequent),
            ("Play recently played in Shelf", .recent),
            ("Play recently played mix in Shelf", .recent),
            ("Shuffle all tracks in Shelv", .shuffleAll),
            ("Shuffle my library with Shelv", .shuffleAll),
            ("Spiele die neueste Musik in Shelv", .newest),
            ("Spiele häufig gespielte Titel in Shelv", .frequent),
            ("Spiele zuletzt gespielte Titel in Shelv", .recent),
            ("Mische alle Titel in Shelv", .shuffleAll),
            ("在 Shelv 中播放最新音乐", .newest),
            ("在 Shelv 中播放最近播放", .recent),
            ("在 Shelv 中随机播放所有歌曲", .shuffleAll),
        ]

        for (phrase, expected) in fixtures {
            XCTAssertEqual(
                ShelvSmartMixIntentVocabulary.smartMix(for: phrase),
                expected,
                phrase
            )
        }
    }

    func testSmartMixVocabularyDoesNotStealExplicitCatalogRequests() {
        let catalogRequests = [
            "Play the album Newest in Shelv",
            "Play the artist Recent in Shelv",
            "Play the playlist Latest in Shelv",
            "Play the song named Newest Tracks in Shelv",
            "Play Mercury in Shelv",
        ]

        for phrase in catalogRequests {
            XCTAssertNil(ShelvSmartMixIntentVocabulary.smartMix(for: phrase), phrase)
        }
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

    func testQualifierMediaKindsDoNotReplaceTheRequestedObject() {
        XCTAssertNil(
            ShelvIntentSearchVocabulary.explicitKind(
                in: "Play Time from the album Running on Empty"
            )
        )
        XCTAssertNil(
            ShelvIntentSearchVocabulary.explicitKind(
                in: "Play Demons by the artist Imagine Dragons"
            )
        )
        XCTAssertNil(
            ShelvIntentSearchVocabulary.explicitKind(
                in: "Spiele Zeit aus dem Album Unendlich"
            )
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(
                in: "Play album Songs by artist Imagine Dragons"
            ),
            .album
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
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Shuffle songs by Imagine Dragons"),
            .artist
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(in: "Mische die Lieder von Silbermond"),
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

    func testServerSearchKindsAreNarrowedBeforeFetching() {
        let allKinds = Set(ShortcutPlayableKind.allCases)

        XCTAssertEqual(
            ShelvIntentSearchVocabulary.effectiveAllowedKinds(
                allKinds,
                for: "Play Pop Radio in Shelv",
                requiresExplicitRadio: true
            ),
            [.radio]
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.effectiveAllowedKinds(
                allKinds,
                for: "Play the song Demons by Imagine Dragons in Shelv",
                requiresExplicitRadio: true
            ),
            [.song]
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.effectiveAllowedKinds(
                allKinds,
                for: "Play Mercury in Shelv",
                requiresExplicitRadio: true
            ),
            [.song, .album, .artist, .playlist]
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

    func testRejectsUnrelatedSongReturnedForExplicitSongRequest() {
        let query = "Play the song Demons by Imagine Dragons in Shelv"

        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Demons",
                artistName: "Imagine Dragons",
                albumTitle: "Night Visions",
                query: query
            )
        )
        XCTAssertNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "No Role Modelz",
                artistName: "J. Cole",
                albumTitle: "2014 Forest Hills Drive",
                query: query
            )
        )
    }

    func testRejectsSameTitleByWrongArtist() {
        let query = "Play the song Demons by Imagine Dragons in Shelv"

        XCTAssertNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Demons",
                artistName: "Doja Cat",
                albumTitle: "Scarlet",
                query: query
            )
        )
    }

    func testAlbumQualifierMustMatchAlbumField() {
        let query = "Play song Time from album Running on Empty"

        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Time",
                artistName: "Jackson Browne",
                albumTitle: "Running on Empty",
                query: query
            )
        )
        XCTAssertNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Time",
                artistName: "Pink Floyd",
                albumTitle: "The Dark Side of the Moon",
                query: query
            )
        )
    }

    func testAlbumAndArtistQualifierKindsResolveWithoutAnExplicitSongWord() {
        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Time",
                artistName: "Jackson Browne",
                albumTitle: "Running on Empty",
                query: "Play Time from the album Running on Empty"
            )
        )
        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Demons",
                artistName: "Imagine Dragons",
                albumTitle: "Night Visions",
                query: "Play Demons by the artist Imagine Dragons"
            )
        )
        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Zeit",
                artistName: "Silbermond",
                albumTitle: "Unendlich",
                query: "Spiele Zeit aus dem Album Unendlich"
            )
        )
    }

    func testUnqualifiedArtistNameRanksArtistAheadOfSongsByArtist() {
        let query = "Shuffle Imagine Dragons in Shelv"
        let artistScore = ShelvIntentSearchRanking.relevantScore(
            kind: .artist,
            title: "Imagine Dragons",
            artistName: "Imagine Dragons",
            albumTitle: nil,
            query: query
        )
        let songScore = ShelvIntentSearchRanking.relevantScore(
            kind: .song,
            title: "Demons",
            artistName: "Imagine Dragons",
            albumTitle: "Night Visions",
            query: query
        )

        XCTAssertNotNil(artistScore)
        XCTAssertNotNil(songScore)
        XCTAssertGreaterThan(artistScore ?? 0, songScore ?? 0)
        XCTAssertTrue(
            ShelvIntentSearchRanking.isPrimaryMatch(
                kind: .artist,
                title: "Imagine Dragons",
                artistName: "Imagine Dragons",
                albumTitle: nil,
                query: query
            )
        )
        XCTAssertFalse(
            ShelvIntentSearchRanking.isPrimaryMatch(
                kind: .song,
                title: "Demons",
                artistName: "Imagine Dragons",
                albumTitle: "Night Visions",
                query: query
            )
        )
    }

    func testAlbumTitleIsPrimaryOnlyForAlbumNotSongsFromAlbum() {
        let query = "Play Mercury in Shelv"

        XCTAssertTrue(
            ShelvIntentSearchRanking.isPrimaryMatch(
                kind: .album,
                title: "Mercury",
                artistName: "Imagine Dragons",
                albumTitle: nil,
                query: query
            )
        )
        XCTAssertFalse(
            ShelvIntentSearchRanking.isPrimaryMatch(
                kind: .song,
                title: "Bones",
                artistName: "Imagine Dragons",
                albumTitle: "Mercury",
                query: query
            )
        )
    }

    func testTitleBeginningWithFromIsNotMisreadAsArtistQualifier() {
        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .album,
                title: "From Mars to Sirius",
                artistName: "Gojira",
                albumTitle: nil,
                query: "Play From Mars to Sirius in Shelv"
            )
        )
    }

    func testAskAppPhraseLeavesOnlyCatalogTerms() {
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.contentTokens(
                in: "Ask Shelv to play the song Demons by Imagine Dragons"
            ),
            ["demons", "imagine", "dragons"]
        )
    }

    func testPrimaryRequestPreservesWordsInsideRealCatalogNames() {
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.primaryRequestTokens(
                in: "Play All My Loving in Shelv"
            ),
            ["all", "my", "loving"]
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.primaryRequestTokens(
                in: "Play The Beatles in Shelv"
            ),
            ["the", "beatles"]
        )
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.primaryRequestTokens(
                in: "Play Pop Radio in Shelv"
            ),
            ["pop"]
        )
    }

    func testLongerTitleWithGrammarWordsBeatsShortPartialTitle() {
        let query = "Play All My Loving in Shelv"

        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "All My Loving",
                artistName: "The Beatles",
                albumTitle: "With the Beatles",
                query: query
            )
        )
        XCTAssertNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Loving",
                artistName: "Other Artist",
                albumTitle: nil,
                query: query
            )
        )
    }

    func testByInsideSongTitleUsesFinalByAsArtistQualifier() {
        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .song,
                title: "Stand by Me",
                artistName: "Ben E. King",
                albumTitle: nil,
                query: "Play Stand by Me by Ben E. King in Shelv"
            )
        )
    }

    func testFromInsideAlbumTitleIsKeptWhenWholeTitleMatches() {
        XCTAssertNotNil(
            ShelvIntentSearchRanking.relevantScore(
                kind: .album,
                title: "Songs from the Big Chair",
                artistName: "Tears for Fears",
                albumTitle: nil,
                query: "Play the album Songs from the Big Chair in Shelv"
            )
        )
    }

    func testDownloadVocabularySeparatesModesAndCatalogNames() {
        XCTAssertEqual(
            ShelvDownloadsIntentVocabulary.mode(for: "Play downloads in Shelv"),
            .shuffled
        )
        XCTAssertEqual(
            ShelvDownloadsIntentVocabulary.mode(for: "Play all downloads in Shelv"),
            .all
        )
        XCTAssertEqual(
            ShelvDownloadsIntentVocabulary.mode(for: "Play newest downloads in Shelv"),
            .newest
        )
        XCTAssertEqual(
            ShelvDownloadsIntentVocabulary.mode(for: "Spiele heruntergeladene Musik in Shelv"),
            .shuffled
        )
        XCTAssertNil(
            ShelvDownloadsIntentVocabulary.mode(for: "Play the playlist Downloads in Shelv")
        )
    }

    func testInstantMixVocabularyExtractsOnlyTheSeed() {
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Play an instant mix for Imagine Dragons in Shelv"
            ),
            "imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Ask Shelv to play an instant mix for Mercury"
            ),
            "mercury"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Spiele einen Instant Mix für Imagine Dragons in Shelv"
            ),
            "imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Instant Mix für das Album Mercury von Imagine Dragons"
            ),
            "mercury von imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Instant Mix for the album Mercury by Imagine Dragons"
            ),
            "mercury by imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Instantmix für Imagine Dragons"
            ),
            "imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Musik wie Imagine Dragons"
            ),
            "imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Play music like Imagine Dragons in Shelv"
            ),
            "imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Create a station from Imagine Dragons in Shelv"
            ),
            "imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Create an instant mix based on Imagine Dragons in Shelv"
            ),
            "imagine dragons"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Erstelle einen Mix basierend auf Mercury"
            ),
            "mercury"
        )
        XCTAssertEqual(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Start Instant Mix for Demons from Imagine Dragons in Shells"
            ),
            "demons from imagine dragons"
        )
        XCTAssertNil(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Play the song Instant Mix in Shelv"
            )
        )
        XCTAssertNil(
            ShelvInstantMixIntentVocabulary.seedQuery(
                from: "Instant Mix für"
            )
        )
    }

    func testDeterministicPlaybackSelectsExactArtistInsteadOfRelatedSongs() {
        let items = [
            catalogItem(
                id: "song",
                kind: .song,
                title: "Demons",
                artist: "Imagine Dragons",
                album: "Night Visions"
            ),
            catalogItem(
                id: "artist",
                kind: .artist,
                title: "Imagine Dragons",
                artist: "Imagine Dragons"
            ),
        ]

        let selected = deterministicPlaybackMatches(
            items,
            query: "Play Imagine Dragons in Shelv"
        )

        XCTAssertEqual(selected.map(\.id), ["artist"])
    }

    func testDeterministicPlaybackUsesQualifiedSongAndArtist() {
        let items = [
            catalogItem(
                id: "correct",
                kind: .song,
                title: "Demons",
                artist: "Imagine Dragons",
                album: "Night Visions"
            ),
            catalogItem(
                id: "wrong",
                kind: .song,
                title: "Demons",
                artist: "Doja Cat",
                album: "Scarlet"
            ),
        ]

        let selected = deterministicPlaybackMatches(
            items,
            query: "Play the song Demons by Imagine Dragons in Shelv"
        )

        XCTAssertEqual(selected.map(\.id), ["correct"])
    }

    func testDeterministicPlaybackKeepsGenuineTitleAmbiguity() {
        let items = [
            catalogItem(
                id: "album",
                kind: .album,
                title: "Mercury",
                artist: "Imagine Dragons"
            ),
            catalogItem(
                id: "song",
                kind: .song,
                title: "Mercury",
                artist: "Imagine Dragons",
                album: "Mercury"
            ),
        ]

        let selected = deterministicPlaybackMatches(
            items,
            query: "Play Mercury in Shelv"
        )

        XCTAssertEqual(Set(selected.map(\.id)), Set(["album", "song"]))
    }

    func testUnqualifiedArtistBeatsEponymousAlbum() {
        let items = [
            catalogItem(
                id: "album",
                kind: .album,
                title: "Dire Straits",
                artist: "Dire Straits"
            ),
            catalogItem(
                id: "artist",
                kind: .artist,
                title: "Dire Straits",
                artist: "Dire Straits"
            ),
        ]

        let selected = deterministicPlaybackMatches(
            items,
            query: "Play Dire Straits in Shelv"
        )

        XCTAssertEqual(selected.map(\.id), ["artist"])
    }

    func testExplicitEponymousAlbumRequestKeepsAlbum() {
        let items = [
            catalogItem(
                id: "album",
                kind: .album,
                title: "Dire Straits",
                artist: "Dire Straits"
            ),
            catalogItem(
                id: "artist",
                kind: .artist,
                title: "Dire Straits",
                artist: "Dire Straits"
            ),
        ]

        let selected = deterministicPlaybackMatches(
            items,
            query: "Play the album Dire Straits in Shelv"
        )

        XCTAssertEqual(selected.map(\.id), ["album"])
    }

    func testQualifiedEponymousAlbumRequestKeepsAlbum() {
        let items = [
            catalogItem(
                id: "album",
                kind: .album,
                title: "Dire Straits",
                artist: "Dire Straits"
            ),
            catalogItem(
                id: "artist",
                kind: .artist,
                title: "Dire Straits",
                artist: "Dire Straits"
            ),
        ]

        let selected = deterministicPlaybackMatches(
            items,
            query: "Play Dire Straits by Dire Straits in Shelv"
        )

        XCTAssertEqual(selected.map(\.id), ["album"])
    }

    func testNegatedAlbumCorrectionSelectsArtist() {
        XCTAssertEqual(
            ShelvIntentSearchVocabulary.explicitKind(
                in: "Play Electric Light Orchestra, not the album, the artist"
            ),
            .artist
        )
    }

    private struct IntentCandidate {
        let id: String
        let kind: ShortcutPlayableKind
        let title: String
        let artist: String?
        let album: String?
    }

    private func deterministicPlaybackMatches(
        _ items: [IntentCandidate],
        query: String
    ) -> [IntentCandidate] {
        ShelvIntentSearchRanking.deterministicPlaybackMatches(items, query: query) { item in
            (item.kind, item.title, item.artist, item.album)
        }
    }

    private func catalogItem(
        id: String,
        kind: ShortcutPlayableKind,
        title: String,
        artist: String? = nil,
        album: String? = nil
    ) -> IntentCandidate {
        IntentCandidate(
            id: id,
            kind: kind,
            title: title,
            artist: artist,
            album: album
        )
    }
}
