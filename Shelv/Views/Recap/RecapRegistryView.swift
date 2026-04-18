import SwiftUI

struct RecapRegistryView: View {
    let serverId: String
    @EnvironmentObject var recapStore: RecapStore
    @AppStorage("themeColor") private var themeColorName = "violet"

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    var body: some View {
        List {
            Section(tr("Registry", "Registry")) {
                if recapStore.entries.isEmpty {
                    Text(tr("No recap playlists yet.", "Noch keine Recap-Playlists."))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(recapStore.entries, id: \.playlistId) { entry in
                        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
                        let period = RecapPeriod(
                            type: type,
                            start: Date(timeIntervalSince1970: entry.periodStart),
                            end: Date(timeIntervalSince1970: entry.periodEnd)
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(period.playlistName)
                                .font(.subheadline)
                            Text(entry.playlistId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task {
                                    await recapStore.deleteRegistryEntryOnly(playlistId: entry.playlistId, serverId: serverId)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            }

            PlayerBottomSpacer(activeHeight: 110, inactiveHeight: 0)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .refreshable {
            await recapStore.refreshWithCleanup(serverId: serverId)
        }
        .navigationTitle(tr("Registry", "Registry"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await recapStore.refreshWithCleanup(serverId: serverId) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await recapStore.refreshWithCleanup(serverId: serverId) }
    }
}
