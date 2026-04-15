import SwiftUI

struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject var player: AudioPlayerService
    @EnvironmentObject var libraryStore: LibraryStore
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true

    @State private var detail: ArtistDetail?
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    AlbumArtView(coverArtId: artist.coverArt, size: 300, cornerRadius: 50)
                        .frame(width: 100, height: 100)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artist.name)
                            .font(.title2).bold()
                        if let count = artist.albumCount {
                            Text("\(count) \(tr("Albums", "Alben"))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                guard let albums = detail?.album, !albums.isEmpty else { return }
                                Task {
                                    let songs = await fetchAllSongs(from: albums)
                                    guard !songs.isEmpty else { return }
                                    player.play(songs: songs, startIndex: 0)
                                }
                            } label: {
                                Label(tr("Play", "Abspielen"), systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(accentColor)
                            .disabled(isLoading)

                            Button {
                                guard let albums = detail?.album, !albums.isEmpty else { return }
                                Task {
                                    let songs = await fetchAllSongs(from: albums)
                                    guard !songs.isEmpty else { return }
                                    player.playShuffled(songs: songs)
                                }
                            } label: {
                                Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(accentColor)
                            .disabled(isLoading)
                        }
                    }
                }
                .padding(.horizontal)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let albums = detail?.album, !albums.isEmpty {
                    Text(tr("Albums", "Alben"))
                        .font(.title3).bold()
                        .padding(.horizontal)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCardView(album: album, showArtist: false, showYear: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, player.currentSong != nil ? 90 : 16)
                }
            }
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if enableFavorites {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await libraryStore.toggleStarArtist(artist) }
                    } label: {
                        Image(systemName: libraryStore.isArtistStarred(artist) ? "heart.fill" : "heart")
                            .foregroundStyle(libraryStore.isArtistStarred(artist) ? accentColor : .secondary)
                    }
                }
            }
        }
        .task {
            await loadDetail()
        }
    }

    private func loadDetail() async {
        isLoading = true
        do {
            detail = try await SubsonicAPIService.shared.getArtist(id: artist.id)
        } catch {}
        isLoading = false
    }

    private func fetchAllSongs(from albums: [Album]) async -> [Song] {
        await withTaskGroup(of: [Song].self) { group in
            for album in albums {
                group.addTask {
                    guard let detail = try? await SubsonicAPIService.shared.getAlbum(id: album.id),
                          let songs = detail.song else { return [] }
                    return songs
                }
            }
            var all: [Song] = []
            for await albumSongs in group { all.append(contentsOf: albumSongs) }
            return all
        }
    }
}
