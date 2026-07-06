import SwiftUI

struct ServerErrorBanner: View {
    @ObservedObject var offlineMode = OfflineModeService.shared
    @AppStorage("themeColor") private var themeColorName = "violet"
    @State private var dragOffset: CGFloat = 0
    @State private var isGestureDismissalInFlight = false

    private let presentationAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.08)
    private let dismissalAnimation = Animation.easeInOut(duration: 0.22)

    private var title: String {
        if offlineMode.lastServerErrorWasDeviceOffline {
            return String(localized: "you_are_offline")
        }
        return String(localized: "server_unreachable")
    }

    var body: some View {
        Group {
            if offlineMode.serverErrorBannerVisible {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
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
                        dismissAnimated()
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
                .transition(.asymmetric(
                    insertion: .offset(y: -26)
                        .combined(with: .scale(scale: 0.98, anchor: .top))
                        .combined(with: .opacity),
                    removal: .offset(y: -26)
                        .combined(with: .scale(scale: 0.98, anchor: .top))
                        .combined(with: .opacity)
                ))
                .offset(y: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height < 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height < -30 {
                                dismissAnimated()
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
            }
        }
        .animation(presentationAnimation, value: offlineMode.serverErrorBannerVisible)
        .animation(.interactiveSpring(response: 0.26, dampingFraction: 0.82), value: dragOffset)
        .onChange(of: offlineMode.serverErrorBannerVisible) { _, visible in
            guard !visible else {
                isGestureDismissalInFlight = false
                dragOffset = 0
                return
            }
            if !isGestureDismissalInFlight {
                dragOffset = 0
            }
        }
        .onChange(of: offlineMode.lastServerErrorMessage) { _, _ in
            guard !isGestureDismissalInFlight else { return }
            dragOffset = 0
        }
    }

    private func dismissAnimated() {
        guard !isGestureDismissalInFlight else { return }
        isGestureDismissalInFlight = true
        withAnimation(dismissalAnimation) {
            dragOffset = -220
        }
        Task {
            try? await Task.sleep(for: .milliseconds(170))
            await MainActor.run {
                withAnimation(dismissalAnimation) {
                    offlineMode.dismissBanner()
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(230))
                    await MainActor.run {
                        dragOffset = 0
                        isGestureDismissalInFlight = false
                    }
                }
            }
        }
    }
}
