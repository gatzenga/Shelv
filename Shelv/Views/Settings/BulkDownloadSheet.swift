import SwiftUI

struct BulkDownloadSheet: View {
    let maxBytes: Int64

    @ObservedObject var libraryStore = LibraryStore.shared
    @EnvironmentObject var serverStore: ServerStore
    @ObservedObject var downloadStore = DownloadStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("enableFavorites") private var enableFavorites = true
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
                    ProgressView(tr("Calculating…", "Berechne…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(tr("Download Everything", "Alles herunterladen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("Cancel", "Abbrechen")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("Start", "Starten")) {
                        guard let plan else { return }
                        downloadStore.enqueueSongs(plan.planned)
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
                    Text(tr("Songs to download", "Songs")).font(.subheadline)
                    Spacer()
                    Text("\(plan.planned.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(tr("Estimated size", "Geschätzte Größe")).font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(tr("Storage limit", "Limit")).font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: plan.limitBytes, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if !plan.skipped.isEmpty {
                    HStack {
                        Text(tr("Skipped (over limit)", "Übersprungen (über Limit)")).font(.subheadline)
                        Spacer()
                        Text("\(plan.skipped.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if plan.isEmpty {
                Section {
                    Text(tr(
                        "Nothing new fits in the configured storage limit.",
                        "Es passt nichts Neues in das konfigurierte Speicher-Limit."
                    ))
                    .foregroundStyle(.secondary)
                }
            } else {
                Section(tr("Order", "Reihenfolge")) {
                    Label(tr("Frequently played first", "Häufig gespielt zuerst"),
                          systemImage: "chart.line.uptrend.xyaxis")
                    Label(tr("Then recently played", "Dann kürzlich gespielt"),
                          systemImage: "clock.arrow.circlepath")
                    if enableFavorites {
                        Label(tr("Then favorites", "Dann Favoriten"),
                              systemImage: "heart")
                    }
                    Label(tr("Then alphabetical by artist", "Dann alphabetisch"),
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
        let computed = await DownloadService.shared.planBulkDownload(
            serverId: stable, maxBytes: maxBytes,
            favorites: enableFavorites,
            libraryAlbums: albums
        )
        guard !Task.isCancelled else { return }
        plan = computed
    }
}
