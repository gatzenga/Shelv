import SwiftUI

struct AlbumDetailView: View {
    let album: Album
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("enablePlaylists") private var enablePlaylists = true
    @AppStorage("enableDownloads") private var enableDownloads = false

    @State private var detail: AlbumDetail?
    @State private var albumPlaylistIds: AlbumPlaylistIds?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var currentToast: ShelveToast?
    @State private var artistDestination: Artist?
    @State private var isResolvingArtist = false
    @State private var artistResolveTask: Task<Void, Never>?
    @State private var searchQuery = ""
    @State private var showDeleteAlbumDownloadConfirm = false

    private var showPerSongArtist: Bool {
        Set((detail?.song ?? []).compactMap(\.artist)).count > 1
    }

    private var displayedSongs: [Song] {
        let all = detail?.song ?? []
        guard !searchQuery.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery)
                || ($0.artist?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
    }

    private var discGroups: [(disc: Int, songs: [Song])] {
        let all = detail?.song ?? []
        let discNumbers = Set(all.compactMap(\.discNumber))
        guard discNumbers.count >= 2 else { return [] }
        let sorted = all.sorted {
            let d0 = $0.discNumber ?? 1, d1 = $1.discNumber ?? 1
            if d0 != d1 { return d0 < d1 }
            return ($0.track ?? 0) < ($1.track ?? 0)
        }
        let grouped = Dictionary(grouping: sorted) { $0.discNumber ?? 1 }
        return grouped.keys.sorted().map { disc in (disc: disc, songs: grouped[disc]!) }
    }

    private var useDiscGrouping: Bool {
        guard searchQuery.isEmpty, let all = detail?.song else { return false }
        return Set(all.compactMap(\.discNumber)).count >= 2
    }

    private var currentArtist: Artist? {
        guard let name = album.artist else { return nil }
        return libraryStore.artists.first { $0.name == name }
    }

