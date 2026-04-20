import SwiftUI

struct RecapDetailView: View {
    let entry: RecapRegistryRecord
    let serverId: String

    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }

    @State private var songs: [SongWithCount] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private struct SongWithCount: Identifiable {
        let id: String
        let song: Song
        let playCount: Int
    }

    private var period: RecapPeriod {
        let type = RecapPeriod.PeriodType(rawValue: entry.periodType) ?? .week
        return RecapPeriod(
            type: type,
            start: Date(timeIntervalSince1970: entry.periodStart),
            end: Date(timeIntervalSince1970: entry.periodEnd)
        )
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if songs.isEmpty {
                ContentUnavailableView(
                    tr("No Songs", "Keine Titel"),
                    systemImage: "music.note",
                    description: Text(tr("No songs found for this period.", "Keine Titel für diesen Zeitraum gefunden."))
                )
            } else {
                List {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { idx, entry in
                        Button {
                            AudioPlayerService.shared.play(
                                songs: songs.map { $0.song },
                                startIndex: idx
                            )
                        } label: {
                            songRow(rank: idx + 1, entry: entry)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                    PlayerBottomSpacer()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(period.playlistName)
        .navigationBarTitleDisplayMode(.large)
        .task { await load() }
    }

    // MARK: - Row

    private func songRow(rank: Int, entry: SongWithCount) -> some View {
        let isTop3 = rank <= 3
        return rankCard(isTop3: isTop3) {
            rankLabel(rank: rank, isTop3: isTop3)
            AlbumArtView(coverArtId: entry.song.coverArt, size: 100, cornerRadius: 8)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.song.title)
                    .font(isTop3 ? .body.bold() : .body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let artist = entry.song.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            playCountBadge(entry.playCount, isTop3: isTop3)
        }
    }

    // MARK: - Shared Components (analog InsightsView)

    private func rankCard<Content: View>(isTop3: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) { content() }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTop3 ? accentColor.opacity(0.08) : Color(.secondarySystemBackground))
            )
            .overlay {
                if isTop3 {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(accentColor.opacity(0.25), lineWidth: 1)
                }
            }
    }

    private func rankLabel(rank: Int, isTop3: Bool) -> some View {
        Text("\(rank)")
            .font(isTop3 ? .title2.bold() : .callout.bold())
            .foregroundStyle(isTop3 ? accentColor : Color.secondary)
            .monospacedDigit()
            .frame(width: 28, alignment: .trailing)
    }

    private func playCountBadge(_ count: Int, isTop3: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.caption2)
            Text("\(count)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(isTop3 ? accentColor : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isTop3 ? accentColor : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Data Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let playlist = try await SubsonicAPIService.shared.getPlaylist(id: entry.playlistId)
            let playlistSongs = playlist.songs ?? []

            let counts = await PlayLogService.shared.topSongs(
                serverId: serverId,
                from: Date(timeIntervalSince1970: entry.periodStart),
                to: Date(timeIntervalSince1970: entry.periodEnd),
                limit: period.type.songLimit
            )
            let countMap = Dictionary(uniqueKeysWithValues: counts.map { ($0.songId, $0.count) })

            songs = playlistSongs.map { song in
                SongWithCount(id: song.id, song: song, playCount: countMap[song.id] ?? 0)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
