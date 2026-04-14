import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var libraryStore: LibraryStore
    @EnvironmentObject var player: AudioPlayerService
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var mixLoading: String?
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if libraryStore.isLoadingDiscover && libraryStore.recentlyAdded.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else {
                        VStack(spacing: 12) {
                            mixButton(
                                title: tr("Mix: Newest Tracks", "Mix: Neueste Titel"),
                                icon: "sparkles",
                                key: "newest"
                            ) { await loadMix(type: "newest") }

                            mixButton(
                                title: tr("Mix: Frequently Played", "Mix: Häufig gespielt"),
                                icon: "chart.bar.fill",
                                key: "frequent"
                            ) { await loadMix(type: "frequent") }

                            mixButton(
                                title: tr("Mix: Recently Played", "Mix: Kürzlich gespielt"),
                                icon: "clock.fill",
                                key: "recent"
                            ) { await loadMix(type: "recent") }
                        }
                        .padding(.horizontal)

                        albumSection(
                            title: tr("Recently Added", "Kürzlich hinzugefügt"),
                            albums: libraryStore.recentlyAdded
                        )
                        albumSection(
                            title: tr("Recently Played", "Kürzlich gespielt"),
                            albums: libraryStore.recentlyPlayed
                        )
                        albumSection(
                            title: tr("Frequently Played", "Häufig gespielt"),
                            albums: libraryStore.frequentlyPlayed
                        )

                        Color.clear.frame(height: player.currentSong != nil ? 90 : 16)
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Shelv")
            .refreshable {
                await libraryStore.loadDiscover()
            }
            .task {
                if libraryStore.recentlyAdded.isEmpty {
                    await libraryStore.loadDiscover()
                }
            }
            .alert(tr("Error", "Fehler"), isPresented: $showError, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private func albumSection(title: String, albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title3).bold()
                    .padding(.horizontal)

                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(album: album, fixedSize: 140, showArtist: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private func mixButton(
        title: String,
        icon: String,
        key: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                mixLoading = key
                await action()
                mixLoading = nil
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .font(.body)
                    .frame(width: 28)
                Text(title)
                    .font(.body).bold()
                Spacer()
                if mixLoading == key {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(mixLoading != nil)
    }

    private func loadMix(type: String) async {
        do {
            let songs: [Song]
            switch type {
            case "newest":   songs = try await SubsonicAPIService.shared.getNewestSongs()
            case "frequent": songs = try await SubsonicAPIService.shared.getFrequentSongs(limit: 100)
            default:         songs = try await SubsonicAPIService.shared.getRecentSongs(limit: 100)
            }
            player.play(songs: songs.shuffled(), startIndex: 0)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
