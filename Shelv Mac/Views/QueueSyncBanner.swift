import SwiftUI

/// Hinweis am oberen Rand (analog zum ServerErrorBanner): Es liegt eine Wiedergabe-Queue
/// von einem anderen Gerät vor — übernehmen oder ablehnen. Nie automatisch.
struct QueueSyncBanner: View {
    @ObservedObject var queueSync = QueueSyncService.shared
    @Environment(\.themeColor) private var themeColor

    var body: some View {
        if let pendingRemote = queueSync.pendingRemote {
            let pendingSignature = pendingRemote.signature
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.headline)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "queue_available_title"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(String(localized: "queue_available_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button(String(localized: "queue_take_over")) {
                    queueSync.acceptPending()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
                Button {
                    queueSync.dismissPending()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(themeColor.gradient, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 480)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: pendingSignature) {
                do {
                    try await Task.sleep(for: .seconds(6))
                } catch {
                    return
                }
                guard queueSync.pendingRemote?.signature == pendingSignature else { return }
                queueSync.dismissPending()
            }
        }
    }
}
