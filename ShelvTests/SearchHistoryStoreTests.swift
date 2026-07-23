import XCTest

final class SearchHistoryStoreTests: XCTestCase {
    func testRecordNormalizesWhitespaceAndMovesDuplicateToFront() {
        let serverID = UUID()
        defer { SearchHistoryStore.clear(for: serverID) }

        _ = SearchHistoryStore.record("Alice in Chains", for: serverID)
        _ = SearchHistoryStore.record("  Soundgarden   Live  ", for: serverID)
        let entries = SearchHistoryStore.record("alice IN chains", for: serverID)

        XCTAssertEqual(entries, ["alice IN chains", "Soundgarden Live"])
    }

    func testHistoryKeepsOnlyNewestTwentyEntries() {
        let serverID = UUID()
        defer { SearchHistoryStore.clear(for: serverID) }

        for index in 0...SearchHistoryStore.maximumEntryCount {
            SearchHistoryStore.record("Query \(index)", for: serverID)
        }

        let entries = SearchHistoryStore.entries(for: serverID)
        XCTAssertEqual(entries.count, SearchHistoryStore.maximumEntryCount)
        XCTAssertEqual(entries.first, "Query 20")
        XCTAssertEqual(entries.last, "Query 1")
    }

    func testHistoryAndClearAreScopedPerServer() {
        let firstServerID = UUID()
        let secondServerID = UUID()
        defer {
            SearchHistoryStore.clear(for: firstServerID)
            SearchHistoryStore.clear(for: secondServerID)
        }

        SearchHistoryStore.record("First", for: firstServerID)
        SearchHistoryStore.record("Second", for: secondServerID)
        SearchHistoryStore.clear(for: firstServerID)

        XCTAssertTrue(SearchHistoryStore.entries(for: firstServerID).isEmpty)
        XCTAssertEqual(SearchHistoryStore.entries(for: secondServerID), ["Second"])
    }
}
