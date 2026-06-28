import SwiftUI

struct PlayerBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var libraryStore = LibraryViewModel.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject private var player = AudioPlayerService.shared

    private var audioBadge: String? {
        player.actualStreamFormat?.displayString
    }
    @Environment(\.themeColor) private var themeColor
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @State private var isDragging: Bool = false
    @State private var dragValue: Double = 0
    // currentTime ist kein @Published → das Zeit-Label/der Slider werden über den
    // timePublisher gespeist. Ohne das friert die Anzeige ein (z.B. nach einem Seek),
    // obwohl der Ton normal weiterläuft.
    @State private var displayTime: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                HStack(spacing: 14) {
                    Group {
                        if let song = player.currentSong, let coverID = song.coverArt,
                           let url = SubsonicAPIService.shared.coverArtURL(id: coverID, size: 120) {
                            CoverArtView(url: url, size: 62, cornerRadius: 8)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.secondary.opacity(0.15))
                                Image(systemName: "music.note")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 62, height: 62)
                        }
                    }

                    if let song = player.currentSong {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.title)
                                .font(.body.bold())
                                .lineLimit(1)
                            HStack(spacing: 0) {
                                if let id = song.artistId, let name = song.artist {
                                    Button(name) {
                                        appState.selectedPlaylist = nil
                                        appState.selectedSidebar = .artists
                                        appState.navigationPath = NavigationPath()
                                        appState.navigationPath.append(
                                            Artist(id: id, name: name, albumCount: nil, coverArt: nil, starred: nil)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(themeColor)
                                    .onHover { inside in
                                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                    }
                                } else if let name = song.artist {
                                    Text(name).foregroundStyle(.secondary)
                                }
                                if song.artist != nil && song.album != nil {
                                    Text(" · ").foregroundStyle(.secondary)
                                }
                                if let id = song.albumId, let name = song.album {
                                    Button(name) {
                                        appState.selectedPlaylist = nil
                                        appState.selectedSidebar = .albums
                                        appState.navigationPath = NavigationPath()
                                        appState.navigationPath.append(
                                            Album(id: id, name: name, artist: song.artist,
                                                  artistId: song.artistId, coverArt: song.coverArt)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(themeColor)
                                    .onHover { inside in
                                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                                    }
                                } else if let name = song.album {
                                    Text(name).foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                            .lineLimit(1)
                        }
                    } else {
                        Text(String(localized: "no_track"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)

                VStack(spacing: 10) {
                    HStack(spacing: 22) {
                        Group {
                            if enablePlaylists, let song = player.currentSong {
                                Button {
                                    NotificationCenter.default.post(name: .addSongsToPlaylist, object: [song.id])
                                } label: {
                                    Image(systemName: "music.note.list")
                                        .foregroundStyle(AnyShapeStyle(.primary.opacity(0.35)))
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "add_to_playlist"))
                            } else {
                                Image(systemName: "music.note.list")
                                    .hidden()
                            }
                        }
                        .font(.title2)

                        Button { player.toggleShuffle() } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.isShuffled ? AnyShapeStyle(themeColor) : AnyShapeStyle(.primary.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .help(player.isShuffled ? String(localized: "shuffle_off") : String(localized: "shuffle_on"))

                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .disabled(player.queue.isEmpty)

                        Button { player.togglePlayPause() } label: {
                            ZStack {
                                Circle().fill(themeColor)
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .foregroundStyle(.white)
                                    .font(.system(size: 17, weight: .semibold))
                                    .offset(x: player.isPlaying ? 0 : 1.5)
                            }
                            .frame(width: 46, height: 46)
                        }
                        .buttonStyle(.plain)
                        .disabled(player.currentSong == nil)

                        Button { player.next(triggeredByUser: true) } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .disabled(player.repeatMode == .off
                            && player.currentIndex >= player.queue.count - 1
                            && player.playNextQueue.isEmpty
                            && player.userQueue.isEmpty)

                        Button { player.cycleRepeatMode() } label: {
                            Image(systemName: player.repeatMode.systemImage)
                                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary.opacity(0.35)) : AnyShapeStyle(themeColor))
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                        .help(repeatHelpText)

                        Group {
                            if enableFavorites, let song = player.currentSong {
                                let isStarred = libraryStore.isSongStarred(song)
                                Button {
                                    Task {
                                        await libraryStore.toggleStarSong(song)
                                        player.setCurrentSongStarred(!isStarred)
                                    }
                                } label: {
                                    Image(systemName: isStarred ? "heart.fill" : "heart")
                                        .foregroundStyle(isStarred ? AnyShapeStyle(themeColor) : AnyShapeStyle(.primary.opacity(0.35)))
                                }
                                .buttonStyle(.plain)
                                .help(isStarred
                                      ? String(localized: "remove_from_favorites")
                                      : String(localized: "add_to_favorites"))
                            } else {
                                Image(systemName: "heart")
                                    .hidden()
                            }
                        }
                        .font(.title2)
                    }

                    HStack(spacing: 10) {
                        Text(formatTime(isDragging ? dragValue : displayTime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)

                        Slider(
                            value: Binding(
                                get: { isDragging ? dragValue : displayTime },
                                set: { newVal in dragValue = newVal }
                            ),
                            in: 0...max(player.duration, 1)
                        ) { editing in
                            if editing {
                                isDragging = true
                            } else {
                                player.seek(to: dragValue)
                                displayTime = dragValue
                                isDragging = false
                            }
                        }
                        .frame(maxWidth: 360)
                        .disabled(player.currentSong == nil || player.duration <= 0)

                        Text(formatTime(player.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 42, alignment: .leading)
                    }
                }
                .frame(maxWidth: 560)

                HStack(spacing: 16) {
                    HStack(spacing: 5) {
                        if player.showBufferingIndicator {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 14, height: 14)
                        }
                        Text(player.showBufferingIndicator ? String(localized: "loading_2") : (audioBadge ?? ""))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
                    .padding(.trailing, 8)

                    Button { appState.togglePanel(.queue) } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 16))
                            .foregroundStyle(appState.activePanel == .queue ? themeColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .help(String(localized: "queue"))

                    Button { appState.togglePanel(.lyrics) } label: {
                        Image(systemName: "text.quote")
                            .font(.system(size: 16))
                            .foregroundStyle(appState.activePanel == .lyrics ? themeColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20, height: 20)
                    .help(String(localized: "lyrics"))

                    AVRoutePickerViewRepresentable()
                        .frame(width: 20, height: 20)
                        .help(String(localized: "airplay"))

                    Image(systemName: player.volume < 0.01 ? "speaker.slash.fill"
                                    : player.volume < 0.5  ? "speaker.wave.1.fill"
                                                           : "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                    Slider(value: Binding(
                        get: { Double(player.volume) },
                        set: { player.volume = Float($0) }
                    ), in: 0...1)
                    .frame(width: 100)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 20)
            }
            .frame(height: 100)
        }
        .background(.bar)
        .onReceive(player.timePublisher) { update in
            guard !isDragging else { return }
            displayTime = update.time
        }
        .onAppear { displayTime = player.currentTime }
        .onChange(of: player.currentSong?.id) { _, _ in displayTime = player.currentTime }
    }

    private var repeatHelpText: String {
        switch player.repeatMode {
        case .off: return String(localized: "repeat_off")
        case .all: return String(localized: "repeat_all")
        case .one: return String(localized: "repeat_one")
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

}

#Preview {
    PlayerBarView()
        .environmentObject(AppState.shared)
        .environmentObject(LibraryViewModel())
        .frame(width: 1000)
}
