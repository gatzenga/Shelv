import SwiftUI

struct RecapVerifyView: View {
    @StateObject private var recapStore = RecapStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor
    let serverId: String
    var isImportContext: Bool = false

    @State private var diffs: [RecapDiff] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var processingDiffId: UUID?
    @State private var completedByButton = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "sync")).font(.title3.bold())
                Spacer()
                if !isImportContext || (diffs.isEmpty && loadError == nil) {
                    Button(String(localized: "done")) {
                        completedByButton = true
                        if isImportContext {
                            Task { await recapStore.completeImport() }
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()

            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(String(localized: "checking_playlists"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView(
                        String(localized: "sync"),
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if diffs.isEmpty {
                    ContentUnavailableView(
                        String(localized: "all_in_sync"),
                        systemImage: "checkmark.seal",
                        description: Text(String(localized: "all_recap_playlists_match_the_database"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(diffs) { diff in
                            diffSection(diff)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .frame(width: 560, height: 600)
        .interactiveDismissDisabled(processingDiffId != nil)
        .task { await loadDiffs() }
        .onDisappear {
            guard isImportContext, !completedByButton else { return }
            Task { await recapStore.cancelImport(serverId: serverId) }
        }
    }

    @ViewBuilder
    private func diffSection(_ diff: RecapDiff) -> some View {
        Section {
            if diff.serverMissing {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(String(localized: "playlist_not_found_on_server"))
                        .font(.subheadline)
                    Spacer()
                }
                diffGroup(
                    label: String(format: String(localized: "songs_to_add_format"), diff.expectedOrder.count),
                    icon: "plus.circle", tint: .green, songs: diff.expectedOrder
                )
            } else {
                if diff.nameMismatch {
                    metadataRow(
                        icon: "pencil", tint: .blue,
                        title: String(localized: "name_will_change"),
                        detail: "\"\(diff.currentName)\" → \"\(diff.playlistName)\""
                    )
                }
                if diff.commentMissing {
                    metadataRow(
                        icon: "text.quote", tint: .blue,
                        title: String(localized: "comment_will_be_added"),
                        detail: diff.currentComment.map { "\"\($0)\" → \"Shelv Recap\"" } ?? "\"Shelv Recap\""
                    )
                }
                if !diff.missingSongs.isEmpty {
                    diffGroup(
                        label: String(format: String(localized: "missing_songs_format"), diff.missingSongs.count),
                        icon: "plus.circle", tint: .green, songs: diff.missingSongs
                    )
                }
                if !diff.extraSongs.isEmpty {
                    diffGroup(
                        label: String(format: String(localized: "extra_songs_format"), diff.extraSongs.count),
                        icon: "minus.circle", tint: .red, songs: diff.extraSongs
                    )
                }
                if diff.orderChanged {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.arrow.down.circle").foregroundStyle(.orange)
                        Text(String(localized: "order_has_changed")).font(.subheadline)
                        Spacer()
                    }
                }
            }

            HStack(spacing: 10) {
                if !diff.serverMissing {
                    Button {
                        apply(diff, decision: .update)
                    } label: {
                        Label(String(localized: "apply"), systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(processingDiffId != nil)
                }
                Button {
                    apply(diff, decision: .createNew)
                } label: {
                    Label(String(localized: "create_new_2"), systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                .disabled(processingDiffId != nil)
            }
            .padding(.vertical, 4)

            if processingDiffId == diff.id {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "applying"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(diff.playlistName).font(.headline).foregroundStyle(.primary)
        }
    }

    private func metadataRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                    CoverArtView(
                        url: song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 80) },
                        size: 32, cornerRadius: 4
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.caption).lineLimit(1)
                        if let artist = song.artist {
                            Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
    }

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
                NotificationCenter.default.post(name: .showToast, object: message)
            } catch {
                NotificationCenter.default.post(name: .showToast, object: error.localizedDescription)
            }
            processingDiffId = nil
        }
    }
}
