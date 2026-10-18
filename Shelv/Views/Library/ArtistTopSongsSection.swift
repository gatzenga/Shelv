import SwiftUI

/// A cell in the artist Top Songs shelf: rank (swapped for the "now playing"
/// waveform when this song is the one playing), the shared song row, and an
/// explicit "..." menu button instead of long-press/swipe. This shelf lives
/// inside a horizontally scrolling grid, where long-press and swipe conflict
/// with the grid's own gesture recognizer rather than being recognized
/// reliably; the "..." button sidesteps that entirely.
struct ArtistTopSongCell: View {
    let rank: Int
    let song: Song
    let accentColor: Color
    var rankWidth: CGFloat = 20
    let isOffline: Bool
    let isFavorite: Bool
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPlay) {
                HStack(spacing: 10) {
                    NowPlayingIndicator(
                        songId: song.id,
                        fallbackIndex: rank,
                        accentColor: accentColor,
                        width: rankWidth,
                        alignment: .leading
                    )
                    LibraryStarredSongRow(song: song)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SongMenuButton(
                song: song,
                isOffline: isOffline,
                isFavorite: isFavorite,
                onPlay: onPlay,
                onFavorite: onFavorite,
                onAddToPlaylist: onAddToPlaylist,
                onPlayNext: onPlayNext,
                onAddToQueue: onAddToQueue
            )
        }
    }
}

/// The full ranked list behind the Top Songs title: numbered, with covers, and the same
/// swipe, long-press and "..." actions as any other song list.
struct ArtistTopSongsListView: View {
    let title: String
    let songs: [Song]

    @ObservedObject private var libraryStore = LibraryStore.shared
    @ObservedObject private var offlineMode = OfflineModeService.shared
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var playlistSelection: PlaylistSongsSelection?
    @State private var currentToast: ShelveToast?

    var body: some View {
        List {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                row(song, index: index)
            }
            PlayerBottomSpacer()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $playlistSelection) { selection in
            AddToPlaylistSheet(songIds: selection.songIds)
                .environmentObject(libraryStore)
                .tint(accentColor)
        }
        .shelveToast($currentToast)
    }

    private func row(_ song: Song, index: Int) -> some View {
        let isFavorite = libraryStore.isSongStarred(song)
        let play: () -> Void = { player.play(songs: songs, startIndex: index) }
        let favorite: () -> Void = {
            haptic(.medium)
            Task { await libraryStore.toggleStarSong(song) }
        }
        let addToPlaylist: () -> Void = { playlistSelection = PlaylistSongsSelection(songIds: [song.id]) }
        let playNext: () -> Void = {
            haptic()
            player.addPlayNext(song)
            currentToast = ShelveToast(message: String(localized: "plays_next"))
        }
        let addToQueue: () -> Void = {
            haptic()
            player.addToQueue(song)
            currentToast = ShelveToast(message: String(localized: "added_to_queue"))
        }
        return ArtistTopSongCell(
            rank: index + 1,
            song: song,
            accentColor: accentColor,
            rankWidth: 28,
            isOffline: offlineMode.isOffline,
            isFavorite: isFavorite,
            onPlay: play,
            onFavorite: favorite,
            onAddToPlaylist: addToPlaylist,
            onPlayNext: playNext,
            onAddToQueue: addToQueue
        )
        .listRowSeparator(index == 0 ? .hidden : .visible, edges: .top)
        .listRowSeparator(index == songs.count - 1 ? .hidden : .visible, edges: .bottom)
        .personalizedSongSwipeActions(
            song: song,
            isOffline: offlineMode.isOffline,
            isFavorite: isFavorite,
            accentColor: accentColor,
            onPlay: play,
            onFavorite: favorite,
            onAddToPlaylist: addToPlaylist,
            onPlayNext: playNext,
            onAddToQueue: addToQueue
        )
    }
}
