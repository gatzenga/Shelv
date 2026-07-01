import AppKit
import SwiftUI

struct PlaylistTrackRow: View {
    let song: Song
    let trackNumber: Int
    let isPlaying: Bool
    var showFavorite: Bool = false
    var showPlaylist: Bool = false
    var isStarred: Bool = false
    let themeColor: Color
    var isEditMode: Bool = false
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onFavorite: () -> Void
    let onAddToPlaylist: () -> Void
    let onRemoveFromPlaylist: () -> Void
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}

    @ObservedObject private var offlineMode = OfflineModeService.shared
    @AppStorage(PersonalizationPreferenceKey.showInstantMixActions) private var showInstantMixActions = true
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if isEditMode {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                } else if isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(themeColor)
                        .symbolEffect(.variableColor.iterative)
                } else {
                    Text("\(trackNumber)")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .frame(width: 36, alignment: .trailing)
            .padding(.leading, 20)

            CoverArtView(
                url: song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 80) },
                size: 40,
                cornerRadius: 4
            )
            .padding(.leading, 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 12)

            Spacer()

            if isEditMode {
                HStack(spacing: 4) {
                    Button { onMoveUp() } label: {
                        Image(systemName: "chevron.up")
                            .font(.body.bold())
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canMoveUp)

                    Button { onMoveDown() } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.bold())
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canMoveDown)

                    Button(role: .destructive) { onRemoveFromPlaylist() } label: {
                        Image(systemName: "trash")
                            .font(.body)
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.trailing, 12)
            }

            HStack(spacing: 8) {
                DownloadStatusIcon(songId: song.id)
                Text(song.durationString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.trailing, 24)
        }
        .frame(height: 52)
        .background {
            Color(NSColor.windowBackgroundColor)
            if isHovered {
                Color.primary.opacity(0.07)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { onPlay() })
        .contextMenu {
            Button(String(localized: "play")) { onPlay() }
            if showInstantMixActions && !offlineMode.isOffline {
                Button(String(localized: "instant_mix")) {
                    InstantMixService.playSongMix(for: song)
                }
            }
            Divider()
            Button(String(localized: "play_next")) { onPlayNext() }
            Button(String(localized: "add_to_queue")) { onAddToQueue() }
            Divider()
            Button(String(localized: "remove_from_playlist"), role: .destructive) {
                onRemoveFromPlaylist()
            }
            if showFavorite || showPlaylist {
                Divider()
                if showFavorite {
                    Button(isStarred
                           ? String(localized: "remove_from_favorites")
                           : String(localized: "add_to_favorites")) {
                        onFavorite()
                    }
                }
                if showPlaylist {
                    Button(String(localized: "add_to_playlist")) {
                        onAddToPlaylist()
                    }
                }
            }
        }
    }
}

struct PlaylistTracksList: View {
    let playlist: Playlist
    @Binding var songs: [Song]
    var displaySongs: [Song]? = nil
    let isLoading: Bool
    let isEditMode: Bool
    let enableFavorites: Bool
    let enablePlaylists: Bool
    let themeColor: Color
    let currentSongId: String?
    @ObservedObject var libraryStore: LibraryViewModel
    var originalRanks: [String: Int] = [:]
    let onPlayAt: (Int) -> Void
    let onPlayNext: (Song) -> Void
    let onAddToQueue: (Song) -> Void
    let onRemoveAt: (Int) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onDelete: (IndexSet) -> Void

    private var tracksToShow: [Song] { displaySongs ?? songs }

    var body: some View {
        if isLoading {
            ProgressView(String(localized: "loading_tracks"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(true)
                .deleteDisabled(true)
        } else if songs.isEmpty {
            ContentUnavailableView(
                String(localized: "empty_playlist"),
                systemImage: "music.note.list",
                description: Text(String(localized: "add_songs_to_this_playlist"))
            )
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .deleteDisabled(true)
        } else if tracksToShow.isEmpty {
            ContentUnavailableView(
                String(localized: "no_results"),
                systemImage: "magnifyingglass"
            )
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
            .deleteDisabled(true)
        } else {
            Section {
                ForEach(Array(tracksToShow.enumerated()), id: \.element.id) { index, song in
                    PlaylistTrackRow(
                        song: song,
                        trackNumber: originalRanks[song.id] ?? (index + 1),
                        isPlaying: currentSongId == song.id,
                        showFavorite: enableFavorites,
                        showPlaylist: enablePlaylists,
                        isStarred: libraryStore.isSongStarred(song),
                        themeColor: themeColor,
                        isEditMode: isEditMode,
                        canMoveUp: index > 0,
                        canMoveDown: index < tracksToShow.count - 1,
                        onPlay: { onPlayAt(index) },
                        onPlayNext: { onPlayNext(song) },
                        onAddToQueue: { onAddToQueue(song) },
                        onFavorite: { Task { await libraryStore.toggleStarSong(song) } },
                        onAddToPlaylist: {
                            NotificationCenter.default.post(name: .addSongsToPlaylist, object: [song.id])
                        },
                        onRemoveFromPlaylist: { onRemoveAt(index) },
                        onMoveUp: { onMove(IndexSet(integer: index), index - 1) },
                        onMoveDown: { onMove(IndexSet(integer: index), index + 2) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .onMove(perform: isEditMode ? onMove : nil)
                .onDelete(perform: isEditMode ? onDelete : nil)
            }
        }
    }
}
