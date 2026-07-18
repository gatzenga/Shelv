import XCTest

final class DownloadRetryRegistryTests: XCTestCase {
    func testRemovingEntryInvalidatesItsToken() {
        var registry = DownloadRetryRegistry<String>()
        let token = registry.register("first", forKey: "song")

        XCTAssertEqual(registry.removeValue(forKey: "song"), "first")
        XCTAssertNil(registry.takeValue(forKey: "song", token: token))
        XCTAssertTrue(registry.isEmpty)
    }

    func testOldTokenCannotConsumeNewerRetryForSameKey() {
        var registry = DownloadRetryRegistry<String>()
        let oldToken = registry.register("old", forKey: "song")
        let newToken = registry.register("new", forKey: "song")

        XCTAssertNil(registry.takeValue(forKey: "song", token: oldToken))
        XCTAssertTrue(registry.contains("song"))
        XCTAssertEqual(registry.takeValue(forKey: "song", token: newToken), "new")
        XCTAssertTrue(registry.isEmpty)
    }
}
