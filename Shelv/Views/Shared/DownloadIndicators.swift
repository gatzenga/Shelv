import SwiftUI
@preconcurrency import Combine

enum DownloadActionSymbols {
    static var delete: String {
        if #available(iOS 26.0, *) {
            return "arrow.down.circle.badge.xmark"
        }
        return "arrow.down.circle"
    }

    static var filledDelete: String {
        if #available(iOS 26.0, *) {
            return "arrow.down.circle.badge.xmark.fill"
        }
        return "arrow.down.circle.fill"
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
                    if proxy.size.width > 0, proxy.size.height > 0 {
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5)
                        }
                        .padding(.horizontal, -5)
                        .padding(.vertical, -3)
                        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    }
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
    @AppStorage("themeColor") private var themeColorName = "violet"

    var body: some View {
        switch style {
        case .list:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(AppTheme.color(for: themeColorName))
                .frame(width: 14, height: 14)
        case .cover:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.color(for: themeColorName))
                .frame(width: 14, height: 14)
        }
    }
}

/// Kompakter Status-Indikator für einen einzelnen Song: Ring während Download, Pfeil wenn fertig.
struct DownloadStatusIcon: View {
    let songId: String
    private let downloadStore = DownloadStore.shared
    @State private var state: DownloadState
    @State private var isSpinning = false
    @AppStorage("themeColor") private var themeColorName = "violet"

    init(songId: String) {
        self.songId = songId
        _state = State(initialValue: DownloadStore.shared.downloadState(songId: songId))
    }

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

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
                    DownloadProgressRing(progress: 0.2, accent: accentColor)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(isSpinning ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                        .onAppear { isSpinning = true }
                        .onDisappear { isSpinning = false }
                } else {
                    DownloadProgressRing(progress: progress, accent: accentColor)
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
        ) { _ in
            state = downloadStore.downloadState(songId: songId)
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
    /// Für Context-Menu-Items mit `role: .destructive`, deren Icon-Slot die
    /// geerbte Vordergrundfarbe sonst überschreibt.
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

/// Kleines Badge-Symbol unten rechts auf einer Album-/Playlist-Card,
/// wenn mindestens ein Song lokal verfügbar ist.
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

/// Badge für Playlist-Rows — zeigt an, dass die Playlist für den Offline-Modus markiert ist.
struct PlaylistDownloadBadge: View {
    let playlistId: String
    var style: DownloadIndicatorStyle = .list
    private let downloadStore = DownloadStore.shared
    @State private var isMarkedForOffline: Bool
    @AppStorage("enableDownloads") private var enableDownloads = true

    init(playlistId: String, style: DownloadIndicatorStyle = .list) {
        self.playlistId = playlistId
        self.style = style
        _isMarkedForOffline = State(
            initialValue: DownloadStore.shared.offlinePlaylistIds.contains(playlistId)
        )
    }

    var body: some View {
        Group {
            if enableDownloads && isMarkedForOffline {
                DownloadAvailabilityIcon(style: style)
            }
        }
        .onReceive(
            downloadStore.$offlinePlaylistIds
                .map { $0.contains(playlistId) }
                .removeDuplicates()
        ) { isMarkedForOffline = $0 }
    }
}

/// Helper für View-Modifier — blendet das Download-Icon auf der rechten Seite einer Song-Zeile ein.
struct DownloadTrailingIcon: ViewModifier {
    let songId: String

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content
            DownloadStatusIcon(songId: songId)
        }
    }
}

extension View {
    func withDownloadStatus(_ songId: String) -> some View {
        modifier(DownloadTrailingIcon(songId: songId))
    }
}
