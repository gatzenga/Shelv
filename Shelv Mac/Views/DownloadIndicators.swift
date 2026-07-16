import SwiftUI

enum DownloadActionSymbols {
    static var delete: String {
        if #available(macOS 26.0, *) {
            return "arrow.down.circle.badge.xmark"
        }
        return "arrow.down.circle"
    }
}

struct DownloadStatusIcon: View {
    let songId: String
    @ObservedObject private var downloadStore = DownloadStore.shared
    @State private var progressTick = 0
    @State private var isSpinning = false
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        let state = downloadStore.downloadState(songId: songId)
        Group {
            switch state {
            case .none:
                EmptyView()
            case .queued:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.secondary)
            case .downloading(let progress):
                if progress < 0 {
                    DownloadProgressRing(progress: 0.2, accent: themeColor)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                        .onAppear { isSpinning = true }
                        .onDisappear { isSpinning = false }
                } else {
                    DownloadProgressRing(progress: progress, accent: themeColor)
                        .frame(width: 14, height: 14)
                }
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onReceive(DownloadStore.shared.progressPublisher) { _ in progressTick &+= 1 }
    }
}

struct DownloadProgressRing: View {
    let progress: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

/// Download-Icon für Aktionen, die lokale Downloads entfernen.
struct DeleteDownloadIcon: View {
    var tint: Color? = nil

    var body: some View {
        if let tint {
            Image(systemName: DownloadActionSymbols.delete)
                .foregroundStyle(tint)
        } else {
            Image(systemName: DownloadActionSymbols.delete)
        }
    }
}

struct AlbumDownloadBadge: View {
    let albumId: String
    @ObservedObject private var statusCache = DownloadStatusCache.shared
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        if statusCache.albumIds.contains(albumId) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(4)
                .background(themeColor, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }
}

struct PlaylistDownloadBadge: View {
    let playlistId: String
    @ObservedObject private var downloadStore = DownloadStore.shared
    @Environment(\.themeColor) private var themeColor
    @AppStorage("enableDownloads") private var enableDownloads = true

    var body: some View {
        if enableDownloads && downloadStore.downloadedPlaylistIds.contains(playlistId) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(4)
                .background(themeColor, in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
    }
}
