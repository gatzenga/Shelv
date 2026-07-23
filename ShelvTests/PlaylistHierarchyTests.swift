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

    func testTreeGroupsPlaylistsBeforeFoldersAtEveryLevel() throws {
        let playlists = [
            playlist(id: "1", name: "Loose"),
            playlist(id: "2", name: "Work/Deep/Focus"),
            playlist(id: "3", name: "Work/Energy"),
            playlist(id: "4", name: "Later")
        ]

        let roots = PlaylistTreeNode.make(from: playlists)

        XCTAssertEqual(roots.map(\.title), ["Loose", "Later", "Work"])
        XCTAssertEqual(roots[2].playlistCount, 2)

        let workChildren = try XCTUnwrap(roots[2].children)
        XCTAssertEqual(workChildren.map(\.title), ["Energy", "Deep"])

        let deepChildren = try XCTUnwrap(workChildren[1].children)
        XCTAssertEqual(deepChildren.map(\.title), ["Focus"])
        XCTAssertEqual(deepChildren[0].playlist?.id, "2")
        XCTAssertEqual(workChildren[0].playlist?.id, "3")
    }

    func testTreePreservesConfiguredOrderWithinPlaylistAndFolderGroups() {
        let roots = PlaylistTreeNode.make(from: [
            playlist(id: "folder-b", name: "Folder B/Track"),
            playlist(id: "loose-b", name: "Loose B"),
            playlist(id: "folder-a", name: "Folder A/Track"),
            playlist(id: "loose-a", name: "Loose A")
        ])

        XCTAssertEqual(
            roots.compactMap(\.playlist?.id),
            ["loose-b", "loose-a"]
        )
        XCTAssertEqual(
            roots.compactMap(\.folderPath),
            ["Folder B", "Folder A"]
        )
    }

    func testPlaylistCanShareItsNameWithANestedFolder() throws {
        let roots = PlaylistTreeNode.make(from: [
            playlist(id: "direct", name: "Rock/Test"),
            playlist(id: "nested", name: "Rock/Test/Test")
        ])

        let rock = try XCTUnwrap(roots.first)
        XCTAssertEqual(rock.title, "Rock")

        let rockChildren = try XCTUnwrap(rock.children)
        XCTAssertEqual(rockChildren.map(\.title), ["Test", "Test"])
        XCTAssertEqual(rockChildren[0].playlist?.id, "direct")

        let testFolderChildren = try XCTUnwrap(rockChildren[1].children)
        XCTAssertEqual(testFolderChildren.map(\.title), ["Test"])
        XCTAssertEqual(testFolderChildren[0].playlist?.id, "nested")
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
