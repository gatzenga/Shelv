import SwiftUI
import AVKit

struct PlayerView: View {
    @ObservedObject var player = AudioPlayerService.shared
    @EnvironmentObject var libraryStore: LibraryStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var seekValue: Double = 0
    @State private var isDragging: Bool = false
    @State private var showQueue: Bool = false
    @State private var artistDestination: Artist?
    @State private var isResolvingArtist = false

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
            songs: nil
        )
    }

    private var currentArtist: Artist? {
        guard let name = player.currentSong?.artist else { return nil }
        return libraryStore.artists.first { $0.name == name }
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    private var artSize: CGFloat { isRegularWidth ? 380 : 280 }
    private var playButtonSize: CGFloat { isRegularWidth ? 90 : 72 }
    private var controlSize: CGFloat { isRegularWidth ? 56 : 44 }

    var body: some View {
        NavigationStack {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Capsule()
                    .fill(Color.gray.opacity(0.4))
                    .frame(width: 40, height: 5)

                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)

            Spacer()

            AlbumArtView(coverArtId: player.currentSong?.coverArt, size: 600, cornerRadius: 20)
                .frame(width: artSize, height: artSize)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 15)
                .padding(.bottom, 28)

            VStack(spacing: 8) {
                Text(player.currentSong?.title ?? tr("Unknown Title", "Titel unbekannt"))
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)

                if let artistName = player.currentSong?.artist {
                    Button {
                        if isResolvingArtist { return }
                        if let found = currentArtist {
                            artistDestination = found
                        } else {
                            isResolvingArtist = true
                            Task {
                                if let result = try? await SubsonicAPIService.shared.search(query: artistName),
                                   let found = result.artist?.first(where: {
                                       $0.name.lowercased() == artistName.lowercased()
                                   }) ?? result.artist?.first {
                                    artistDestination = found
                                }
                                isResolvingArtist = false
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(artistName)
                                .font(.title3)
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
                    }
                }

                if let album = currentAlbum {
                    NavigationLink(destination: AlbumDetailView(album: album)) {
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

            VStack(spacing: 4) {
                Slider(
                    value: (isDragging || player.isSeeking) ? $seekValue : Binding(
                        get: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                        set: { _ in }
                    ),
                    in: 0...1
                ) { editing in
                    if editing {
                        isDragging = true
                        player.isSeeking = true
                        seekValue = player.duration > 0 ? player.currentTime / player.duration : 0
                    } else {
                        player.seek(to: seekValue * player.duration)
                        isDragging = false
                    }
                }
                .tint(accentColor)

                HStack {
                    Text(formatTime(player.currentTime))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(formatTime(player.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, isRegularWidth ? 60 : 32)
            .padding(.bottom, 28)

            HStack(spacing: isRegularWidth ? 44 : 32) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: isRegularWidth ? 30 : 24))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

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
                                .font(.system(size: isRegularWidth ? 38 : 30))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: accentColor.opacity(0.4), radius: 12, y: 6)
                }
                .buttonStyle(.plain)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: isRegularWidth ? 30 : 24))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 20)

            GeometryReader { geo in
                HStack {
                    ZStack {
                        Circle()
                            .fill(player.isAirPlayActive
                                  ? accentColor.opacity(0.2)
                                  : Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                            .frame(width: controlSize, height: controlSize)
                        AirPlayButton(tintColor: UIColor(accentColor), activeTintColor: UIColor(accentColor))
                            .frame(width: isRegularWidth ? 32 : 26, height: isRegularWidth ? 32 : 26)
                    }

                    Spacer()

                    Button {
                        showQueue = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                                .frame(width: controlSize, height: controlSize)
                            Image(systemName: "list.bullet")
                                .font(.system(size: isRegularWidth ? 20 : 16))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .buttonStyle(.plain)

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
                                .font(.system(size: isRegularWidth ? 22 : 18))
                                .foregroundStyle(accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, isRegularWidth ? 52 : 36)
            }
            .frame(height: controlSize)
            .padding(.bottom, isRegularWidth ? 50 : 40)
        }
        .background(Color(UIColor.systemBackground))
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(24)
                .tint(accentColor)
        }
        } // NavigationStack
        .navigationBarHidden(true)
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
