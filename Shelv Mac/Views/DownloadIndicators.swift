import SwiftUI
@preconcurrency import Combine

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
    private let downloadStore = DownloadStore.shared
    @State private var state: DownloadState
    @State private var isSpinning = false
    @Environment(\.themeColor) private var themeColor

    init(songId: String) {
        self.songId = songId
        _state = State(initialValue: DownloadStore.shared.downloadState(songId: songId))
    }

    var body: some View {
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
        .onReceive(
            downloadStore.progressPublisher
                .filter { $0.contains(songId) }
        ) { _ in
            state = downloadStore.downloadState(songId: songId)
        }
        .onReceive(
            DownloadUIStateHub.shared.songAvailabilityPublisher(songID: songId)
        ) { isDownloaded in
            if isDownloaded {
                state = .completed
            } else {
                state = downloadStore.downloadState(songId: songId)
            }
        }
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
    @State private var isDownloaded: Bool
    @Environment(\.themeColor) private var themeColor

    init(albumId: String) {
        self.albumId = albumId
        _isDownloaded = State(
            initialValue: DownloadUIStateHub.shared.isAlbumDownloaded(albumId)
        )
    }

    var body: some View {
        Group {
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(themeColor, in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
        .onReceive(
            DownloadUIStateHub.shared.albumAvailabilityPublisher(albumID: albumId)
        ) { isDownloaded = $0 }
    }
}

struct ArtistDownloadBadge: View {
    let artistName: String
    @State private var isDownloaded: Bool
    @Environment(\.themeColor) private var themeColor

    init(artistName: String) {
        self.artistName = artistName
        _isDownloaded = State(
            initialValue: DownloadUIStateHub.shared.isArtistBadgeDownloaded(artistName)
        )
    }

    var body: some View {
        Group {
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(themeColor, in: Circle())
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
        }
        .onReceive(
            DownloadUIStateHub.shared.artistAvailabilityPublisher(name: artistName)
        ) { isDownloaded = $0 }
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
