import SwiftUI

struct BulkDownloadSheet: View {
    let maxBytes: Int64

    @ObservedObject var libraryStore = LibraryStore.shared
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var recapStore: RecapStore
    @ObservedObject var downloadStore = DownloadStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableFavorites") private var enableFavorites = true
    @AppStorage("recapEnabled") private var recapEnabled = false
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var plan: BulkDownloadPlan?
    @State private var isPlanning = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        NavigationStack {
            Group {
                if let plan {
                    planDetails(plan)
                } else if isPlanning {
                    ProgressView(String(localized: "calculating"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(String(localized: "download_everything"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "start")) {
                        guard let plan else { return }
                        downloadStore.enqueueSongs(plan.planned)
                        let plannedIds = Set(plan.planned.map(\.id))
                        for (playlistId, songIds) in plan.recapPlaylistSongIds {
                            let allCovered = songIds.allSatisfy { downloadStore.isDownloaded(songId: $0) || plannedIds.contains($0) }
                            if allCovered {
                                downloadStore.addOfflinePlaylist(playlistId, songIds: songIds)
                            }
                        }
                        dismiss()
                    }
                    .disabled(plan?.isEmpty ?? true)
                }
            }
            .task(id: serverStore.activeServer?.stableId) { await recompute() }
        }
    }

    @ViewBuilder
    private func planDetails(_ plan: BulkDownloadPlan) -> some View {
        List {
            Section {
                HStack {
                    Text(String(localized: "songs_to_download")).font(.subheadline)
                    Spacer()
                    Text("\(plan.planned.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(String(localized: "estimated_size")).font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(String(localized: "storage_limit")).font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: plan.limitBytes, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if !plan.skipped.isEmpty {
                    HStack {
                        Text(String(localized: "skipped_over_limit")).font(.subheadline)
                        Spacer()
                        Text("\(plan.skipped.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if plan.isEmpty {
                Section {
                    Text(String(localized: "nothing_new_fits_in_the_configured_storage_limit"))
                    .foregroundStyle(.secondary)
                }
            } else {
                Section(String(localized: "order")) {
                    Label(String(localized: "frequently_played_first"),
                          systemImage: "chart.line.uptrend.xyaxis")
                    Label(String(localized: "then_recently_played"),
                          systemImage: "clock.arrow.circlepath")
                    if enableFavorites {
                        Label(String(localized: "then_favorites"),
                              systemImage: "heart")
                    }
                    if recapEnabled && !recapStore.recapPlaylistIds.isEmpty {
                        Label(String(localized: "then_recap_playlists"),
                              systemImage: "calendar.badge.clock")
                    }
                    Label(String(localized: "then_alphabetical_by_artist"),
                          systemImage: "textformat")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }

    private func recompute() async {
        isPlanning = true
        defer { isPlanning = false }
        guard let stable = serverStore.activeServer?.stableId, !stable.isEmpty else { return }
        if libraryStore.albums.isEmpty {
            await libraryStore.loadAlbums()
        }
        guard !Task.isCancelled else { return }
        let albums = libraryStore.albums
        guard !albums.isEmpty else { return }
        let recapIds = await MainActor.run { recapEnabled ? Array(recapStore.recapPlaylistIds) : [] }
        let computed = await DownloadService.shared.planBulkDownload(
            serverId: stable, maxBytes: maxBytes,
            favorites: enableFavorites,
            recapPlaylistIds: recapIds,
            libraryAlbums: albums
        )
        guard !Task.isCancelled else { return }
        plan = computed
    }
}
