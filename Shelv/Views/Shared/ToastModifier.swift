import SwiftUI

struct ShelveToast: Equatable {
    let message: String
    var isError: Bool = false

    static var cellularDownloadsDisabled: ShelveToast {
        ShelveToast(message: String(localized: "cellular_downloads_disabled"), isError: true)
    }
}

private struct ToastViewModifier: ViewModifier {
    @Binding var toast: ShelveToast?
    /// Distance from the host view's top edge. Negative values lift the banner
    /// above it, for screens like the player whose content starts below a
    /// navigation bar.
    let topPadding: CGFloat
    @AppStorage("themeColor") private var themeColorName = "violet"
    private var accentColor: Color { AppTheme.color(for: themeColorName) }
    @State private var isVisible = false
    @State private var displayedToast: ShelveToast?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isVisible, let t = displayedToast {
                    toastBanner(t)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: toast) { _, newToast in
                if let newToast {
                    displayedToast = newToast
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isVisible = true
                    }
                    dismissTask?.cancel()
                    dismissTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isVisible = false
                            toast = nil
                        }
                    }
                } else if isVisible {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isVisible = false
                    }
                }
            }
    }

    private func toastBanner(_ t: ShelveToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(.white)
            Text(t.message)
                .font(.subheadline).bold()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(t.isError ? Color.red : accentColor)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .padding(.top, resolvedTopPadding)
    }

    /// A negative `topPadding` lifts the banner over a navigation bar, but the
    /// room for that is the safe area inset, which is far smaller on devices
    /// without a notch and on iPad. Clamped so the banner always keeps 8pt to
    /// the screen edge instead of being cut off there.
    private var resolvedTopPadding: CGFloat {
        guard topPadding < 0 else { return topPadding }
        let safeTop = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?
            .safeAreaInsets.top) ?? 0
        return max(topPadding, 8 - safeTop)
    }
}

extension View {
    func shelveToast(_ toast: Binding<ShelveToast?>, topPadding: CGFloat = 8) -> some View {
        modifier(ToastViewModifier(toast: toast, topPadding: topPadding))
    }
}
