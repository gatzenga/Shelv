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

enum DownloadIndicatorStyle {
    case list
    case cover
}

private struct CoverStatusCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5)
                    }
                    .padding(.horizontal, -5)
                    .padding(.vertical, -3)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .opacity(proxy.size.width > 0 && proxy.size.height > 0 ? 1 : 0)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
    }
}

extension View {
    func coverStatusCapsule() -> some View {
        modifier(CoverStatusCapsuleModifier())
    }
}

/// Einheitliche Download-Darstellung: subtil in Listen, akzentfarben auf Cover-Artwork.
struct DownloadAvailabilityIcon: View {
    var style: DownloadIndicatorStyle = .list
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        switch style {
        case .list:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(themeColor)
                .frame(width: 14, height: 14)
        case .cover:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeColor)
                .frame(width: 14, height: 14)
        }
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
                DownloadAvailabilityIcon()
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
    var style: DownloadIndicatorStyle = .cover
    @State private var isDownloaded: Bool

    init(albumId: String, style: DownloadIndicatorStyle = .cover) {
        self.albumId = albumId
        self.style = style
        _isDownloaded = State(
            initialValue: DownloadUIStateHub.shared.isAlbumDownloaded(albumId)
        )
    }

    var body: some View {
        Group {
            if isDownloaded {
                DownloadAvailabilityIcon(style: style)
            }
        }
        .onReceive(
            DownloadUIStateHub.shared.albumAvailabilityPublisher(albumID: albumId)
        ) { isDownloaded = $0 }
    }
}

struct ArtistDownloadBadge: View {
    let artistName: String
    var style: DownloadIndicatorStyle = .cover
    @State private var isDownloaded: Bool

    init(artistName: String, style: DownloadIndicatorStyle = .cover) {
        self.artistName = artistName
        self.style = style
        _isDownloaded = State(
            initialValue: DownloadUIStateHub.shared.isArtistBadgeDownloaded(artistName)
        )
    }

    var body: some View {
        Group {
            if isDownloaded {
                DownloadAvailabilityIcon(style: style)
            }
        }
        .onReceive(
            DownloadUIStateHub.shared.artistAvailabilityPublisher(name: artistName)
        ) { isDownloaded = $0 }
    }
}

struct PlaylistDownloadBadge: View {
    let playlistId: String
    var style: DownloadIndicatorStyle = .list
    @ObservedObject private var downloadStore = DownloadStore.shared
    @AppStorage("enableDownloads") private var enableDownloads = true

    var body: some View {
        if enableDownloads && downloadStore.downloadedPlaylistIds.contains(playlistId) {
            DownloadAvailabilityIcon(style: style)
        }
    }
}
