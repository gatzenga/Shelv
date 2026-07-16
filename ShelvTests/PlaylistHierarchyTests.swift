import XCTest

final class PlaylistHierarchyTests: XCTestCase {
    func testPlainNameStaysAtRoot() {
        let path = PlaylistNamePath("Focus")

        XCTAssertFalse(path.isNested)
        XCTAssertEqual(path.displayName, "Focus")
        XCTAssertEqual(path.folderComponents, [])
    }

    func testNestedNameUsesFoldersAndLeafName() {
        let path = PlaylistNamePath("Work/Deep/Focus")

        XCTAssertTrue(path.isNested)
        XCTAssertEqual(path.folderComponents, ["Work", "Deep"])
        XCTAssertEqual(path.displayName, "Focus")
    }

    func testSeparatorCompatibilityMatchesFeishin() {
        XCTAssertEqual(PlaylistNamePath("/Focus").displayName, "/Focus")
        XCTAssertFalse(PlaylistNamePath("/Focus").isNested)

        XCTAssertEqual(PlaylistNamePath("Work/").displayName, "Work/")
        XCTAssertFalse(PlaylistNamePath("Work/").isNested)

        let repeatedSeparator = PlaylistNamePath("Work//Focus")
        XCTAssertEqual(repeatedSeparator.folderComponents, ["Work"])
        XCTAssertEqual(repeatedSeparator.displayName, "Focus")

        let whitespace = PlaylistNamePath(" Work / Focus ")
        XCTAssertEqual(whitespace.folderComponents, [" Work "])
        XCTAssertEqual(whitespace.displayName, " Focus ")
    }

    func testTreeMergesFoldersAndPreservesPlaylistOrder() throws {
        let playlists = [
            playlist(id: "1", name: "Loose"),
            playlist(id: "2", name: "Work/Deep/Focus"),
            playlist(id: "3", name: "Work/Energy"),
            playlist(id: "4", name: "Later")
        ]

        let roots = PlaylistTreeNode.make(from: playlists)

        XCTAssertEqual(roots.map(\.title), ["Loose", "Work", "Later"])
        XCTAssertEqual(roots[1].playlistCount, 2)

        let workChildren = try XCTUnwrap(roots[1].children)
        XCTAssertEqual(workChildren.map(\.title), ["Deep", "Energy"])

        let deepChildren = try XCTUnwrap(workChildren[0].children)
        XCTAssertEqual(deepChildren.map(\.title), ["Focus"])
        XCTAssertEqual(deepChildren[0].playlist?.id, "2")
        XCTAssertEqual(workChildren[1].playlist?.id, "3")
    }

    private func playlist(id: String, name: String) -> Playlist {
        Playlist(
            id: id,
            name: name,
            comment: nil,
            songCount: nil,
            duration: nil,
            coverArt: nil,
            created: nil,
            changed: nil,
            songs: nil
        )
    }
}
