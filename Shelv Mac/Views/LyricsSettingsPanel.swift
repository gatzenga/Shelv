import SwiftUI

struct LyricsSettingsPanel: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var lyricsStore: LyricsStore
    @Environment(\.themeColor) private var themeColor
    @AppStorage("autoFetchLyrics") private var autoFetchLyrics = true

    @State private var showResetConfirm = false

    private var serverId: String {
        appState.serverStore.activeServerID?.uuidString ?? ""
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $autoFetchLyrics) {
                    Label(String(localized: "autofetch_on_playback"), systemImage: "wand.and.stars")
                }
                .tint(themeColor)
            }

            Section(String(localized: "database")) {
                LabeledContent(String(localized: "stored")) {
                    if lyricsStore.isDownloading {
                        Text("\(lyricsStore.downloadFetched) / \(lyricsStore.downloadTotal)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("\(lyricsStore.fetchedCount) · \(lyricsStore.dbSize)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                if lyricsStore.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(
                            value: Double(lyricsStore.downloadFetched),
                            total: Double(max(lyricsStore.downloadTotal, 1))
                        )
                        .tint(themeColor)
                        Button(String(localized: "cancel_download")) {
                            lyricsStore.cancelBulkDownload()
                        }
                        .foregroundStyle(.red)
                        .font(.caption)
                        .buttonStyle(.plain)
                    }
                } else {
                    Button {
                        guard !serverId.isEmpty else { return }
                        lyricsStore.startBulkDownload(serverId: serverId)
                    } label: {
                        Label(String(localized: "download_all_lyrics"), systemImage: "arrow.down.circle")
                    }
                    .disabled(serverId.isEmpty)
                }

                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label(String(localized: "reset_lyrics_database"), systemImage: "trash")
                }
                .confirmationDialog(
                    String(localized: "reset_lyrics_database_2"),
                    isPresented: $showResetConfirm
                ) {
                    Button(String(localized: "reset"), role: .destructive) {
                        Task {
                            await lyricsStore.reset(serverId: serverId)
                        }
                    }
                    Button(String(localized: "cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "all_stored_lyrics_for_the_active_server_will_be_de"))
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await lyricsStore.refreshFetchedCount(serverId: serverId)
            lyricsStore.refreshDbSize()
        }
    }
}
