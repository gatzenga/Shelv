import SwiftUI

struct ServerErrorBanner: View {
    @ObservedObject var offlineMode = OfflineModeService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"

    var body: some View {
        if offlineMode.serverErrorBannerVisible {
            HStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Server unreachable", "Server nicht erreichbar"))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(tr(
                        "Switch to offline mode to use your downloads.",
                        "In Offline-Modus wechseln um Downloads zu verwenden."
                    ))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Button {
                    offlineMode.enterOfflineMode()
                } label: {
                    Text(tr("Offline", "Offline"))
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
        }
    }
}
