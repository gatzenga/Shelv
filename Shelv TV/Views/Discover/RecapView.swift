import SwiftUI

/// Eigener Tab für Recap-Playlists (nur sichtbar wenn `recapEnabled`).
/// Zeigt die generierten Wochen-/Monats-/Jahres-Rückblicke, neueste zuerst.
struct RecapView: View {
    @ObservedObject var library = LibraryStore.shared
    @ObservedObject var recap = RecapStore.shared
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 240), spacing: 50)]

    /// Recap-Playlists nach Periodenstart absteigend (über die Registry).
    private var recapPlaylists: [Playlist] {
        let order = Dictionary(recap.entries.map { ($0.playlistId, $0.periodStart) }) { a, _ in a }
        return library.playlists
            .filter { recap.recapPlaylistIds.contains($0.id) }
            .sorted { (order[$0.id] ?? 0) > (order[$1.id] ?? 0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if recapPlaylists.isEmpty {
                        ContentUnavailableView(
                            String(localized: "no_recaps_yet"),
                            systemImage: "sparkles.rectangle.stack"
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: columns, spacing: 50) {
                            ForEach(recapPlaylists) { PlaylistCard(playlist: $0) }
                        }
                    }
                }
                .padding(50)
            }
            .scrollClipDisabled()
            .task { await library.loadPlaylists() }
        }
    }
}
