import SwiftUI

struct DiscoverView: View {
    @ObservedObject var libraryStore = LibraryStore.shared
    @ObservedObject var offlineMode = OfflineModeService.shared
    @ObservedObject var downloadStore = DownloadStore.shared
    @EnvironmentObject var recapStore: RecapStore
    private let player = AudioPlayerService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("recapEnabled") private var recapEnabled = false
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    private var recapButtonVisible: Bool {
        // Wenn Recap deaktiviert ist, soll der Eintrag komplett aus der UI verschwinden.
        guard recapEnabled else { return false }
        if !offlineMode.isOffline { return true }
        // Offline: nur wenn mindestens eine Recap-Playlist heruntergeladen ist.
        return !recapStore.recapPlaylistIds.isDisjoint(with: downloadStore.offlinePlaylistIds)
    }

    @State private var mixLoading: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var randomRefreshing = false
    @State private var showSearch = false
    @State private var showInsights = false
    @State private var showRecap = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if offlineMode.isOffline {
                        offlineEmptyState
                    } else if libraryStore.isLoadingDiscover && libraryStore.recentlyAdded.isEmpty {
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
                        randomAlbumSection

                        PlayerBottomSpacer()
                    }
                }
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Shelv")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if recapButtonVisible {
                            Button {
                                showRecap = true
                            } label: {
                                Image(systemName: "calendar.badge.clock")
                            }
                        }
                        if !offlineMode.isOffline {
                            Button {
                                showInsights = true
                            } label: {
                                Image(systemName: "chart.bar.xaxis")
                            }
                        }
                        Button {
                            showSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSearch) {
                SearchView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .sheet(isPresented: $showInsights) {
                InsightsView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .sheet(isPresented: $showRecap) {
                RecapView()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
                    .tint(accentColor)
            }
            .refreshable {
                async let discover: Void = libraryStore.loadDiscover()
                async let sync:     Void = CloudKitSyncService.shared.syncNow()
                _ = await (discover, sync)
            }
            .task(id: libraryStore.reloadID) {
                await libraryStore.loadDiscover()
            }
            .onChange(of: libraryStore.errorMessage) { _, msg in
                if let msg {
                    errorMessage = msg
                    showError = true
                    libraryStore.errorMessage = nil
                }
            }
            .alert(tr("Error", "Fehler"), isPresented: $showError, presenting: errorMessage) { _ in
                Button(tr("OK", "OK"), role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private var offlineEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text(tr("You are offline", "Du bist offline"))
                .font(.title3).bold()
            Text(tr(
                "Downloads are still available. Tap the magnifying glass to search your library.",
                "Downloads sind weiterhin verfügbar. Tippe auf die Lupe um in deiner Bibliothek zu suchen."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            Button {
                offlineMode.exitOfflineMode()
            } label: {
                Label(tr("Go Online", "Online gehen"), systemImage: "wifi")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    @ViewBuilder
    private var randomAlbumSection: some View {
        albumSection(title: tr("Random Albums", "Zufällige Alben"), albums: libraryStore.randomAlbums) {
            Button {
                randomRefreshing = true
                Task {
                    await libraryStore.refreshRandomAlbums()
                    randomRefreshing = false
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.body)
                    .foregroundStyle(accentColor)
                    .rotationEffect(.degrees(randomRefreshing ? 360 : 0))
                    .animation(
                        randomRefreshing ? .linear(duration: 0.5).repeatForever(autoreverses: false) : .default,
                        value: randomRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(randomRefreshing)
        }
    }

    @ViewBuilder
    private func albumSection<T: View>(title: String, albums: [Album], @ViewBuilder trailingButton: () -> T = { EmptyView() }) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(.title3).bold()
                    Spacer()
                    trailingButton()
                }
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
            case "frequent": songs = try await SubsonicAPIService.shared.getFrequentSongs(limit: 50)
            default:         songs = try await SubsonicAPIService.shared.getRecentSongs(limit: 50)
            }
            player.playShuffled(songs: songs)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
