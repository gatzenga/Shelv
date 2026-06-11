import SwiftUI

struct ServerErrorBanner: View {
    @ObservedObject var offlineMode = OfflineModeService.shared

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
                Button(String(localized: "offline")) {
                    offlineMode.enterOfflineMode()
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
                Button {
                    offlineMode.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 480)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
