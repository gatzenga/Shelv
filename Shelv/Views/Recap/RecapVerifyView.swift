import SwiftUI

struct RecapVerifyView: View {
    @EnvironmentObject var recapStore: RecapStore
    @Environment(\.dismiss) private var dismiss
    let serverId: String
    var isImportContext: Bool = false
    @AppStorage("themeColor") private var themeColorName = "violet"

    @State private var diffs: [RecapDiff] = []
    @State private var isLoading = true
    @State private var loadError: String?
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
                        Text(String(localized: "checking_playlists"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        String(localized: "sync"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else if diffs.isEmpty {
                    ContentUnavailableView(
                        String(localized: "all_in_sync"),
                        systemImage: "checkmark.seal",
                        description: Text(String(localized: "all_recap_playlists_match_the_database"))
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
            .navigationTitle(String(localized: "sync"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !isImportContext || (diffs.isEmpty && loadError == nil) {
                        Button(String(localized: "done")) {
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
                    Text(String(localized: "playlist_not_found_on_server"))
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.vertical, 4)

                diffGroup(
                    label: String(format: String(localized: "songs_to_add_format"), diff.expectedOrder.count),
                    icon: "plus.circle",
                    tint: .green,
                    songs: diff.expectedOrder
                )
            } else {
                if diff.nameMismatch {
                    metadataRow(
                        icon: "pencil",
                        tint: .blue,
                        title: String(localized: "name_will_change"),
                        detail: "\"\(diff.currentName)\" → \"\(diff.playlistName)\""
                    )
                }

                if diff.commentMissing {
                    metadataRow(
                        icon: "text.quote",
                        tint: .blue,
                        title: String(localized: "comment_will_be_added"),
                        detail: diff.currentComment.map { "\"\($0)\" → \"Shelv Recap\"" } ?? "\"Shelv Recap\""
                    )
                }

                if !diff.missingSongs.isEmpty {
                    diffGroup(
                        label: String(format: String(localized: "missing_songs_format"), diff.missingSongs.count),
                        icon: "plus.circle",
                        tint: .green,
                        songs: diff.missingSongs
                    )
                }

                if !diff.extraSongs.isEmpty {
                    diffGroup(
                        label: String(format: String(localized: "extra_songs_format"), diff.extraSongs.count),
                        icon: "minus.circle",
                        tint: .red,
                        songs: diff.extraSongs
                    )
                }

                if diff.orderChanged {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .foregroundStyle(.orange)
                        Text(String(localized: "order_has_changed"))
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
                        Label(String(localized: "apply"), systemImage: "checkmark")
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
                    Label(String(localized: "create_new"), systemImage: "plus.rectangle.on.rectangle")
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
                    Text(String(localized: "applying"))
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
        loadError = nil
        do {
            diffs = try await recapStore.computeDiffs(serverId: serverId)
        } catch {
            diffs = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func apply(_ diff: RecapDiff, decision: RecapDiffDecision) {
        processingDiffId = diff.id
        Task {
            do {
                let appliedDecision = try await recapStore.applyLatestDiff(
                    matching: diff,
                    preferredDecision: decision,
                    serverId: serverId
                )
                diffs.removeAll { $0.id == diff.id }
                let message: String
                switch appliedDecision {
                case .some(.createNew):
                    message = String(localized: "new_playlist_created")
                default:
                    message = String(localized: "playlist_updated")
                }
                toast = ShelveToast(message: message)
            } catch {
                toast = ShelveToast(message: error.localizedDescription, isError: true)
            }
            processingDiffId = nil
        }
    }
}
