import SwiftUI

struct QueueSongRow: View {
    let song: Song
    var isEditing: Bool = false
    var onDelete: (() -> Void)? = nil

    @Environment(\.themeColor) private var themeColor
    @ObservedObject private var streamCacheStatus = StreamCacheStatus.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            CoverArtView(
                url: song.coverArt.flatMap { SubsonicAPIService.shared.coverArtURL(id: $0, size: 80) },
                size: 36,
                cornerRadius: 4
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.callout).lineLimit(1)
                if let artist = song.artist {
                    Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isEditing {
                if let onDelete {
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .frame(width: 22, height: 22)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(themeColor)
            } else {
                HStack(spacing: 4) {
                    Group {
                        if streamCacheStatus.cachedSongIds.contains(song.id) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(themeColor)
                                .accessibilityLabel(String(localized: "precache_ready"))
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(song.durationString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .frame(minWidth: 54, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        .onHover { isHovered = $0 }
    }
}
