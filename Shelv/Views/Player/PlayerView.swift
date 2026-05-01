import SwiftUI
import AVKit

struct PlayerView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @ObservedObject var libraryStore = LibraryStore.shared
    @EnvironmentObject var lyricsStore: LyricsStore
    @ObservedObject private var offlineMode = OfflineModeService.shared
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
    // Amperfy-style: blurred artwork + dominant color gradient
    @State private var playerBgColor: Color = Color(UIColor.systemBackground)
    @State private var playerImage: UIImage?

    private var currentAlbum: Album? {
        guard let song = player.currentSong, let albumId = song.albumId else { return nil }
        return Album(
            id: albumId, name: song.album ?? "", artist: song.artist, artistId: nil,
            coverArt: song.coverArt, songCount: nil, duration: nil, year: song.year,
            genre: song.genre, playCount: nil, starred: nil, created: nil, songs: nil
        )
    }

    private var currentArtist: Artist? {
        guard let name = player.currentSong?.artist else { return nil }
        return libraryStore.artists.first { $0.name == name }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func artSize(_ h: CGFloat) -> CGFloat { isPad ? min(380, max(240, h * 0.42)) : 280 }
    private func playButtonSize(_ h: CGFloat) -> CGFloat { isPad ? min(96, max(72, h * 0.11)) : 72 }
    private func controlSize(_ h: CGFloat) -> CGFloat { isPad ? min(56, max(44, h * 0.065)) : 44 }
    private func vPad(_ h: CGFloat, large: CGFloat, small: CGFloat) -> CGFloat {
        guard isPad else { return small }
        return h < 760 ? max(small * 0.6, large * 0.5) : large
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let h = geo.size.height
                let art = artSize(h)
                let play = playButtonSize(h)
                let ctrl = controlSize(h)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    AlbumArtView(coverArtId: player.currentSong?.coverArt, size: 600, cornerRadius: isPad ? 22 : 20)
                        .frame(width: art, height: art)
                        .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
                        .padding(.bottom, vPad(h, large: 20, small: 28))

                    VStack(spacing: isPad ? 6 : 8) {
                        Text(player.displayTitle)
                            .font(isPad ? .title : .title2).bold()
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 24)

                        if let artistName = player.currentSong?.artist {
                            Button { resolveArtist(artistName) } label: {
                                Text(artistName)
                                    .font(isPad ? .title2 : .title3)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .navigationDestination(item: $artistDestination) { artist in
                                ArtistDetailView(artist: artist)
                                    .toolbarBackground(.visible, for: .navigationBar)
                            }
                        }

                        if let album = currentAlbum {
                            NavigationLink(destination: AlbumDetailView(album: album)
                                .toolbarBackground(.visible, for: .navigationBar)
                            ) {
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

                    Spacer(minLength: 0)

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
                            Text(formatTime(isDragging ? seekValue * displayDuration : displayTime))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                            Text(formatTime(displayDuration))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }

                        if let badge = audioBadge {
                            Text(badge)
                                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, isPad ? 48 : 32)
                    .padding(.bottom, vPad(h, large: 24, small: 32))

                    // Transport-Buttons
                    HStack(spacing: isPad ? 28 : 22) {
                        Image(systemName: "shuffle")
                            .font(.system(size: isPad ? 22 : 19, weight: .semibold))
                            .foregroundStyle(player.isShuffled ? accentColor : .secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .onTapGesture { player.toggleShuffle() }

                        Image(systemName: "backward.fill")
                            .font(.system(size: isPad ? 28 : 24))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .onTapGesture { player.previous() }

                        Button { player.togglePlayPause() } label: {
                            ZStack {
                                Circle().fill(accentColor).frame(width: play, height: play)
                                if player.isBuffering {
                                    ProgressView().tint(.white).scaleEffect(1.2)
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: isPad ? 34 : 30)).foregroundStyle(.white)
                                }
                            }
                            .shadow(color: accentColor.opacity(0.4), radius: 12, y: 6)
                        }
                        .buttonStyle(.plain)

                        Image(systemName: "forward.fill")
                            .font(.system(size: isPad ? 28 : 24))
                            .foregroundStyle(player.hasNextTrack ? Color.primary : Color.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .onTapGesture { player.next(triggeredByUser: true) }
                            .disabled(!player.hasNextTrack)

                        Image(systemName: player.repeatMode.systemImage)
                            .font(.system(size: isPad ? 22 : 19, weight: .semibold))
                            .foregroundStyle(player.repeatMode != .off ? accentColor : .secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .onTapGesture { player.cycleRepeatMode() }
                    }
                    .padding(.bottom, vPad(h, large: 36, small: 20))

                    // Sekundäre Buttons — Amperfy-Stil: grauer Kreis, .primary Icon
                    HStack {
                        if enableFavorites && !offlineMode.isOffline, let song = player.currentSong {
                            Button {
                                Task { await libraryStore.toggleStarSong(song) }
                            } label: {
                                playerSecondaryButton(
                                    icon: libraryStore.isSongStarred(song) ? "heart.fill" : "heart",
                                    color: libraryStore.isSongStarred(song) ? Color.pink : Color.primary,
                                    size: ctrl, isPad: isPad
                                )
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }

                        Button { showLyricsSheet = true } label: {
                            playerSecondaryButton(icon: "quote.bubble", color: .primary, size: ctrl, isPad: isPad)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button { showQueue = true } label: {
                            playerSecondaryButton(icon: "list.bullet", color: .primary, size: ctrl, isPad: isPad)
                        }
                        .buttonStyle(.plain)

                        if enablePlaylists && !offlineMode.isOffline {
                            Spacer()
                            Button { showAddToPlaylist = true } label: {
                                playerSecondaryButton(icon: "music.note.list", color: .primary, size: ctrl, isPad: isPad)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button { player.stop(); dismiss() } label: {
                            playerSecondaryButton(icon: "stop.fill", color: .primary, size: ctrl, isPad: isPad)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, isPad ? 44 : 36)
                    .padding(.bottom, vPad(h, large: 32, small: 40))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background {
                    // Amperfy-Stil: stark geblurrtes Cover + Verlauf dominant→systemBackground
                    ZStack {
                        Color(UIColor.systemBackground)
                        if let img = playerImage {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .blur(radius: 50, opaque: true)
                        }
                        LinearGradient(
                            colors: [playerBgColor, Color(UIColor.systemBackground)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .opacity(0.80)
                    }
                    .ignoresSafeArea()
                }
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
                    else { lyricsStore.currentLyrics = nil; lyricsStore.isLoadingLyrics = false; return }
                    lyricsStore.loadLyrics(for: song, serverId: serverId)
                }
                .task(id: player.currentSong?.coverArt) {
                    await updatePlayerBackground()
                }
                .onReceive(player.timePublisher) { update in
                    guard !isDragging, !player.isSeeking else { return }
                    displayTime = update.time
                    displayDuration = update.duration
                }
                .onAppear { displayTime = player.currentTime; displayDuration = player.duration }
                .onDisappear { artistResolveTask?.cancel(); artistResolveTask = nil }
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
    }

    @ViewBuilder
    private func playerSecondaryButton(icon: String, color: Color, size: CGFloat, isPad: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: isPad ? 22 : 20, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }

    private func updatePlayerBackground() async {
        guard let coverArtId = player.currentSong?.coverArt else {
            withAnimation(.easeInOut(duration: 0.5)) {
                playerBgColor = Color(UIColor.systemBackground)
                playerImage = nil
            }
            return
        }

        let cached: UIImage? = ImageCacheService.shared.cachedImage(key: "\(coverArtId)_600")
            ?? ImageCacheService.shared.cachedImage(key: "\(coverArtId)_300")

        let resolved: UIImage?
        if let cached {
            resolved = cached
        } else if let url = SubsonicAPIService.shared.coverArtURL(for: coverArtId, size: 80) {
            resolved = await ImageCacheService.shared.image(url: url, key: "\(coverArtId)_80")
        } else {
            resolved = nil
        }

        guard !Task.isCancelled, let image = resolved else { return }
        let color = image.playerDominantColor()
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.5)) { playerBgColor = color }
        playerImage = image
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
                   let found = result.artist?.first(where: { $0.name.lowercased() == artistName.lowercased() })
                    ?? result.artist?.first {
                    guard !Task.isCancelled else { return }
                    artistDestination = found
                }
            }
        }
    }

    private var audioBadge: String? {
        if let actual = player.actualStreamFormat { return actual.displayString }
        guard let song = player.currentSong else { return nil }
        var parts: [String] = []
        if let suffix = song.suffix { parts.append(suffix.uppercased()) }
        if let bitRate = song.bitRate { parts.append("\(bitRate) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
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

private extension UIImage {
    // Extrahiert die dominante Farbe für den Player-Hintergrundverlauf (Amperfy-Stil)
    func playerDominantColor() -> Color {
        let size = CGSize(width: 16, height: 16)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImage = small.cgImage else { return Color(UIColor.systemBackground) }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        guard let ctx = CGContext(
            data: &pixels, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Color(UIColor.systemBackground) }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let n: CGFloat = 256
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r += CGFloat(pixels[i]) / 255
            g += CGFloat(pixels[i + 1]) / 255
            b += CGFloat(pixels[i + 2]) / 255
        }
        let avg = UIColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        // Sättigung leicht boosten, Helligkeit fast original lassen — vivid wie bei Amperfy
        return Color(UIColor(hue: h, saturation: min(s * 1.2, 1.0), brightness: min(v * 1.05, 1.0), alpha: 1))
    }
}
