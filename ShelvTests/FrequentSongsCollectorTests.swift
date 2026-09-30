import XCTest

final class FrequentSongsCollectorTests: XCTestCase {
    private func song(_ id: String, plays: Int?) -> Song {
        Song(id: id, title: id, playCount: plays)
    }

    func testKeepsTheBestSongsInOrderAndDropsNeverPlayedOnes() {
        var collector = FrequentSongsCollector(limit: 3)
        collector.add([song("a", plays: 60), song("b", plays: 30), song("c", plays: 10), song("z", plays: nil), song("y", plays: 0)])
        collector.add([song("d", plays: 50), song("e", plays: 20)])
        XCTAssertEqual(collector.top.map(\.id), ["a", "d", "b"])
    }

    func testCutoffIsZeroUntilTheListIsFullThenTheLastPlace() {
        var collector = FrequentSongsCollector(limit: 2)
        collector.add([song("a", plays: 20)])
        XCTAssertEqual(collector.cutoff, 0)
        collector.add([song("b", plays: 5)])
        XCTAssertEqual(collector.cutoff, 5)
    }

    func testAlbumWithNoMorePlaysThanLastPlaceIsNotLoaded() {
        var collector = FrequentSongsCollector(limit: 1)
        collector.add([song("a", plays: 20)])
        XCTAssertTrue(collector.isWorthLoading(albumPlayCount: 21))
        XCTAssertFalse(collector.isWorthLoading(albumPlayCount: 20))
        XCTAssertFalse(collector.isWorthLoading(albumPlayCount: 19))
        XCTAssertFalse(collector.isWorthLoading(albumPlayCount: nil))
    }

    /// The walk-through from the discussion: last place 20, an album with 21
    /// plays is still looked at but brings nothing, an album with 19 is not.
    func testWalkThroughStopsAtTheFirstAlbumThatCannotDisplaceAnyone() {
        var collector = FrequentSongsCollector(limit: 1)
        collector.add([song("x", plays: 20), song("y", plays: 1), song("z", plays: 1)])
        XCTAssertTrue(collector.isWorthLoading(albumPlayCount: 21))
        collector.add((0..<21).map { song("s\($0)", plays: 1) })
        XCTAssertEqual(collector.top.map(\.id), ["x"])
        XCTAssertFalse(collector.isWorthLoading(albumPlayCount: 19))
    }

    func testASingleHitOnALowAlbumStillMakesTheList() {
        // Album 1: 100 songs with one play each. Album 2: one song with two.
        var collector = FrequentSongsCollector(limit: 50)
        collector.add((0..<100).map { song("a\($0)", plays: 1) })
        XCTAssertTrue(collector.isWorthLoading(albumPlayCount: 2))
        collector.add([song("hit", plays: 2)])
        XCTAssertEqual(collector.top.first?.id, "hit")
        XCTAssertEqual(collector.top.count, 50)
    }
}
