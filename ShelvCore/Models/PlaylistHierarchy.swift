import Foundation

/// Interpretiert Playlist-Namen als virtuelle Ordnerpfade, ohne den Namen auf dem
/// Server zu verändern. Das Verhalten entspricht Feishin: Leere Segmente werden
/// ignoriert und nur Namen mit mindestens zwei Segmenten bilden eine Hierarchie.
nonisolated struct PlaylistNamePath: Hashable, Sendable {
    static let separator: Character = "/"

    let rawValue: String
    let components: [String]

    init(_ rawValue: String) {
        self.rawValue = rawValue
        components = rawValue
            .split(separator: Self.separator, omittingEmptySubsequences: true)
            .map(String.init)
    }

    var isNested: Bool { components.count > 1 }

    var folderComponents: [String] {
        isNested ? Array(components.dropLast()) : []
    }

    var displayName: String {
        isNested ? (components.last ?? rawValue) : rawValue
    }
}

extension Playlist {
    var hierarchyDisplayName: String {
        PlaylistNamePath(name).displayName
    }
}

/// Plattformunabhängiger Baum für die Playlist-Darstellung. Ordner sind rein
/// virtuell; Blätter behalten immer das originale `Playlist`-Objekt für API-Aufrufe.
nonisolated struct PlaylistTreeNode: Identifiable, Sendable {
    let id: String
    let title: String
    let folderPath: String?
    let playlist: Playlist?
    var children: [PlaylistTreeNode]?

    var isFolder: Bool { children != nil }

    var playlistCount: Int {
        if playlist != nil { return 1 }
        return children?.reduce(0) { $0 + $1.playlistCount } ?? 0
    }

    static func make(from playlists: [Playlist]) -> [PlaylistTreeNode] {
        var roots: [PlaylistTreeNode] = []

        for playlist in playlists {
            let namePath = PlaylistNamePath(playlist.name)
            guard namePath.isNested else {
                roots.append(playlistNode(playlist, title: namePath.displayName))
                continue
            }

            insert(
                playlist,
                title: namePath.displayName,
                folders: ArraySlice(namePath.folderComponents),
                parentComponents: [],
                into: &roots
            )
        }

        return playlistsBeforeFolders(in: roots)
    }

    /// Keeps the caller's configured order stable within both groups while
    /// presenting playlist leaves before virtual folders at every tree level.
    private static func playlistsBeforeFolders(
        in nodes: [PlaylistTreeNode]
    ) -> [PlaylistTreeNode] {
        let recursivelyOrdered = nodes.map { node in
            guard let children = node.children else { return node }
            var folder = node
            folder.children = playlistsBeforeFolders(in: children)
            return folder
        }
        return recursivelyOrdered.filter { !$0.isFolder }
            + recursivelyOrdered.filter(\.isFolder)
    }

    private static func insert(
        _ playlist: Playlist,
        title: String,
        folders: ArraySlice<String>,
        parentComponents: [String],
        into nodes: inout [PlaylistTreeNode]
    ) {
        guard let folderTitle = folders.first else {
            nodes.append(playlistNode(playlist, title: title))
            return
        }

        let pathComponents = parentComponents + [folderTitle]
        let folderPath = pathComponents.joined(separator: String(PlaylistNamePath.separator))

        if let index = nodes.firstIndex(where: { $0.folderPath == folderPath }) {
            var folder = nodes[index]
            var children = folder.children ?? []
            insert(
                playlist,
                title: title,
                folders: folders.dropFirst(),
                parentComponents: pathComponents,
                into: &children
            )
            folder.children = children
            nodes[index] = folder
        } else {
            var children: [PlaylistTreeNode] = []
            insert(
                playlist,
                title: title,
                folders: folders.dropFirst(),
                parentComponents: pathComponents,
                into: &children
            )
            nodes.append(
                PlaylistTreeNode(
                    id: "folder:\(folderPath)",
                    title: folderTitle,
                    folderPath: folderPath,
                    playlist: nil,
                    children: children
                )
            )
        }
    }

    private static func playlistNode(_ playlist: Playlist, title: String) -> PlaylistTreeNode {
        PlaylistTreeNode(
            id: "playlist:\(playlist.id)",
            title: title,
            folderPath: nil,
            playlist: playlist,
            children: nil
        )
    }
}
