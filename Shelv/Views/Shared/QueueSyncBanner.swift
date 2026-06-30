import SwiftUI

/// Inline-Hinweis am oberen Rand (analog zum ServerErrorBanner): Es liegt eine
/// Wiedergabe-Queue von einem anderen Gerät vor — der User kann sie übernehmen
/// oder ablehnen. Es wird nie automatisch übernommen.
struct QueueSyncBanner: View {
    @ObservedObject var queueSync = QueueSyncService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @State private var dragOffset: CGFloat = 0

    private var accentColor: Color { AppTheme.color(for: themeColorName) }

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
                Button {
                    queueSync.acceptPending()
                } label: {
                    Text(String(localized: "queue_take_over"))
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.25), in: Capsule())
                        .foregroundStyle(.white)
                }
                Button {
                    queueSync.dismissPending()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(accentColor.gradient, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height < 0 { dragOffset = value.translation.height }
                    }
                    .onEnded { value in
                        if value.translation.height < -30 {
                            withAnimation(.easeOut(duration: 0.2)) { dragOffset = -300 }
                            Task {
                                try? await Task.sleep(for: .milliseconds(200))
                                queueSync.dismissPending()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragOffset = 0 }
                        }
                    }
            )
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
