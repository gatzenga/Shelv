import SwiftUI

struct RecapVerifyView: View {
    @EnvironmentObject var recapStore: RecapStore
    @Environment(\.dismiss) private var dismiss
    let serverId: String
    var isImportContext: Bool = false
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var diffs: [RecapDiff] = []
    @State private var isLoading = true
    @State private var processingDiffId: UUID?
    @State private var toast: ShelveToast?
    @State private var completedByButton = false

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(tr("recap.recap.verify.checking_playlists"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if diffs.isEmpty {
                    ContentUnavailableView(
                        tr("recap.recap.verify.sync"),
                        systemImage: "checkmark.seal",
                        description: Text(tr("recap.recap.verify.recap_playlists_match_database"))
                    )
                } else {
                    List {
                        ForEach(diffs) { diff in
                            diffSection(diff)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle(tr("recap.recap.verify.sync.3c9fd927"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !isImportContext || diffs.isEmpty {
                        Button(tr("player.queue.done")) {
                            completedByButton = true
                            if isImportContext {
                                Task { await recapStore.completeImport() }
                            }
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(processingDiffId != nil)
            .shelveToast($toast)
        }
        .tint(accentColor)
        .task { await loadDiffs() }
        .onDisappear {
            guard isImportContext, !completedByButton else { return }
            Task { await recapStore.cancelImport(serverId: serverId) }
        }
    }

    // MARK: - Diff Section

    @ViewBuilder
    private func diffSection(_ diff: RecapDiff) -> some View {
        Section {
            if diff.serverMissing {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(tr("recap.recap.verify.playlist_not_found_server"))
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.vertical, 4)

                diffGroup(
                    label: tr("recap.recap.verify.songs_add_value", String(describing: diff.expectedOrder.count)),
                    icon: "plus.circle",
                    tint: .green,
                    songs: diff.expectedOrder
                )
            } else {
                if diff.nameMismatch {
                    metadataRow(
                        icon: "pencil",
                        tint: .blue,
                        title: tr("recap.recap.verify.name_change"),
                        detail: "\"\(diff.currentName)\" → \"\(diff.playlistName)\""
                    )
                }

                if diff.commentMissing {
                    metadataRow(
                        icon: "text.quote",
                        tint: .blue,
                        title: tr("recap.recap.verify.comment_added"),
                        detail: diff.currentComment.map { "\"\($0)\" → \"Shelv Recap\"" } ?? "\"Shelv Recap\""
                    )
                }

                if !diff.missingSongs.isEmpty {
                    diffGroup(
                        label: tr("recap.recap.verify.missing_songs_value", String(describing: diff.missingSongs.count)),
                        icon: "plus.circle",
                        tint: .green,
                        songs: diff.missingSongs
                    )
                }

                if !diff.extraSongs.isEmpty {
                    diffGroup(
                        label: tr("recap.recap.verify.extra_songs_value", String(describing: diff.extraSongs.count)),
                        icon: "minus.circle",
                        tint: .red,
                        songs: diff.extraSongs
                    )
                }

                if diff.orderChanged {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .foregroundStyle(.orange)
                        Text(tr("recap.recap.verify.order_has_changed"))
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack(spacing: 10) {
                if !diff.serverMissing {
                    Button {
                        apply(diff, decision: .update)
                    } label: {
                        Label(tr("recap.recap.verify.apply"), systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(processingDiffId != nil)
                }

                Button {
                    apply(diff, decision: .createNew)
                } label: {
                    Label(tr("recap.recap.verify.create_new"), systemImage: "plus.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(diff.serverMissing ? accentColor : Color(.tertiarySystemBackground))
                        .foregroundStyle(diff.serverMissing ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(processingDiffId != nil)
            }
            .padding(.vertical, 4)

            if processingDiffId == diff.id {
                HStack {
                    ProgressView()
                    Text(tr("recap.recap.verify.applying"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(diff.playlistName)
                .font(.headline)
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }

    private func metadataRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func diffGroup(label: String, icon: String, tint: Color, songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(label).font(.subheadline.weight(.semibold))
            }
            ForEach(songs, id: \.id) { song in
                HStack(spacing: 10) {
                    AlbumArtView(coverArtId: song.coverArt, size: 80, cornerRadius: 4)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title)
                            .font(.caption)
                            .lineLimit(1)
                        if let artist = song.artist {
                            Text(artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func loadDiffs() async {
        isLoading = true
        diffs = await recapStore.computeDiffs(serverId: serverId)
        isLoading = false
    }

    private func apply(_ diff: RecapDiff, decision: RecapDiffDecision) {
        processingDiffId = diff.id
        Task {
            do {
                try await recapStore.applyDiff(diff, decision: decision, serverId: serverId)
                diffs.removeAll { $0.id == diff.id }
                toast = ShelveToast(message: decision == .update
                    ? tr("recap.recap.verify.playlist_updated")
                    : tr("recap.recap.verify.new_playlist_created"))
            } catch {
                toast = ShelveToast(message: error.localizedDescription, isError: true)
            }
            processingDiffId = nil
        }
    }
}
