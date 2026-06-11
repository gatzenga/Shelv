import SwiftUI

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

/// Durchgestrichenes Download-Icon für „Download entfernen"-Aktionen.
struct DeleteDownloadIcon: View {
    var tint: Color? = nil

    var body: some View {
        if let tint {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(tint)
                .overlay {
                    GeometryReader { geo in
                        Path { p in
                            p.move(to: CGPoint(x: geo.size.width * 0.15, y: geo.size.height * 0.85))
                            p.addLine(to: CGPoint(x: geo.size.width * 0.85, y: geo.size.height * 0.15))
                        }
                        .stroke(tint, lineWidth: max(1.5, min(geo.size.width, geo.size.height) * 0.09))
                    }
                }
        } else {
            Image(systemName: "arrow.down.circle")
                .overlay {
                    GeometryReader { geo in
                        Path { p in
                            p.move(to: CGPoint(x: geo.size.width * 0.15, y: geo.size.height * 0.85))
                            p.addLine(to: CGPoint(x: geo.size.width * 0.85, y: geo.size.height * 0.15))
                        }
                        .stroke(.foreground, lineWidth: max(1.5, min(geo.size.width, geo.size.height) * 0.09))
                    }
                }
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
    @AppStorage("enableDownloads") private var enableDownloads = false

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
