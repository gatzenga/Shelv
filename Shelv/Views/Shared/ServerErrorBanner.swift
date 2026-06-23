import SwiftUI

struct ServerErrorBanner: View {
    @ObservedObject var offlineMode = OfflineModeService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        if offlineMode.serverErrorBannerVisible {
            HStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "server_unreachable"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(String(localized: "switch_to_offline_mode_to_use_your_downloads"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button {
                    offlineMode.enterOfflineMode()
                } label: {
                    Text(String(localized: "offline"))
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.25), in: Capsule())
                        .foregroundStyle(.white)
                }
                Button {
                    offlineMode.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 14))
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
                                offlineMode.dismissBanner()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragOffset = 0 }
                        }
                    }
            )
        }
    }
}
