import XCTest

final class IndexedSongOccurrenceTests: XCTestCase {
    func testRepeatedSongIdentifiersReceiveDistinctOccurrenceIDs() {
        let song = Song(id: "same-song", title: "Repeated song")

        let rows = IndexedSongOccurrence.rows(for: [song, song])

        XCTAssertEqual(rows.map(\.index), [0, 1])
        XCTAssertEqual(rows.map(\.occurrence), [0, 1])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.map(\.song), [song, song])
    }

    func testUnrelatedInsertionKeepsExistingOccurrenceIDsStable() {
        let repeated = Song(id: "same-song", title: "Repeated song")
        let inserted = Song(id: "inserted-song", title: "Inserted song")

        let before = IndexedSongOccurrence.rows(for: [repeated, repeated])
        let after = IndexedSongOccurrence.rows(for: [inserted, repeated, repeated])

        XCTAssertEqual(before.map(\.id), Array(after.dropFirst().map(\.id)))
    }
}
