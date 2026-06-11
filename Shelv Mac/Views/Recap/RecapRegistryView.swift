import SwiftUI

struct RecapRegistryView: View {
    let serverId: String
    @StateObject private var recapStore = RecapStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        Form {
            Section(String(localized: "registry")) {
                if recapStore.entries.isEmpty {
                    Text(String(localized: "no_recap_playlists_yet"))
                        .foregroundStyle(.secondary).font(.subheadline)
                } else {
                    ForEach(recapStore.entries, id: \.playlistId) { entry in
                        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
                        let period = RecapPeriod(
                            type: type,
                            start: Date(timeIntervalSince1970: entry.periodStart),
                            end: Date(timeIntervalSince1970: entry.periodEnd)
                        )
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(period.playlistName).font(.subheadline)
                                Text(entry.playlistId)
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                Task {
                                    await recapStore.deleteRegistryEntryOnly(playlistId: entry.playlistId, serverId: serverId)
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help(String(localized: "delete"))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 540, height: 580)
        .navigationTitle(String(localized: "registry"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await recapStore.refreshWithCleanup(serverId: serverId) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
        .task { await recapStore.refreshWithCleanup(serverId: serverId) }
    }
}
