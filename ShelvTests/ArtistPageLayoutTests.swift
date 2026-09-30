import XCTest

final class ArtistPageLayoutTests: XCTestCase {
    private func artist(_ id: String, albums: Int?) -> Artist {
        Artist(id: id, name: id, albumCount: albums)
    }

    func testDropsArtistsWithoutAlbumsAndKeepsTheServersOrder() {
        let shown = ArtistPageLayout.shownSimilarArtists(from: [
            artist("a", albums: 2), artist("credit", albums: 0), artist("b", albums: 1), artist("none", albums: nil), artist("c", albums: 5),
        ])
        XCTAssertEqual(shown.map(\.id), ["a", "b", "c"])
    }

    func testCreditOnlyArtistsDoNotTakePlacesFromArtistsWithAlbums() {
        // 5 credit-only artists up front, then 14 with albums: 12 are shown.
        let artists = (0..<5).map { artist("credit\($0)", albums: 0) } + (0..<14).map { artist("real\($0)", albums: 1) }
        let shown = ArtistPageLayout.shownSimilarArtists(from: artists)
        XCTAssertEqual(shown.count, ArtistPageLayout.similarArtistLimit)
        XCTAssertEqual(shown.first?.id, "real0")
        XCTAssertEqual(shown.last?.id, "real11")
    }

    func testNoArtistsGivesAnEmptyRow() {
        XCTAssertTrue(ArtistPageLayout.shownSimilarArtists(from: nil).isEmpty)
    }
}