    var body: some View {
        List {
            Section {
                headerView
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            } else if let allSongs = detail?.song {
                if useDiscGrouping {
                    ForEach(discGroups, id: \.disc) { group in
                        Section(header: Text(tr("Disc \(group.disc)", "Disc \(group.disc)"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                        ) {
                            ForEach(group.songs, id: \.id) { song in
                                let startIndex = allSongs.firstIndex(where: { $0.id == song.id }) ?? 0
                                songRow(song: song, startIndex: startIndex, allSongs: allSongs)
                            }
                        }
                    }
                } else {
                    Section {
                        ForEach(Array(displayedSongs.enumerated()), id: \.element.id) { index, song in
                            let startIndex = allSongs.firstIndex(where: { $0.id == song.id }) ?? index
                            songRow(song: song, startIndex: startIndex, allSongs: allSongs)
                        }
                    }
                }
            } else if let err = errorMessage {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                PlayerBottomSpacer(activeHeight: 90, inactiveHeight: 0)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .searchable(text: $searchQuery, prompt: tr("Search songs…", "Titel suchen…"))
        .navigationDestination(item: $artistDestination) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if enableFavorites && !offlineMode.isOffline {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await libraryStore.toggleStarAlbum(album) }
                    } label: {
                        Image(systemName: libraryStore.isAlbumStarred(album) ? "heart.fill" : "heart")
                            .foregroundStyle(libraryStore.isAlbumStarred(album) ? accentColor : .secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if let songs = detail?.song, !songs.isEmpty {
                            player.addPlayNext(songs)
                            currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
                        }
                    } label: {
                        Label(tr("Play Next", "Als nächstes"), systemImage: "text.insert")
                    }
                    .disabled(detail == nil)

                    Button {
                        if let songs = detail?.song, !songs.isEmpty {
                            player.addToQueue(songs)
                            currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
                        }
                    } label: {
                        Label(tr("Add to Queue", "Zur Warteschlange"), systemImage: "text.badge.plus")
                    }
                    .disabled(detail == nil)

                    if enablePlaylists && !offlineMode.isOffline {
                        Divider()
                        Button {
                            if let songs = detail?.song, !songs.isEmpty {
                                albumPlaylistIds = AlbumPlaylistIds(ids: songs.map(\.id))
                            }
                        } label: {
                            Label(tr("Add to Playlist…", "Zur Playlist hinzufügen…"), systemImage: "music.note.list")
                        }
                        .disabled(detail == nil)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .shelveToast($currentToast)
        .alert(
            tr("Delete Downloads?", "Downloads löschen?"),
            isPresented: $showDeleteAlbumDownloadConfirm
        ) {
            Button(tr("Delete", "Löschen"), role: .destructive) {
                downloadStore.deleteAlbum(album.id)
                currentToast = ShelveToast(message: tr("Downloads deleted", "Downloads gelöscht"))
            }
            Button(tr("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(tr("The downloads will be removed from this device.", "Die Downloads werden von diesem Gerät entfernt."))
        }
        .sheet(item: $albumPlaylistIds) { item in
            AddToPlaylistSheet(songIds: item.ids)
                .environmentObject(libraryStore)
                .tint(accentColor)
        }
        .task {
            await loadDetail()
        }
        .onChange(of: downloadStore.songs.count) { _, _ in
            guard offlineMode.isOffline else { return }
            populateFromLocal()
        }
        .onDisappear {
            artistResolveTask?.cancel()
            artistResolveTask = nil
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            AlbumArtView(coverArtId: detail?.coverArt ?? album.coverArt, size: 600, cornerRadius: 16)
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)

            VStack(spacing: 4) {
                Text(album.name)
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                if let artist = detail?.artist ?? album.artist {
                    Button { resolveArtist(artist) } label: {
                        Text(artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 12) {
                    if let year = detail?.year ?? album.year  { Text(String(year)) }
                    if let genre = detail?.genre ?? album.genre { Text(genre) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Button {
                        if let songs = detail?.song, !songs.isEmpty {
                            player.play(songs: songs, startIndex: 0)
                        }
                    } label: {
                        Label(tr("Play", "Abspielen"), systemImage: "play.fill")
                            .font(.body).bold()
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(accentColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(detail == nil)

                    Button {
                        if let songs = detail?.song {
                            player.playShuffled(songs: songs)
                        }
                    } label: {
                        Label(tr("Shuffle", "Zufällig"), systemImage: "shuffle")
                            .font(.body).bold()
                            .foregroundStyle(accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(detail == nil)
                }

                if enableDownloads {
                    downloadHeaderButtons()
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func downloadHeaderButtons() -> some View {
        let total = detail?.song?.count ?? album.songCount ?? 0
        let status = downloadStore.albumDownloadStatus(albumId: album.id, totalSongs: total)
        HStack(spacing: 10) {
            switch status {
            case .none:
                if !offlineMode.isOffline {
                    Button {
                        haptic(); downloadStore.enqueueAlbum(album)
                        currentToast = ShelveToast(message: tr("Download started", "Download gestartet"))
                    } label: {
                        Label(tr("Download", "Herunterladen"), systemImage: "arrow.down.circle")
                            .font(.subheadline).bold()
                            .foregroundStyle(accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            case .partial(let done, let tot):
                if !offlineMode.isOffline {
                    Button {
                        haptic(); downloadStore.enqueueAlbum(album)
                    } label: {
                        Label(tr("Rest (\(tot - done))", "Rest (\(tot - done))"), systemImage: "arrow.down.circle")
                            .font(.subheadline).bold()
                            .foregroundStyle(accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    haptic(); showDeleteAlbumDownloadConfirm = true
                } label: {
                    Label(tr("Delete", "Löschen"), systemImage: "arrow.down.circle")
                        .font(.subheadline).bold()
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            case .complete:
                Button {
                    haptic(); showDeleteAlbumDownloadConfirm = true
                } label: {
                    Label(tr("Delete Downloads", "Downloads löschen"), systemImage: "arrow.down.circle")
                        .font(.subheadline).bold()
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func songRow(song: Song, startIndex: Int, allSongs: [Song]) -> some View {
        Button {
            player.play(songs: allSongs, startIndex: startIndex)
        } label: {
            HStack(spacing: 14) {
                NowPlayingIndicator(
                    songId: song.id,
                    fallbackIndex: song.track ?? (startIndex + 1),
                    accentColor: accentColor
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if showPerSongArtist, let artist = song.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                DownloadStatusIcon(songId: song.id)
                Text(song.durationFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                haptic(); player.addToQueue(song)
                currentToast = ShelveToast(message: tr("Added to Queue", "Zur Warteschlange hinzugefügt"))
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .tint(accentColor)

            Button {
                haptic(); player.addPlayNext(song)
                currentToast = ShelveToast(message: tr("Plays Next", "Wird als nächstes gespielt"))
            } label: {
                Image(systemName: "text.insert")
            }
            .tint(.orange)

            if enableDownloads {
                downloadSwipeButton(for: song)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if enableFavorites && !offlineMode.isOffline {
                Button {
                    haptic(.medium); Task { await libraryStore.toggleStarSong(song) }
                } label: {
                    Image(systemName: libraryStore.isSongStarred(song) ? "heart.slash" : "heart.fill")
                }
                .tint(.pink)
            }
            if enablePlaylists && !offlineMode.isOffline {
                Button {
                    albumPlaylistIds = AlbumPlaylistIds(ids: [song.id])
                } label: {
                    Image(systemName: "music.note.list")
                }
                .tint(accentColor)
            }
        }
    }

    @ViewBuilder
    private func downloadSwipeButton(for song: Song) -> some View {
        if downloadStore.isDownloaded(songId: song.id) {
            Button {
                haptic(); downloadStore.deleteSong(song.id)
            } label: {
                DeleteDownloadIcon()
            }
            .tint(.red)
        } else if !offlineMode.isOffline {
            Button {
                haptic(); downloadStore.enqueueSongs([song])
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .tint(accentColor)
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

    private func loadDetail() async {
        isLoading = true
        if offlineMode.isOffline {
            populateFromLocal()
            isLoading = false
            return
        }
        do {
            detail = try await SubsonicAPIService.shared.getAlbum(id: album.id)
        } catch {
            populateFromLocal()
            if detail == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func populateFromLocal() {
        guard let local = downloadStore.albums.first(where: { $0.albumId == album.id }) else { return }
        let songs = local.songs.map { $0.asSong() }
        detail = AlbumDetail(
            id: local.albumId,
            name: local.title,
            artist: local.artistName,
            artistId: local.artistId,
            coverArt: local.coverArtId,
            songCount: songs.count,
            duration: songs.reduce(0) { $0 + ($1.duration ?? 0) },
            year: nil, genre: nil,
            song: songs
        )
    }
}

private struct AlbumPlaylistIds: Identifiable {
    let id = UUID()
    let ids: [String]
}
