import XCTest

final class ArtistTopSongsRankingTests: XCTestCase {
    func testLastFMRankingKeepsLastFMOrderAndSkipsTracksNotInTheLibrary() {
        let songs = [
            Song(id: "1", title: "Airplanes", artist: "B.o.B", playCount: 9),
            Song(id: "2", title: "Magic", artist: "B.o.B", playCount: 1)
        ]
        let tracks = [
            LastFMTrack(title: "Nothing on You", artist: "B.o.B", album: nil),
            LastFMTrack(title: "Magic", artist: "B.o.B", album: nil),
            LastFMTrack(title: "Airplanes", artist: "B.o.B", album: nil)
        ]

        let ranked = ArtistTopSongsRanking.rankLastFMTracks(tracks, in: songs)

        XCTAssertEqual(ranked.map { $0.id }, ["2", "1"])
    }

    func testLastFMRankingUsesTheMostPlayedCopyAndDropsRepeatedTitles() {
        let songs = [
            Song(id: "single", title: "Peace", artist: "Depeche Mode", playCount: 3),
            Song(id: "album", title: "Peace", artist: "Depeche Mode", playCount: 12)
        ]
        let tracks = [
            LastFMTrack(title: "Peace", artist: "Depeche Mode", album: nil),
            LastFMTrack(title: "PEACE", artist: "Depeche Mode", album: nil)
        ]

        XCTAssertEqual(ArtistTopSongsRanking.rankLastFMTracks(tracks, in: songs).map { $0.id }, ["album"])
    }

    func testLastFMRankingHonoursTheLimit() {
        let songs = (1...12).map { Song(id: "\($0)", title: "Track \($0)", artist: "Band") }
        let tracks = (1...12).map { LastFMTrack(title: "Track \($0)", artist: "Band", album: nil) }

        XCTAssertEqual(ArtistTopSongsRanking.rankLastFMTracks(tracks, in: songs, limit: 5).count, 5)
        XCTAssertEqual(ArtistTopSongsRanking.rankLastFMTracks(tracks, in: songs).count, ArtistTopSongsRanking.limit)
    }

    func testLastFMScansAllAlbumsUpToItsCapRegardlessOfPlayCount() {
        let albums = (1...60).map { (index: Int) in
            Album(id: "\(index)", name: "Album \(index)", playCount: index == 60 ? nil : index)
        }

        let scanned = ArtistTopSongsRanking.lastFMAlbums(from: albums)

        XCTAssertEqual(scanned.count, ArtistTopSongsRanking.lastFMAlbumLimit)
    }

    func testPlayCountFallbackOrdersByPlayCountAndIgnoresUnplayedTracks() {
        let songs = [
            Song(id: "1", title: "Never played"),
            Song(id: "2", title: "Played twice", playCount: 2),
            Song(id: "3", title: "Played once", playCount: 1),
            Song(id: "4", title: "Played a lot", playCount: 40),
            Song(id: "5", title: "Played zero times", playCount: 0)
        ]

        let ranked = ArtistTopSongsRanking.rankByPlayCount(songs)

        XCTAssertEqual(ranked.map { $0.id }, ["4", "2", "3"])
    }

    func testPlayCountFallbackReturnsNothingWhenNoTrackWasEverPlayed() {
        let songs = [
            Song(id: "1", title: "One"),
            Song(id: "2", title: "Two", playCount: 0)
        ]

        XCTAssertTrue(ArtistTopSongsRanking.rankByPlayCount(songs).isEmpty)
    }

    func testPlayCountFallbackKeepsTheMostPlayedCopyOfADuplicatedTitle() {
        let songs = [
            Song(id: "album", title: "Peace", playCount: 12),
            Song(id: "single", title: "PEACE", playCount: 3)
        ]

        XCTAssertEqual(ArtistTopSongsRanking.rankByPlayCount(songs).map { $0.id }, ["album"])
    }

    func testFallbackScansTheMostPlayedAlbumsFirstAndCapsTheFanOut() {
        let albums = (1...40).map { (index: Int) in
            Album(id: "\(index)", name: "Album \(index)", playCount: index)
        }

        let scanned = ArtistTopSongsRanking.fallbackAlbums(from: albums)

        XCTAssertEqual(scanned.count, ArtistTopSongsRanking.fallbackAlbumLimit)
        XCTAssertEqual(scanned.first?.id, "40")
        XCTAssertEqual(scanned.last?.id, "16")
    }

    func testFallbackHandlesAlbumsWithoutPlayCounts() {
        let albums = [
            Album(id: "unplayed", name: "Unplayed"),
            Album(id: "played", name: "Played", playCount: 5)
        ]

        XCTAssertEqual(ArtistTopSongsRanking.fallbackAlbums(from: albums).first?.id, "played")
    }
}
