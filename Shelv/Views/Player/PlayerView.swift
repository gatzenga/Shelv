import SwiftUI
import AVKit

struct PlayerView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var lyricsStore: LyricsStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true

    @State private var seekValue: Double = 0
    @State private var isDragging: Bool = false
    @State private var displayTime: Double = 0
    @State private var displayDuration: Double = 0
    @State private var showQueue: Bool = false
    @State private var showAddToPlaylist = false
    @State private var showLyricsSheet: Bool = false
    @State private var artistDestination: Artist?
    @State private var isResolvingArtist = false
    @State private var artistResolveTask: Task<Void, Never>?

    private var currentAlbum: Album? {
        guard let song = player.currentSong, let albumId = song.albumId else { return nil }
        return Album(
            id: albumId,
            name: song.album ?? "",
            artist: song.artist,
            artistId: nil,
            coverArt: song.coverArt,
            songCount: nil,
            duration: nil,
            year: song.year,
            genre: song.genre,
            playCount: nil,
            starred: nil,
            songs: nil
        )
    }

    private var currentArtist: Artist? {
        guard let name = player.currentSong?.artist else { return nil }
        return libraryStore.artists.first { $0.name == name }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var artSize: CGFloat { isPad ? 380 : 280 }
    private var playButtonSize: CGFloat { isPad ? 96 : 72 }
    private var controlSize: CGFloat { isPad ? 56 : 44 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // Album Art
                AlbumArtView(coverArtId: player.currentSong?.coverArt, size: 600, cornerRadius: isPad ? 22 : 20)
                    .frame(width: artSize, height: artSize)
                    .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
                    .padding(.bottom, isPad ? 20 : 28)

                // Titel / Künstler / Album
                VStack(spacing: isPad ? 6 : 8) {
                    Text(player.displayTitle)
                        .font(isPad ? .title : .title2).bold()
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)

                    if let artistName = player.currentSong?.artist {
                        Button { resolveArtist(artistName) } label: {
                            HStack(spacing: 6) {
                                Text(artistName)
                                    .font(isPad ? .title2 : .title3)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if isResolvingArtist {
                                    ProgressView().scaleEffect(0.7)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .navigationDestination(item: $artistDestination) { artist in
                            ArtistDetailView(artist: artist)
                                .toolbarBackground(.visible, for: .navigationBar)
                        }
                    }

                    if let album = currentAlbum {
                        NavigationLink(destination: AlbumDetailView(album: album).toolbarBackground(.visible, for: .navigationBar)) {
                            Text(album.name)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    } else if let albumName = player.currentSong?.album {
                        Text(albumName)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Seek-Slider
                VStack(spacing: 4) {
                    Slider(
                        value: (isDragging || player.isSeeking) ? $seekValue : Binding(
                            get: { displayDuration > 0 ? displayTime / displayDuration : 0 },
                            set: { _ in }
                        ),
                        in: 0...1
                    ) { editing in
                        if editing {
                            isDragging = true
                            seekValue = displayDuration > 0 ? displayTime / displayDuration : 0
                        } else {
                            let seconds = seekValue * displayDuration
                            displayTime = seconds
                            player.seek(to: seconds)
                            isDragging = false
                        }
                    }
                    .tint(accentColor)

                    HStack {
                        Text(formatTime(displayTime))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Text(formatTime(displayDuration))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if let badge = audioBadge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, isPad ? 48 : 32)
                .padding(.bottom, isPad ? 24 : 32)

                // Shuffle / Prev / Play / Next / Repeat
                HStack(spacing: isPad ? 28 : 22) {
                    Image(systemName: "shuffle")
                        .font(.system(size: isPad ? 22 : 19, weight: .semibold))
                        .foregroundStyle(player.isShuffled ? accentColor : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { player.toggleShuffle() }

                    Image(systemName: "backward.fill")
                        .font(.system(size: isPad ? 28 : 24))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { player.previous() }

                    Button { player.togglePlayPause() } label: {
                        ZStack {
                            Circle()
                                .fill(accentColor)
                                .frame(width: playButtonSize, height: playButtonSize)
                            if player.isBuffering {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(1.2)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: isPad ? 34 : 30))
                                    .foregroundStyle(.white)
                            }
                        }
                        .shadow(color: accentColor.opacity(0.4), radius: 12, y: 6)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "forward.fill")
                        .font(.system(size: isPad ? 28 : 24))
                        .foregroundStyle(player.hasNextTrack ? Color.primary : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { player.next(triggeredByUser: true) }
                        .disabled(!player.hasNextTrack)

                    Image(systemName: player.repeatMode.systemImage)
                        .font(.system(size: isPad ? 22 : 19, weight: .semibold))
                        .foregroundStyle(player.repeatMode != .off ? accentColor : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture { player.repeatMode = player.repeatMode.toggled }
                }
                .padding(.bottom, isPad ? 36 : 20)

                HStack {
                    if enableFavorites, let song = player.currentSong {
                        Button {
                            Task { await libraryStore.toggleStarSong(song) }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                                    .frame(width: controlSize, height: controlSize)
                                Image(systemName: libraryStore.isSongStarred(song) ? "heart.fill" : "heart")
                                    .font(.system(size: isPad ? 20 : 18))
                                    .foregroundStyle(libraryStore.isSongStarred(song) ? accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }

                    Button {
                        showLyricsSheet = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                                .frame(width: controlSize, height: controlSize)
                            Image(systemName: "quote.bubble")
                                .font(.system(size: isPad ? 18 : 16))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        showQueue = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                                .frame(width: controlSize, height: controlSize)
                            Image(systemName: "list.bullet")
                                .font(.system(size: isPad ? 18 : 16))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .buttonStyle(.plain)

                    if enablePlaylists {
                        Spacer()

                        Button {
                            showAddToPlaylist = true
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                                    .frame(width: controlSize, height: controlSize)
                                Image(systemName: "music.note.list")
                                    .font(.system(size: isPad ? 18 : 16))
                                    .foregroundStyle(accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button {
                        player.stop()
                        dismiss()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                                .frame(width: controlSize, height: controlSize)
                            Image(systemName: "stop.fill")
                                .font(.system(size: isPad ? 20 : 18))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, isPad ? 44 : 36)
                .padding(.bottom, isPad ? 32 : 40)
            }
            .background(Color(UIColor.systemBackground))
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AirPlayButton(tintColor: .label, activeTintColor: UIColor(accentColor))
                        .frame(width: 34, height: 34)
                }
            }
            .navigationDestination(isPresented: $showLyricsSheet) {
                LyricsSheetView()
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .onChange(of: player.currentSong?.id) { _, _ in
                artistDestination = nil
                artistResolveTask?.cancel()
                artistResolveTask = nil
                isResolvingArtist = false
            }
            .task(id: player.currentSong?.id) {
                guard autoFetchLyrics,
                      let song = player.currentSong,
                      let serverId = SubsonicAPIService.shared.activeServer?.id.uuidString
                else {
                    lyricsStore.currentLyrics = nil
                    lyricsStore.isLoadingLyrics = false
                    return
                }
                lyricsStore.loadLyrics(for: song, serverId: serverId)
            }
            .onReceive(player.timePublisher) { update in
                guard !isDragging, !player.isSeeking else { return }
                displayTime = update.time
                displayDuration = update.duration
            }
            .onAppear {
                displayTime = player.currentTime
                displayDuration = player.duration
            }
            .onDisappear {
                artistResolveTask?.cancel()
                artistResolveTask = nil
            }
            .sheet(isPresented: $showQueue) {
                QueueView()
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .sheet(isPresented: $showAddToPlaylist) {
                if let song = player.currentSong {
                    AddToPlaylistSheet(songIds: [song.id])
                        .environmentObject(libraryStore)
                        .tint(accentColor)
                }
            }
        }
    }

    private func resolveArtist(_ artistName: String) {
        if let found = currentArtist {
            artistDestination = found
        } else if !isResolvingArtist {
            isResolvingArtist = true
            artistResolveTask?.cancel()
            artistResolveTask = Task {
                defer { isResolvingArtist = false }
                guard !Task.isCancelled else { return }
                if let result = try? await SubsonicAPIService.shared.search(query: artistName),
                   let found = result.artist?.first(where: {
                       $0.name.lowercased() == artistName.lowercased()
                   }) ?? result.artist?.first {
                    guard !Task.isCancelled else { return }
                    artistDestination = found
                }
            }
        }
    }

    private var audioBadge: String? {
        guard let song = player.currentSong else { return nil }
        var parts: [String] = []
        if let suffix = song.suffix { parts.append(suffix.uppercased()) }
        if let bitRate = song.bitRate { parts.append("\(bitRate) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .label
    var activeTintColor: UIColor = .systemBlue

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tintColor
        picker.activeTintColor = activeTintColor
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
        uiView.activeTintColor = activeTintColor
    }
}
