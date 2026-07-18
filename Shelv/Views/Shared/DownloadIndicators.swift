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

/// Kompakter Status-Indikator für einen einzelnen Song: Ring während Download, Häkchen wenn fertig.
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
    @State private var isDownloaded: Bool
    @AppStorage("themeColor") private var themeColorName = "violet"

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
                    .background(AppTheme.color(for: themeColorName), in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
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
    private let downloadStore = DownloadStore.shared
    @State private var isMarkedForOffline: Bool
    @AppStorage("themeColor") private var themeColorName = "violet"
    @AppStorage("enableDownloads") private var enableDownloads = true

    init(playlistId: String) {
        self.playlistId = playlistId
        _isMarkedForOffline = State(
            initialValue: DownloadStore.shared.offlinePlaylistIds.contains(playlistId)
        )
    }

    var body: some View {
        Group {
            if enableDownloads && isMarkedForOffline {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(AppTheme.color(for: themeColorName), in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
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
